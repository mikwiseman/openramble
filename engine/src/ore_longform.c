// ore_longform.c - cutting a clip longer than the model's segment limit.
//
// Parakeet Ultra carries a small speech-detection head and a rule for long
// audio: find the pauses, cut at the last pause that keeps a piece under the
// limit (30 s), and recognize each piece as a clip of its own. This is a port
// of transcribe.cpp's segmenter (arch/parakeet/longform.cpp), which follows
// the model's reference implementation; the comparisons are in double
// precision and in the same order, so the cuts fall on the same samples.
#include "ore_internal.h"

typedef struct {
    double a, b;  // seconds
} region;

typedef struct {
    region * r;
    int      n, cap;
} regions;

static int regions_push(regions * rs, double a, double b) {
    if (rs->n == rs->cap) {
        const int cap = rs->cap ? rs->cap * 2 : 64;
        region *  nr  = (region *) realloc(rs->r, sizeof(region) * (size_t) cap);
        if (!nr) return 0;
        rs->r   = nr;
        rs->cap = cap;
    }
    rs->r[rs->n].a = a;
    rs->r[rs->n].b = b;
    ++rs->n;
    return 1;
}

// Nearest integer, ties to even: Python's round().
static int64_t round_half_even(double x) { return (int64_t) nearbyint(x); }

static int64_t samples_for(double seconds, int rate) { return round_half_even(seconds * (double) rate); }

// A pause source reports region edges on its own frame grid, so a gap of
// exactly min_pause comes out as a difference of two multiples of that frame;
// ties go to the pause.
static const double k_pause_epsilon   = 1e-6;
static const double k_boundary_window = 0.1;  // seconds
static const double k_min_tail        = 0.5;  // seconds
static const int    k_min_feature     = 320;  // samples too few to normalize

static int has_speech(const regions * rs, double seconds) {
    for (int i = 0; i < rs->n; ++i) {
        if (rs->r[i].b > 0.0 && rs->r[i].a < seconds) return 1;
    }
    return 0;
}

// Runs of frames at or above the threshold; gaps shorter than min_gap are
// bridged, then runs shorter than min_speech are dropped.
static int speech_regions(const struct ore_model * m, const float * probs, int n, double frame_seconds,
                          regions * out) {
    regions all       = { 0 };
    int     run_start = -1, ok = 1;
    for (int i = 0; i <= n && ok; ++i) {
        const int speaking = i < n && probs[i] >= m->vad_threshold;
        if (speaking && run_start < 0) {
            run_start = i;
        } else if (!speaking && run_start >= 0) {
            const double start = (double) run_start * frame_seconds;
            const double end   = (double) i * frame_seconds;
            if (all.n > 0 && start - all.r[all.n - 1].b < m->vad_min_gap) {
                all.r[all.n - 1].b = end;
            } else {
                ok = regions_push(&all, start, end);
            }
            run_start = -1;
        }
    }
    for (int i = 0; i < all.n && ok; ++i) {
        if (all.r[i].b - all.r[i].a >= m->vad_min_speech) ok = regions_push(out, all.r[i].a, all.r[i].b);
    }
    free(all.r);
    return ok;
}

static int cmp_region(const void * x, const void * y) {
    const region * a = (const region *) x, *b = (const region *) y;
    if (a->a != b->a) return a->a < b->a ? -1 : 1;
    if (a->b != b->b) return a->b < b->b ? -1 : 1;
    return 0;
}

// Gaps of at least min_pause before, between and after the speech.
static int pauses_from_speech(const struct ore_model * m, const regions * speech, double duration, regions * out) {
    const double least = m->seg_min_pause - k_pause_epsilon;
    regions      sorted = { 0 };
    int          ok     = 1;
    for (int i = 0; i < speech->n && ok; ++i) ok = regions_push(&sorted, speech->r[i].a, speech->r[i].b);
    if (ok && sorted.n > 1) qsort(sorted.r, (size_t) sorted.n, sizeof(region), cmp_region);
    double previous = 0.0;
    for (int i = 0; i < sorted.n && ok; ++i) {
        if (sorted.r[i].a - previous >= least) ok = regions_push(out, previous, sorted.r[i].a);
        if (sorted.r[i].b > previous) previous = sorted.r[i].b;
    }
    if (ok && duration - previous >= least) ok = regions_push(out, previous, duration);
    free(sorted.r);
    return ok;
}

// The last pause that lies wholly inside (min_segment, max_segment), else any
// pause whose middle does, else the limit itself.
static double next_cut(const struct ore_model * m, const regions * pauses) {
    const region * last = NULL;
    for (int i = 0; i < pauses->n; ++i) {
        if (pauses->r[i].a >= m->seg_min && pauses->r[i].b <= m->seg_max) last = &pauses->r[i];
    }
    if (!last) {
        for (int i = 0; i < pauses->n; ++i) {
            const double mid = (pauses->r[i].a + pauses->r[i].b) / 2;
            if (m->seg_min <= mid && mid <= m->seg_max) last = &pauses->r[i];
        }
    }
    if (!last) return m->seg_max;
    return (last->a + last->b) / 2;
}

int ore_needs_segments(const struct ore_model * m, int64_t n_samples) {
    return m->has_vad && n_samples > samples_for(m->seg_max, m->mel.sample_rate);
}

// Speech in [start, start + len) of the clip, in seconds from `start`.
// Returns 1, or 0 on failure (out of memory or aborted).
static int speech_in(struct ore_session * s, const float * pcm, int64_t start, int64_t len, regions * out) {
    const struct ore_model * m        = s->m;
    const double             rate     = (double) m->mel.sample_rate;
    const double             duration = (double) len / rate;
    out->n                            = 0;
    if (len < k_min_feature) return regions_push(out, 0.0, duration);
    if (s->abort_fn && s->abort_fn(s->abort_user)) return 0;
    const float * probs = NULL;
    int           n     = 0;
    if (!ore_speech_probs(s, pcm + start, (int) len, &probs, &n)) return 0;
    const double frame_seconds = (double) m->mel.hop_length / rate * 8.0;
    regions      found         = { 0 };
    int          ok            = speech_regions(m, probs, n, frame_seconds, &found);
    for (int i = 0; i < found.n && ok; ++i) {
        ok = regions_push(out, found.r[i].a, found.r[i].b < duration ? found.r[i].b : duration);
    }
    free(found.r);
    return ok;
}

static int segment_push(ore_segment ** out, int * n, int * cap, int64_t start, int64_t len) {
    if (*n == *cap) {
        const int     c  = *cap ? *cap * 2 : 16;
        ore_segment * ns = (ore_segment *) realloc(*out, sizeof(ore_segment) * (size_t) c);
        if (!ns) return 0;
        *out = ns;
        *cap = c;
    }
    (*out)[*n].start     = start;
    (*out)[*n].n_samples = len;
    ++*n;
    return 1;
}

int ore_segments(struct ore_session * s, const float * pcm, int64_t n_samples, ore_segment ** out, int * n_out) {
    const struct ore_model * m    = s->m;
    const int                sr   = m->mel.sample_rate;
    const double             rate = (double) sr;
    *out                          = NULL;
    *n_out                        = 0;
    int     cap = 0, ok = 1;
    regions carried = { 0 }, block = { 0 }, pauses = { 0 }, alone = { 0 };

    const int64_t cap_samples = samples_for(m->seg_max, sr);
    const int64_t max_block   = samples_for(m->seg_scan_block, sr);
    int64_t       window      = samples_for(k_boundary_window, sr);
    if (window < 4) window = 4;
    int64_t min_tail = samples_for(k_min_tail, sr);
    if (min_tail < window) min_tail = window;

    // The carry is [consumed, consumed + carry_len) of the clip; the carried
    // regions are relative to its start.
    int64_t consumed = 0, carry_len = 0, block_start = 0, emitted = 0;
    int     cuts = 0;
    while (ok && emitted < n_samples) {
        // The audio is scanned in blocks; a block is shortened only so that
        // the one after it is not too short to judge.
        const int64_t remaining = n_samples - emitted;
        int64_t       block_len = remaining;
        if (remaining > max_block) block_len = max_block < remaining - min_tail ? max_block : remaining - min_tail;
        emitted += block_len;

        const double offset = (double) carry_len / rate;
        ok                  = speech_in(s, pcm, block_start, block_len, &block);
        for (int i = 0; i < block.n && ok; ++i) ok = regions_push(&carried, block.r[i].a + offset, block.r[i].b + offset);
        carry_len += block_len;
        block_start += block_len;

        while (ok && carry_len > cap_samples) {
            pauses.n = 0;
            ok       = pauses_from_speech(m, &carried, (double) carry_len / rate, &pauses);
            if (!ok) break;
            const double  cut     = next_cut(m, &pauses);
            const int64_t index   = round_half_even(cut * rate);
            const double  seconds = (double) index / rate;
            int           keep    = has_speech(&carried, seconds);
            if (!keep) {
                // Speech judged over a whole block is judged against
                // everything else in it: speech much quieter than a neighbour
                // can score as silence there and as speech by itself. So a
                // piece is asked about on its own before it is dropped.
                ok   = speech_in(s, pcm, consumed, index, &alone);
                keep = ok && has_speech(&alone, (double) index / rate);
            }
            if (ok && keep) ok = segment_push(out, n_out, &cap, consumed, index);
            consumed += index;
            carry_len -= index;
            ++cuts;
            int kept = 0;
            for (int i = 0; i < carried.n; ++i) {
                if (carried.r[i].b > seconds) {
                    const double a      = carried.r[i].a - seconds;
                    carried.r[kept].a   = a > 0.0 ? a : 0.0;
                    carried.r[kept++].b = carried.r[i].b - seconds;
                }
            }
            carried.n = kept;
        }
    }
    // What is left after the last cut is dropped when it is too short to
    // normalize or holds no speech.
    if (ok) {
        int keep = 1;
        if (cuts > 0) {
            if (carry_len < k_min_feature) {
                keep = 0;
            } else if (!has_speech(&carried, (double) carry_len / rate)) {
                ok   = speech_in(s, pcm, consumed, carry_len, &alone);
                keep = ok && has_speech(&alone, (double) carry_len / rate);
            }
        }
        if (ok && keep) ok = segment_push(out, n_out, &cap, consumed, carry_len);
    }
    free(carried.r);
    free(block.r);
    free(pauses.r);
    free(alone.r);
    if (!ok) {
        free(*out);
        *out   = NULL;
        *n_out = 0;
    }
    return ok;
}
