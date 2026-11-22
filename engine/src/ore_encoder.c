// ore_encoder.c - the FastConformer encoder: subsampling, then 24 blocks of
// feed-forward, relative-position attention, convolution and feed-forward.
//
// The arithmetic follows NeMo's model as transcribe.cpp runs it on the CPU:
// quantized weights meet activations quantized the way ggml quantizes them,
// everything else is single precision. What differs is how the work is laid
// out: no graph, no per-run allocation, every product over all frames at once.
#include "ore_internal.h"

#include <stdio.h>

#if defined(_WIN32)
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
double ore_now_ms(void) {
    LARGE_INTEGER f, c;
    QueryPerformanceFrequency(&f);
    QueryPerformanceCounter(&c);
    return (double) c.QuadPart * 1000.0 / (double) f.QuadPart;
}
#else
#include <time.h>
double ore_now_ms(void) {
    struct timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    return t.tv_sec * 1e3 + t.tv_nsec / 1e6;
}
#endif

#define LN_EPS 1e-5f

static float * need(struct ore_session * s, ore_buf * b, size_t n) {
    float * p = ore_buf_need(b, n);
    if (!p) s->oom = 1;
    return p;
}

static void dump(struct ore_session * s, const char * name, const float * data, int rows, int cols) {
    if (s->dump) s->dump(s->dump_user, name, data, rows, cols);
}

// ---- matrix products --------------------------------------------------------

static void lin_in_set(ore_lin_in * in, const float * x, size_t stride, int rows, int n) {
    in->x        = x;
    in->stride   = stride;
    in->rows     = rows;
    in->n        = n;
    in->have_q8k = in->have_q80 = in->have_xp = 0;
}

typedef struct {
    struct ore_session * s;
    const ore_tensor *   w;
    ore_lin_in *         in;
    float *              y;
    size_t               ystride;
    int                  n_in;
} lin_ctx;

static void job_quant_q8k(void * v, int b, int e, int thread) {
    lin_ctx * c = (lin_ctx *) v;
    (void) thread;
    c->s->k->quantize_q8k(c->in->x, c->in->stride, b, e, &c->in->q8k);
}
static void job_quant_q80(void * v, int b, int e, int thread) {
    lin_ctx * c = (lin_ctx *) v;
    (void) thread;
    c->s->k->quantize_q80(c->in->x, c->in->stride, b, e, &c->in->q80);
}
static void job_pack(void * v, int b, int e, int thread) {
    lin_ctx * c = (lin_ctx *) v;
    (void) thread;
    ore_pack16(c->in->x, c->in->stride, c->in->rows, c->in->n, b, e, c->in->xp.p);
}
static void job_gemm_q4k(void * v, int b, int e, int thread) {
    lin_ctx * c = (lin_ctx *) v;
    (void) thread;
    c->s->k->gemm_q4k(c->w->data, c->n_in, b, e, &c->in->q8k, c->y, c->ystride);
}
static void job_gemm_q80(void * v, int b, int e, int thread) {
    lin_ctx * c = (lin_ctx *) v;
    (void) thread;
    c->s->k->gemm_q80(c->w->data, c->n_in, b, e, &c->in->q80, c->y, c->ystride);
}
static void job_gemm_f32(void * v, int b, int e, int thread) {
    lin_ctx * c = (lin_ctx *) v;
    c->s->k->gemm_f32(c->w->data, c->w->type == ORE_T_F16, (size_t) c->n_in, c->n_in, b, e, c->in->xp.p, c->in->rows,
                      c->y, c->ystride, c->s->ts[thread].f.p);
}

// y[t][r] = sum_k W[r][k] * in[t][k] for every frame, whatever the weight's
// storage type. Linear weights are [n_in, n_out]; 1x1 convolutions are
// [1, n_in, n_out].
static void linear(struct ore_session * s, const ore_tensor * w, ore_lin_in * in, float * y, size_t ystride) {
    const int n_in  = (int) (w->n_dims == 3 ? w->dims[1] : w->dims[0]);
    const int n_out = (int) (w->n_dims == 3 ? w->dims[2] : w->dims[1]);
    const int ntb   = ore_frame_blocks(in->rows);
    lin_ctx   c     = { s, w, in, y, ystride, n_in };
    if (s->oom || in->rows <= 0) return;
    if (w->type == ORE_T_Q4_K) {
        if (!in->have_q8k) {
            if (!ore_qact_reserve(&in->q8k, in->rows, in->n, ORE_Q4K_BLOCK)) {
                s->oom = 1;
                return;
            }
            ore_parallel_for(s->pool, ntb, 1, job_quant_q8k, &c);
            in->have_q8k = 1;
        }
        ore_parallel_for(s->pool, n_out, 48, job_gemm_q4k, &c);
    } else if (w->type == ORE_T_Q8_0) {
        if (!in->have_q80) {
            if (!ore_qact_reserve(&in->q80, in->rows, in->n, ORE_Q80_BLOCK)) {
                s->oom = 1;
                return;
            }
            ore_parallel_for(s->pool, ntb, 1, job_quant_q80, &c);
            in->have_q80 = 1;
        }
        ore_parallel_for(s->pool, n_out, 48, job_gemm_q80, &c);
    } else {
        if (!in->have_xp) {
            if (!need(s, &in->xp, (size_t) ntb * in->n * ORE_FB)) return;
            ore_parallel_for(s->pool, ntb, 1, job_pack, &c);
            in->have_xp = 1;
        }
        ore_parallel_for(s->pool, n_out, 48, job_gemm_f32, &c);
    }
}

// ---- per-frame steps --------------------------------------------------------

enum { OP_LN, OP_SILU, OP_ADD, OP_ADD_HALF, OP_ADD_VEC2, OP_GLU, OP_DWCONV, OP_ADD_BIAS };

typedef struct {
    struct ore_session * s;
    int                  op, n, T;
    const float *        a;   // input, [T][astride]
    size_t               astride;
    float *              out; // [T][ostride]
    size_t               ostride;
    const float *        p0;  // per-op parameters
    const float *        p1;
    float *              out2;
    const ore_block *    blk;
} frame_ctx;

static void job_frames(void * v, int b, int e, int thread) {
    frame_ctx *         c = (frame_ctx *) v;
    const ore_kernels * k = c->s->k;
    (void) thread;
    for (int t = b; t < e; ++t) {
        const float * a = c->a + (size_t) t * c->astride;
        float *       o = c->out + (size_t) t * c->ostride;
        switch (c->op) {
            case OP_LN: k->layer_norm(a, o, c->n, c->p0, c->p1, LN_EPS); break;
            case OP_SILU: k->silu(o, (size_t) c->n); break;
            case OP_ADD:
                for (int i = 0; i < c->n; ++i) o[i] = o[i] + a[i];
                break;
            case OP_ADD_HALF:
                for (int i = 0; i < c->n; ++i) o[i] = o[i] + a[i] * 0.5f;
                break;
            case OP_ADD_BIAS:
                for (int i = 0; i < c->n; ++i) o[i] = o[i] + c->p0[i];
                break;
            case OP_ADD_VEC2: {
                // q + pos_bias_u and q + pos_bias_v
                float * o2 = c->out2 + (size_t) t * c->ostride;
                for (int i = 0; i < c->n; ++i) {
                    o[i]  = a[i] + c->p0[i];
                    o2[i] = a[i] + c->p1[i];
                }
            } break;
            case OP_GLU: k->glu(a, a + c->n, o, (size_t) c->n); break;
            case OP_DWCONV: {
                const int     kk   = c->blk ? c->s->m->conv_kernel : 0;
                const int     half = (kk - 1) / 2;
                const float * taps[64];
                for (int j = 0; j < kk; ++j) {
                    const int tt = t + j - half;
                    taps[j]      = (tt >= 0 && tt < c->T) ? c->a + (size_t) tt * c->astride : NULL;
                }
                k->dwconv_bn_silu(taps, c->blk->dw_t, kk, c->n, c->blk->bn_scale, c->blk->bn_bias, o);
            } break;
        }
    }
}

static void frames(struct ore_session * s, frame_ctx * c) {
    c->s = s;
    ore_parallel_for(s->pool, c->T, 4, job_frames, c);
}

static void layer_norm(struct ore_session * s, const float * x, float * y, int T, int n, const ore_tensor * g,
                       const ore_tensor * b) {
    frame_ctx c = { 0 };
    c.op        = OP_LN;
    c.n         = n;
    c.T         = T;
    c.a         = x;
    c.astride   = (size_t) n;
    c.out       = y;
    c.ostride   = (size_t) n;
    c.p0        = (const float *) g->data;
    c.p1        = (const float *) b->data;
    frames(s, &c);
}

static void add_into(struct ore_session * s, float * x, const float * y, int T, int n, int half) {
    frame_ctx c = { 0 };
    c.op        = half ? OP_ADD_HALF : OP_ADD;
    c.n         = n;
    c.T         = T;
    c.a         = y;
    c.astride   = (size_t) n;
    c.out       = x;
    c.ostride   = (size_t) n;
    frames(s, &c);
}

// ---- attention ----------------------------------------------------------------

typedef struct {
    struct ore_session * s;
    int                  T;
} att_ctx;

// One head: scores against keys and against relative positions, softmax,
// then the weighted sum of values.
static void job_heads(void * v, int h0, int h1, int thread) {
    att_ctx *            c  = (att_ctx *) v;
    struct ore_session * s  = c->s;
    const ore_kernels *  k  = s->k;
    ore_thread_scratch * ts = &s->ts[thread];
    const int            T  = c->T, d = s->m->d_model, hd = d / s->m->n_heads, P = 2 * T - 1;
    const int            ntb = ore_frame_blocks(T);
    const float          scale = 1.0f / sqrtf((float) hd);
    float *              ac = ts->ac.p;
    float *              bd = ts->bd.p;
    for (int h = h0; h < h1; ++h) {
        // content scores: ac[tq][tk] = q_u[tq] . k[tk]
        ore_pack16(s->qu.p + h * hd, (size_t) d, T, hd, 0, ntb, ts->pk.p);
        k->gemm_f32(s->kk.p + h * hd, 0, (size_t) d, hd, 0, T, ts->pk.p, T, ac, (size_t) T, ts->f.p);
        // position scores: bd[tq][j] = q_v[tq] . p[j], j = tk - tq + T - 1
        ore_pack16(s->qv.p + h * hd, (size_t) d, T, hd, 0, ntb, ts->pk.p);
        k->gemm_f32(s->p.p + h * hd, 0, (size_t) d, hd, 0, P, ts->pk.p, T, bd, (size_t) P, ts->f.p);
        const int band = s->m->att_band;
        for (int tq = 0; tq < T; ++tq) {
            float *       row = ac + (size_t) tq * T;
            const float * br  = bd + (size_t) tq * P + (T - 1 - tq);
            for (int tk = 0; tk < T; ++tk) row[tk] = (row[tk] + br[tk]) * scale;
            if (band > 0 && T - 1 > band) {
                // Out of reach: a score so low its weight is exactly zero.
                for (int tk = 0; tk < tq - band; ++tk) row[tk] = -1e30f;
                for (int tk = tq + band + 1; tk < T; ++tk) row[tk] = -1e30f;
            }
            k->softmax(row, T);
        }
        // out[tq][h][dd] = sum_tk attn[tq][tk] * v[tk][h][dd]
        ore_pack16(ac, (size_t) T, T, T, 0, ntb, ts->pk2.p);
        k->gemm_f32(s->vt.p + (size_t) h * hd * T, 0, (size_t) T, T, 0, hd, ts->pk2.p, T, s->o.p + h * hd, (size_t) d,
                    ts->f.p);
    }
}

typedef struct {
    const float * v;
    float *       vt;
    int           T, d;
} tr_ctx;
static void job_transpose(void * vc, int c0, int c1, int thread) {
    tr_ctx * c = (tr_ctx *) vc;
    (void) thread;
    for (int ch = c0; ch < c1; ++ch) {
        float * dst = c->vt + (size_t) ch * c->T;
        for (int t = 0; t < c->T; ++t) dst[t] = c->v[(size_t) t * c->d + ch];
    }
}

// Sinusoidal table for relative offsets T-1 .. -(T-1), as NeMo builds it.
static int build_positions(struct ore_session * s, int T) {
    const int d = s->m->d_model, P = 2 * T - 1;
    if (s->pos_T == T) return 1;
    float * pos = need(s, &s->pos, (size_t) P * d);
    if (!pos) return 0;
    // Single-precision values, as the model's reference computes them, but
    // through the double-precision functions rounded once: C libraries agree
    // on those, and not always on the single-precision ones.
    const float ln_10000 = (float) log(10000.0);
    for (int i = 0; i < P; ++i) {
        const float rel = (float) (T - 1 - i);
        float *     row = pos + (size_t) i * d;
        for (int kq = 0; kq < d / 2; ++kq) {
            const float div = (float) exp((double) ((float) (2 * kq) * (-ln_10000 / (float) d)));
            const float arg = rel * div;
            row[2 * kq]     = (float) sin((double) arg);
            row[2 * kq + 1] = (float) cos((double) arg);
        }
    }
    s->pos_T = T;
    lin_in_set(&s->in_pos, pos, (size_t) d, P, d);
    return 1;
}

// ---- subsampling ----------------------------------------------------------------

typedef struct {
    struct ore_session * s;
    const float *        mel;  // [n_mels][T_mel]
    int                  T_mel, H1, H2, H3, len1, len2, len3;
    float *              flat;  // [T][sub_ch * n_mels / 8]
} pre_ctx;

static void relu_bias(float * a, size_t rows, int n, const float * bias) {
    for (size_t r = 0; r < rows; ++r) {
        float * p = a + r * (size_t) n;
        for (int i = 0; i < n; ++i) {
            const float v = p[i] + bias[i];
            p[i]          = v > 0.0f ? v : 0.0f;
        }
    }
}

// Output frames [e0, e1): three stride-2 stages over the rows they need.
// Rows past a stage's valid length are zeroed where the model zeroes them
// (after the first ReLU and after each depthwise convolution), not elsewhere.
static void job_pre(void * v, int e0, int e1, int thread) {
    pre_ctx *                c  = (pre_ctx *) v;
    struct ore_session *     s  = c->s;
    const struct ore_model * m  = s->m;
    const ore_kernels *      k  = s->k;
    ore_thread_scratch *     ts = &s->ts[thread];
    const int                C  = m->sub_ch, F0 = m->n_mels, F1 = F0 / 2, F2 = F0 / 4, F3 = F0 / 8;
    const int r2a = ORE_MAX(0, 2 * e0 - 1), r2b = ORE_MIN(c->H2, 2 * (e1 - 1) + 2);
    const int r1a = ORE_MAX(0, 2 * r2a - 1), r1b = ORE_MIN(c->H1, 2 * (r2b - 1) + 2);
    const int n1 = r1b - r1a, n2 = r2b - r2a, n3 = e1 - e0;
    const size_t P1 = (size_t) n1 * F1, P2 = (size_t) n2 * F2, P3 = (size_t) n3 * F3;
    float * patch = ore_buf_need(&ts->pre[0], P1 * 9);
    float * A1    = ore_buf_need(&ts->pre[1], P1 * C);
    float * B2    = ore_buf_need(&ts->pre[2], P2 * C);
    float * A2    = ore_buf_need(&ts->pre[3], P2 * C);
    float * B3    = ore_buf_need(&ts->pre[4], P3 * C);
    float * A3    = ore_buf_need(&ts->pre[5], P3 * C);
    size_t  xpn   = (size_t) ore_frame_blocks((int) P1) * 9 * ORE_FB;
    xpn           = ORE_MAX(xpn, (size_t) ore_frame_blocks((int) P2) * C * ORE_FB);
    float * xp    = ore_buf_need(&ts->pre[6], xpn);
    if (!patch || !A1 || !B2 || !A2 || !B3 || !A3 || !xp) {
        s->oom = 1;
        return;
    }
    // conv0: 3x3, stride 2, one input channel.
    for (int r = r1a; r < r1b; ++r) {
        for (int f = 0; f < F1; ++f) {
            float * pp = patch + ((size_t) (r - r1a) * F1 + f) * 9;
            for (int kh = 0; kh < 3; ++kh) {
                const int tt = 2 * r + kh - 1;
                for (int kw = 0; kw < 3; ++kw) {
                    const int ff = 2 * f + kw - 1;
                    pp[kh * 3 + kw] =
                        (tt >= 0 && tt < c->T_mel && ff >= 0 && ff < F0) ? c->mel[(size_t) ff * c->T_mel + tt] : 0.0f;
                }
            }
        }
    }
    ore_pack16(patch, 9, (int) P1, 9, 0, ore_frame_blocks((int) P1), xp);
    k->gemm_f32(m->c0w.data, 0, 9, 9, 0, C, xp, (int) P1, A1, (size_t) C, ts->f.p);
    relu_bias(A1, P1, C, (const float *) m->c0b.data);
    for (int r = ORE_MAX(r1a, c->len1); r < r1b; ++r) memset(A1 + (size_t) (r - r1a) * F1 * C, 0, sizeof(float) * F1 * C);

    // conv2 (depthwise, stride 2), conv3 (1x1), ReLU.
    for (int r = r2a; r < r2b; ++r) {
        float * row = B2 + (size_t) (r - r2a) * F2 * C;
        if (r >= c->len2) {
            memset(row, 0, sizeof(float) * F2 * C);
            continue;
        }
        for (int f = 0; f < F2; ++f) {
            const float * taps[9];
            for (int kh = 0; kh < 3; ++kh) {
                const int rr = 2 * r + kh - 1;
                for (int kw = 0; kw < 3; ++kw) {
                    const int ff = 2 * f + kw - 1;
                    taps[kh * 3 + kw] =
                        (rr >= 0 && rr < c->H1 && ff >= 0 && ff < F1) ? A1 + ((size_t) (rr - r1a) * F1 + ff) * C : NULL;
                }
            }
            k->dwconv_bias(taps, m->c2_t, 9, C, (const float *) m->c2b.data, row + (size_t) f * C);
        }
    }
    ore_pack16(B2, (size_t) C, (int) P2, C, 0, ore_frame_blocks((int) P2), xp);
    k->gemm_f32(m->c3w.data, 0, (size_t) C, C, 0, C, xp, (int) P2, A2, (size_t) C, ts->f.p);
    relu_bias(A2, P2, C, (const float *) m->c3b.data);

    // conv5 (depthwise, stride 2), conv6 (1x1), ReLU.
    for (int e = e0; e < e1; ++e) {
        float * row = B3 + (size_t) (e - e0) * F3 * C;
        if (e >= c->len3) {
            memset(row, 0, sizeof(float) * F3 * C);
            continue;
        }
        for (int f = 0; f < F3; ++f) {
            const float * taps[9];
            for (int kh = 0; kh < 3; ++kh) {
                const int rr = 2 * e + kh - 1;
                for (int kw = 0; kw < 3; ++kw) {
                    const int ff = 2 * f + kw - 1;
                    taps[kh * 3 + kw] =
                        (rr >= 0 && rr < c->H2 && ff >= 0 && ff < F2) ? A2 + ((size_t) (rr - r2a) * F2 + ff) * C : NULL;
                }
            }
            k->dwconv_bias(taps, m->c5_t, 9, C, (const float *) m->c5b.data, row + (size_t) f * C);
        }
    }
    ore_pack16(B3, (size_t) C, (int) P3, C, 0, ore_frame_blocks((int) P3), xp);
    k->gemm_f32(m->c6w.data, 0, (size_t) C, C, 0, C, xp, (int) P3, A3, (size_t) C, ts->f.p);
    relu_bias(A3, P3, C, (const float *) m->c6b.data);

    // Flatten: feature index is channel * F3 + frequency.
    for (int e = e0; e < e1; ++e) {
        float * dst = c->flat + (size_t) e * C * F3;
        for (int f = 0; f < F3; ++f) {
            const float * src = A3 + ((size_t) (e - e0) * F3 + f) * C;
            for (int ch = 0; ch < C; ++ch) dst[(size_t) ch * F3 + f] = src[ch];
        }
    }
}

// ---- the whole encoder ----------------------------------------------------------

static int aborted(struct ore_session * s) { return s->abort_fn && s->abort_fn(s->abort_user); }

// Mel features, the three subsampling stages and the projection to d_model:
// s->x holds [*T_out][d_model]. With `all_frames` the frames past the valid
// length are computed too, as the model computes them (the speech-detection
// head looks at them); otherwise they are left out, because attention never
// looks at them and the decoder never reads them. *valid_out is the number of
// valid frames. Returns 0 on failure.
static int pre_encode(struct ore_session * s, const float * pcm, int n_samples, int all_frames, int * T_out,
                      int * valid_out) {
    const struct ore_model * m = s->m;
    const int                d = m->d_model, dff = m->d_ff;

    double    t0    = ore_now_ms();
    const int T_mel = ore_mel_frames(&m->mel, n_samples);
    if (T_mel < 3) return 0;
    float * mel = need(s, &s->mel, (size_t) m->n_mels * T_mel);
    if (!mel || !ore_mel_compute(&m->mel, pcm, n_samples, mel)) return 0;
    if (!all_frames) dump(s, "enc.mel.in", mel, m->n_mels, T_mel);
    s->t_mel += ore_now_ms() - t0;

    pre_ctx pc;
    pc.s     = s;
    pc.mel   = mel;
    pc.T_mel = T_mel;
    pc.H1    = (T_mel - 1) / 2 + 1;
    pc.H2    = (pc.H1 - 1) / 2 + 1;
    pc.H3    = (pc.H2 - 1) / 2 + 1;
    if (m->length_masking) {
        // Valid lengths count from the samples, not from the padded mel.
        const int len0 = n_samples / m->mel.hop_length;
        pc.len1        = (len0 - 1) / 2 + 1;
        pc.len2        = (pc.len1 - 1) / 2 + 1;
        pc.len3        = (pc.len2 - 1) / 2 + 1;
    } else {
        pc.len1 = pc.H1;
        pc.len2 = pc.H2;
        pc.len3 = pc.H3;
    }
    const int valid = ORE_MIN(pc.len3, pc.H3);
    const int T     = all_frames ? pc.H3 : valid;
    if (valid < 1) return 0;
    const int n_flat = m->sub_ch * (m->n_mels / 8);
    pc.flat          = need(s, &s->flat, (size_t) T * n_flat);
    for (int i = 0; i < s->n_threads; ++i) {
        size_t fs = (size_t) 6 * ORE_MAX(ORE_MAX(dff, d), ORE_MAX(n_flat, T));
        need(s, &s->ts[i].f, fs);
    }
    float * x = need(s, &s->x, (size_t) T * d);
    if (s->oom) return 0;
    ore_parallel_for(s->pool, T, 8, job_pre, &pc);
    if (s->oom) return 0;

    lin_in_set(&s->in_a, pc.flat, (size_t) n_flat, T, n_flat);
    linear(s, &m->pre_out_w, &s->in_a, x, (size_t) d);
    frame_ctx c = { 0 };
    c.op        = OP_ADD_BIAS;
    c.n         = d;
    c.T         = T;
    c.out       = x;
    c.ostride   = (size_t) d;
    c.a         = x;
    c.astride   = (size_t) d;
    c.p0        = (const float *) m->pre_out_b.data;
    frames(s, &c);
    if (s->oom) return 0;
    *T_out     = T;
    *valid_out = valid;
    return 1;
}

typedef struct {
    struct ore_session * s;
    const float *        h;      // [T][H]
    float *              patch;  // [T][H * K]
    int                  T, H, K;
} vad_ctx;
static void job_vad_patch(void * v, int b, int e, int thread) {
    vad_ctx * c = (vad_ctx *) v;
    (void) thread;
    const int half = c->K / 2;
    for (int t = b; t < e; ++t) {
        float * p = c->patch + (size_t) t * c->H * c->K;
        for (int kk = 0; kk < c->K; ++kk) {
            const int     tt  = t + kk - half;
            const float * src = (tt >= 0 && tt < c->T) ? c->h + (size_t) tt * c->H : NULL;
            for (int ic = 0; ic < c->H; ++ic) p[(size_t) ic * c->K + kk] = src ? src[ic] : 0.0f;
        }
    }
}

typedef struct {
    struct ore_session * s;
    const void *         w;
    int                  n_in, rows;
    const float *        xp;
    float *              y;
    size_t               ystride;
} plain_ctx;
static void job_plain_f32(void * v, int b, int e, int thread) {
    plain_ctx * c = (plain_ctx *) v;
    c->s->k->gemm_f32(c->w, 0, (size_t) c->n_in, c->n_in, b, e, c->xp, c->rows, c->y, c->ystride,
                      c->s->ts[thread].f.p);
}

// The speech-detection head over one stretch of audio: the probability of
// speech at each valid encoder frame (80 ms each). *probs points into the
// session. Returns 0 on failure.
int ore_speech_probs(struct ore_session * s, const float * pcm, int n_samples, const float ** probs, int * n) {
    const struct ore_model * m = s->m;
    const int                d = m->d_model, H = m->vad_hidden, K = m->vad_kernel;
    const double             t0 = ore_now_ms();
    int                      T = 0, valid = 0;
    s->oom = 0;
    if (!m->has_vad || !pre_encode(s, pcm, n_samples, 1, &T, &valid)) return 0;
    const int ntb = ore_frame_blocks(T);
    float *   h   = need(s, &s->h, (size_t) T * ORE_MAX(H, 1) * 2);
    float *   c2  = h ? h + (size_t) T * H : NULL;
    float *   pat = need(s, &s->y, (size_t) T * H * K);
    float *   xp  = need(s, &s->in_a.xp, (size_t) ntb * ORE_MAX(d, H * K) * ORE_FB);
    float *   pr  = need(s, &s->o, (size_t) T);
    for (int i = 0; i < s->n_threads; ++i) need(s, &s->ts[i].f, (size_t) 6 * ORE_MAX(ORE_MAX(d, H * K), m->d_ff));
    if (s->oom) return 0;

    // proj (1x1 convolution), bias, SiLU.
    ore_pack16(s->x.p, (size_t) d, T, d, 0, ntb, xp);
    plain_ctx pc = { s, m->vad_proj_w, d, T, xp, h, (size_t) H };
    ore_parallel_for(s->pool, H, 48, job_plain_f32, &pc);
    for (int t = 0; t < T; ++t) {
        float * r = h + (size_t) t * H;
        for (int i = 0; i < H; ++i) r[i] = r[i] + m->vad_proj_b[i];
        s->k->silu(r, (size_t) H);
    }
    // Context convolution over K frames, bias, SiLU.
    vad_ctx vc = { s, h, pat, T, H, K };
    ore_parallel_for(s->pool, T, 32, job_vad_patch, &vc);
    ore_pack16(pat, (size_t) H * K, T, H * K, 0, ntb, xp);
    plain_ctx cc = { s, m->vad_ctx_w, H * K, T, xp, c2, (size_t) H };
    ore_parallel_for(s->pool, H, 48, job_plain_f32, &cc);
    for (int t = 0; t < T; ++t) {
        float * r = c2 + (size_t) t * H;
        for (int i = 0; i < H; ++i) r[i] = r[i] + m->vad_ctx_b[i];
        s->k->silu(r, (size_t) H);
        // Output: one weight per channel, bias, sigmoid.
        float acc = 0.0f;
        for (int i = 0; i < H; ++i) acc = fmaf(m->vad_out_w[i], r[i], acc);
        acc   = acc + m->vad_out_b;
        pr[t] = 1.0f / (1.0f + ore_expf(-acc));
    }
    s->t_encode += ore_now_ms() - t0;
    *probs = pr;
    *n     = valid;
    return 1;
}

int ore_encode(struct ore_session * s, const float * pcm, int n_samples, const float ** enc, int * T_out) {
    const struct ore_model * m = s->m;
    const int                d = m->d_model, dff = m->d_ff;
    s->oom                     = 0;
    int T = 0, valid = 0;
    const double mel_before = s->t_mel;
    double       t0         = ore_now_ms();
    if (!pre_encode(s, pcm, n_samples, 0, &T, &valid)) return 0;
    t0 += s->t_mel - mel_before;  // the mel's share is reported on its own

    float * x  = s->x.p;
    float * xn = need(s, &s->xn, (size_t) T * d);
    float * h  = need(s, &s->h, (size_t) T * ORE_MAX(dff, 2 * d));
    float * y  = need(s, &s->y, (size_t) T * d);
    float * q  = need(s, &s->q, (size_t) T * d);
    float * kk = need(s, &s->kk, (size_t) T * d);
    float * vv = need(s, &s->v, (size_t) T * d);
    float * vt = need(s, &s->vt, (size_t) T * d);
    float * p  = need(s, &s->p, (size_t) (2 * T - 1) * d);
    float * qu = need(s, &s->qu, (size_t) T * d);
    float * qv = need(s, &s->qv, (size_t) T * d);
    float * o  = need(s, &s->o, (size_t) T * d);
    float * gl = need(s, &s->gl, (size_t) T * d);
    float * cv = need(s, &s->cv, (size_t) T * d);
    const int ntb = ore_frame_blocks(T), hd = d / m->n_heads;
    for (int i = 0; i < s->n_threads; ++i) {
        need(s, &s->ts[i].ac, (size_t) T * T);
        need(s, &s->ts[i].bd, (size_t) T * (2 * T - 1));
        need(s, &s->ts[i].pk, (size_t) ntb * hd * ORE_FB);
        need(s, &s->ts[i].pk2, (size_t) ntb * T * ORE_FB);
    }
    if (s->oom || !build_positions(s, T)) return 0;
    dump(s, "enc.pre_encode.out", x, T, d);

    for (int l = 0; l < m->n_layers && !s->oom; ++l) {
        const ore_block * b = &m->blocks[l];
        char              name[64];
        if (aborted(s)) return 0;

        // Feed-forward 1, half-weighted.
        layer_norm(s, x, xn, T, d, &b->norm_ff1_w, &b->norm_ff1_b);
        lin_in_set(&s->in_a, xn, (size_t) d, T, d);
        linear(s, &b->ff1_l1, &s->in_a, h, (size_t) dff);
        {
            frame_ctx c = { 0 };
            c.op        = OP_SILU;
            c.n         = dff;
            c.T         = T;
            c.a         = h;
            c.astride   = (size_t) dff;
            c.out       = h;
            c.ostride   = (size_t) dff;
            frames(s, &c);
        }
        lin_in_set(&s->in_a, h, (size_t) dff, T, dff);
        linear(s, &b->ff1_l2, &s->in_a, y, (size_t) d);
        add_into(s, x, y, T, d, 1);
        if (l == 0) dump(s, "enc.block.0.ff1", x, T, d);

        // Self-attention with relative positions.
        layer_norm(s, x, xn, T, d, &b->norm_attn_w, &b->norm_attn_b);
        lin_in_set(&s->in_a, xn, (size_t) d, T, d);
        linear(s, &b->att_q, &s->in_a, q, (size_t) d);
        linear(s, &b->att_k, &s->in_a, kk, (size_t) d);
        linear(s, &b->att_v, &s->in_a, vv, (size_t) d);
        linear(s, &b->att_pos, &s->in_pos, p, (size_t) d);
        {
            frame_ctx c = { 0 };
            c.op        = OP_ADD_VEC2;
            c.n         = d;
            c.T         = T;
            c.a         = q;
            c.astride   = (size_t) d;
            c.out       = qu;
            c.out2      = qv;
            c.ostride   = (size_t) d;
            c.p0        = (const float *) b->pos_u.data;
            c.p1        = (const float *) b->pos_v.data;
            frames(s, &c);
            tr_ctx tc = { vv, vt, T, d };
            ore_parallel_for(s->pool, d, 64, job_transpose, &tc);
            att_ctx ac = { s, T };
            ore_parallel_for(s->pool, m->n_heads, 1, job_heads, &ac);
        }
        lin_in_set(&s->in_a, o, (size_t) d, T, d);
        linear(s, &b->att_out, &s->in_a, y, (size_t) d);
        add_into(s, x, y, T, d, 0);
        if (l == 0) dump(s, "enc.block.0.attn", x, T, d);

        // Convolution module.
        layer_norm(s, x, xn, T, d, &b->norm_conv_w, &b->norm_conv_b);
        lin_in_set(&s->in_a, xn, (size_t) d, T, d);
        linear(s, &b->pw1, &s->in_a, h, (size_t) (2 * d));
        {
            frame_ctx c = { 0 };
            c.op        = OP_GLU;
            c.n         = d;
            c.T         = T;
            c.a         = h;
            c.astride   = (size_t) (2 * d);
            c.out       = gl;
            c.ostride   = (size_t) d;
            frames(s, &c);
            c.op      = OP_DWCONV;
            c.a       = gl;
            c.astride = (size_t) d;
            c.out     = cv;
            c.blk     = b;
            frames(s, &c);
        }
        lin_in_set(&s->in_a, cv, (size_t) d, T, d);
        linear(s, &b->pw2, &s->in_a, y, (size_t) d);
        add_into(s, x, y, T, d, 0);
        if (l == 0) dump(s, "enc.block.0.conv", x, T, d);

        // Feed-forward 2, half-weighted.
        layer_norm(s, x, xn, T, d, &b->norm_ff2_w, &b->norm_ff2_b);
        lin_in_set(&s->in_a, xn, (size_t) d, T, d);
        linear(s, &b->ff2_l1, &s->in_a, h, (size_t) dff);
        {
            frame_ctx c = { 0 };
            c.op        = OP_SILU;
            c.n         = dff;
            c.T         = T;
            c.a         = h;
            c.astride   = (size_t) dff;
            c.out       = h;
            c.ostride   = (size_t) dff;
            frames(s, &c);
        }
        lin_in_set(&s->in_a, h, (size_t) dff, T, dff);
        linear(s, &b->ff2_l2, &s->in_a, y, (size_t) d);
        add_into(s, x, y, T, d, 1);
        if (l == 0) dump(s, "enc.block.0.ff2", x, T, d);

        layer_norm(s, x, x, T, d, &b->norm_out_w, &b->norm_out_b);
        if (s->dump) {
            snprintf(name, sizeof name, "enc.block.%d.out", l);
            dump(s, name, x, T, d);
        }
    }
    if (s->oom) return 0;
    dump(s, "enc.final", x, T, d);
    s->t_encode += ore_now_ms() - t0;
    *enc   = x;
    *T_out = T;
    return 1;
}
