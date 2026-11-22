// ore_mel.c - see ore_mel.h. Follows transcribe.cpp's front end for the
// power-of-two FFT sizes (its non-BLAS path: double-precision FFT and
// filterbank sums), which in turn follows NeMo.
#include "ore_mel.h"

#include <stdlib.h>

#ifndef M_PI
#define M_PI 3.14159265358979323846
#endif

static const double k_log_eps  = 5.9604644775390625e-08;  // 2^-24
static const double k_norm_eps = 1.0e-05;

static double hz_to_mel(double hz) {
    const double fsp = 200.0 / 3.0, min_log_hz = 1000.0;
    if (hz < min_log_hz) return hz / fsp;
    return min_log_hz / fsp + log(hz / min_log_hz) / (log(6.4) / 27.0);
}
static double mel_to_hz(double mel) {
    const double fsp = 200.0 / 3.0, min_log_hz = 1000.0, min_log_mel = min_log_hz / fsp;
    if (mel < min_log_mel) return mel * fsp;
    return min_log_hz * exp((log(6.4) / 27.0) * (mel - min_log_mel));
}

void ore_mel_free(ore_mel * m) {
    free(m->window);
    free(m->fb);
    free(m->fb_lo);
    free(m->fb_hi);
    memset(m, 0, sizeof(*m));
}

int ore_mel_init(ore_mel * m, int sample_rate, int n_fft, int win_length, int hop_length, int n_mels, float f_min,
                 float f_max, float pre_emphasis) {
    memset(m, 0, sizeof(*m));
    if (n_fft < 2 || (n_fft & (n_fft - 1)) != 0 || win_length < 2 || win_length > n_fft || hop_length < 1 ||
        n_mels < 1 || sample_rate < 1) {
        return 0;
    }
    m->sample_rate  = sample_rate;
    m->n_fft        = n_fft;
    m->win_length   = win_length;
    m->hop_length   = hop_length;
    m->n_mels       = n_mels;
    m->pre_emphasis = pre_emphasis;
    m->n_freq       = n_fft / 2 + 1;
    const int nf    = m->n_freq;
    m->window       = (double *) calloc((size_t) n_fft, sizeof(double));
    m->fb           = (float *) calloc((size_t) n_mels * nf, sizeof(float));
    m->fb_lo        = (int *) calloc((size_t) n_mels, sizeof(int));
    m->fb_hi        = (int *) calloc((size_t) n_mels, sizeof(int));
    double * hz     = (double *) calloc((size_t) n_mels + 2, sizeof(double));
    if (!m->window || !m->fb || !m->fb_lo || !m->fb_hi || !hz) {
        free(hz);
        ore_mel_free(m);
        return 0;
    }
    // Symmetric Hann of win_length, centred in the FFT frame.
    const int pad_each = (n_fft - win_length) / 2;
    for (int k = 0; k < win_length; ++k) {
        m->window[pad_each + k] = 0.5 - 0.5 * cos(2.0 * M_PI * k / (double) (win_length - 1));
    }
    // Slaney filterbank with area normalization.
    const double mel_min = hz_to_mel(f_min), mel_max = hz_to_mel(f_max);
    for (int i = 0; i < n_mels + 2; ++i) hz[i] = mel_to_hz(mel_min + (mel_max - mel_min) * i / (double) (n_mels + 1));
    for (int i = 0; i < n_mels; ++i) {
        const double enorm = 2.0 / (hz[i + 2] - hz[i]);
        int          lo = nf, hi = 0;
        for (int k = 0; k < nf; ++k) {
            const double f     = (double) sample_rate * k / (double) n_fft;
            const double lower = (f - hz[i]) / (hz[i + 1] - hz[i]);
            const double upper = (hz[i + 2] - f) / (hz[i + 2] - hz[i + 1]);
            double       w     = lower < upper ? lower : upper;
            if (w < 0.0) w = 0.0;
            const float v            = (float) (w * enorm);
            m->fb[(size_t) i * nf + k] = v;
            if (v != 0.0f) {
                if (k < lo) lo = k;
                hi = k + 1;
            }
        }
        if (lo < hi) {
            m->fb_lo[i] = lo - lo % 4;
            m->fb_hi[i] = hi;
        }
    }
    free(hz);
    return 1;
}

int ore_mel_frames(const ore_mel * m, int n_samples) { return n_samples / m->hop_length + 1; }

// In-place radix-2 FFT on interleaved complex doubles; the twiddles advance
// by multiplication inside each stage, as in the code this follows.
static void fft_radix2(double * data, int n) {
    int j = 0;
    for (int i = 1; i < n; ++i) {
        int bit = n >> 1;
        for (; j & bit; bit >>= 1) j ^= bit;
        j ^= bit;
        if (i < j) {
            double t        = data[2 * i];
            data[2 * i]     = data[2 * j];
            data[2 * j]     = t;
            t               = data[2 * i + 1];
            data[2 * i + 1] = data[2 * j + 1];
            data[2 * j + 1] = t;
        }
    }
    for (int len = 2; len <= n; len <<= 1) {
        const double ang     = -2.0 * M_PI / (double) len;
        const double wlen_re = cos(ang), wlen_im = sin(ang);
        for (int i = 0; i < n; i += len) {
            double w_re = 1.0, w_im = 0.0;
            for (int k = 0; k < len / 2; ++k) {
                const int    a    = 2 * (i + k), b = 2 * (i + k + len / 2);
                const double u_re = data[a], u_im = data[a + 1];
                const double v_re = data[b] * w_re - data[b + 1] * w_im;
                const double v_im = data[b] * w_im + data[b + 1] * w_re;
                data[a]           = u_re + v_re;
                data[a + 1]       = u_im + v_im;
                data[b]           = u_re - v_re;
                data[b + 1]       = u_im - v_im;
                const double t_re = w_re * wlen_re - w_im * wlen_im;
                const double t_im = w_re * wlen_im + w_im * wlen_re;
                w_re              = t_re;
                w_im              = t_im;
            }
        }
    }
}

int ore_mel_compute(const ore_mel * m, const float * pcm, int n_samples, float * out) {
    const int n_fft = m->n_fft, hop = m->hop_length, n_mels = m->n_mels, nf = m->n_freq, pad = n_fft / 2;
    const int n_frames = ore_mel_frames(m, n_samples);
    if (!pcm || n_frames < 3) return 0;  // the statistics need two real frames

    double * padded = (double *) calloc((size_t) n_samples + 2 * (size_t) pad, sizeof(double));
    double * frame  = (double *) malloc(sizeof(double) * 2 * (size_t) n_fft);
    float *  power  = (float *) malloc(sizeof(float) * (size_t) nf);
    if (!padded || !frame || !power) {
        free(padded);
        free(frame);
        free(power);
        return 0;
    }
    // Pre-emphasis into the middle of a zero-padded buffer.
    if (m->pre_emphasis != 0.0f) {
        const double alpha = (double) m->pre_emphasis;
        padded[pad]        = (double) pcm[0];
        for (int i = 1; i < n_samples; ++i) padded[pad + i] = (double) pcm[i] - alpha * (double) pcm[i - 1];
    } else {
        for (int i = 0; i < n_samples; ++i) padded[pad + i] = (double) pcm[i];
    }

    for (int t = 0; t < n_frames; ++t) {
        const double * src = padded + (size_t) t * hop;
        for (int k = 0; k < n_fft; ++k) {
            frame[2 * k]     = src[k] * m->window[k];
            frame[2 * k + 1] = 0.0;
        }
        fft_radix2(frame, n_fft);
        for (int k = 0; k < nf; ++k) {
            const double re = frame[2 * k], im = frame[2 * k + 1];
            power[k]        = (float) (re * re + im * im);
        }
        for (int i = 0; i < n_mels; ++i) {
            const float * fb  = m->fb + (size_t) i * nf;
            const int     khi = m->fb_hi[i];
            double        sum = 0.0;
            int           k   = m->fb_lo[i];
            for (; k < khi && k < nf - 3; k += 4) {
                sum += (double) fb[k] * (double) power[k] + (double) fb[k + 1] * (double) power[k + 1] +
                       (double) fb[k + 2] * (double) power[k + 2] + (double) fb[k + 3] * (double) power[k + 3];
            }
            for (; k < khi; ++k) sum += (double) fb[k] * (double) power[k];
            out[(size_t) i * n_frames + t] = (float) log(sum + k_log_eps);
        }
    }
    free(padded);
    free(frame);
    free(power);

    // Per-feature normalization over every frame but the last, which is
    // padding and becomes zero.
    const int n_norm = n_frames - 1;
    for (int i = 0; i < n_mels; ++i) {
        float * row = out + (size_t) i * n_frames;
        double  sum = 0.0;
        for (int t = 0; t < n_norm; ++t) sum += (double) row[t];
        const double mean  = sum / (double) n_norm;
        double       sumsq = 0.0;
        for (int t = 0; t < n_norm; ++t) {
            const double d = (double) row[t] - mean;
            sumsq += d * d;
        }
        const double inv = 1.0 / (sqrt(sumsq / (double) (n_norm - 1)) + k_norm_eps);
        for (int t = 0; t < n_norm; ++t) row[t] = (float) (((double) row[t] - mean) * inv);
        row[n_norm] = 0.0f;
    }
    return 1;
}
