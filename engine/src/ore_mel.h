// ore_mel.h - log-mel features, as NeMo's preprocessor computes them for the
// Parakeet models: pre-emphasis, zero-padded centred frames, Hann window,
// power spectrum, Slaney mel filterbank, log, and per-feature normalization.
#ifndef ORE_MEL_H
#define ORE_MEL_H

#include "ore_base.h"

typedef struct {
    int     sample_rate, n_fft, win_length, hop_length, n_mels;
    float   pre_emphasis;
    int     n_freq;      // n_fft / 2 + 1
    double * window;     // [n_fft], the window centred in the FFT frame
    float *  fb;         // [n_mels][n_freq]
    int *    fb_lo;      // first and one-past-last nonzero bin of each filter
    int *    fb_hi;
} ore_mel;

// Returns 0 when the settings are unsupported or memory runs out.
int  ore_mel_init(ore_mel * m, int sample_rate, int n_fft, int win_length, int hop_length, int n_mels, float f_min,
                  float f_max, float pre_emphasis);
void ore_mel_free(ore_mel * m);

// Frames for n samples: n / hop + 1.
int ore_mel_frames(const ore_mel * m, int n_samples);

// out[m * n_frames + t], n_mels rows. The last frame is zero (it is padding);
// the statistics cover the frames before it. Returns 0 on bad input (fewer
// than two frames) or when memory runs out.
int ore_mel_compute(const ore_mel * m, const float * pcm, int n_samples, float * out);

#endif  // ORE_MEL_H
