// ore_internal.h - the model and session as the engine's own files see them.
#ifndef ORE_INTERNAL_H
#define ORE_INTERNAL_H

#include "ore_gguf.h"
#include "ore_kernels.h"
#include "ore_mel.h"
#include "ore_threads.h"

#include <stdlib.h>

#define ORE_MAX_THREADS 64
#define ORE_MAX_DURATIONS 16

typedef struct {
    ore_tensor norm_ff1_w, norm_ff1_b, ff1_l1, ff1_l2;
    ore_tensor norm_attn_w, norm_attn_b, att_q, att_k, att_v, att_out, att_pos, pos_u, pos_v;
    ore_tensor norm_conv_w, norm_conv_b, pw1, pw2;
    ore_tensor norm_ff2_w, norm_ff2_b, ff2_l1, ff2_l2;
    ore_tensor norm_out_w, norm_out_b;
    float *    bn_scale;  // batch norm folded into one multiply and one add
    float *    bn_bias;
    float *    dw_t;      // depthwise kernel, [tap][channel]
} ore_block;

typedef struct {
    int          n_tokens;      // vocabulary size including blank
    const char ** piece;        // into the model file, not NUL-terminated
    uint32_t *   piece_len;
    float *      score;
    uint8_t *    type;          // 1 normal, 2 unknown, 3 control, ...
    int          unk_id;
    // lookup for encoding terms: pieces sorted by bytes
    int *        sorted;
} ore_vocab;

struct ore_model {
    ore_gguf * g;
    // encoder
    int         n_layers, d_model, n_heads, d_ff, conv_kernel, n_mels, sub_ch;
    ore_mel     mel;
    ore_tensor  c0w, c0b, c2b, c3w, c3b, c5b, c6w, c6b, pre_out_w, pre_out_b;
    float *     c2_t;  // depthwise 3x3 kernels, [tap][channel]
    float *     c5_t;
    ore_block * blocks;
    // decoder, all single precision
    int     pred_hidden, pred_layers, joint_hidden, joint_n, n_token_cls, blank_id;
    int     n_dur, durations[ORE_MAX_DURATIONS], max_symbols, global_budget;
    float * embed;    // [n_token_cls][pred_hidden]
    float * lstm_wx;  // [layers][4H][H]
    float * lstm_wh;
    float * lstm_b;   // [layers][4H]
    float * enc_w;    // [joint_hidden][d_model]
    float * enc_b;
    float * pred_w;   // [joint_hidden][pred_hidden]
    float * pred_b;
    float * out_w;    // [joint_n][joint_hidden]
    float * out_b;
    ore_vocab vocab;
};

// A growable, 64-byte aligned buffer of floats.
typedef struct {
    float * p;
    size_t  cap;
} ore_buf;

ORE_INLINE float * ore_buf_need(ore_buf * b, size_t n) {
    if (n > b->cap) {
        ore_free(b->p);
        b->p   = (float *) ore_alloc(n * sizeof(float));
        b->cap = b->p ? n : 0;
    }
    return b->p;
}

// The input of a matrix product, with whichever prepared forms the weight
// types that consume it have asked for.
typedef struct {
    const float * x;
    size_t        stride;
    int           rows, n;
    ore_qact      q8k, q80;
    ore_buf       xp;
    int           have_q8k, have_q80, have_xp;
} ore_lin_in;

typedef struct {
    ore_buf ac, bd, pk, pk2, f;  // attention scores and packed operands; f: weight-row scratch
    ore_buf pre[8];              // subsampling bands
} ore_thread_scratch;

// One emitted token before it is turned into text.
typedef struct {
    int   id;
    float p;
    int   step;      // encoder frame it was emitted at
    int   duration;  // frames the model said it spans
} ore_raw_token;

struct ore_boost;

typedef struct {
    ore_buf         enc_proj, state, logits, probs, boosted, gates, recur, act, x;
    ore_raw_token * raw;
    int             n_raw, cap_raw;
    struct ore_boost * boost;  // NULL when no vocabulary is set
} ore_dec;

typedef void (*ore_dump_fn)(void * user, const char * name, const float * data, int rows, int cols);

struct ore_session {
    const struct ore_model * m;
    const ore_kernels *      k;
    ore_pool *               pool;
    int                      n_threads;
    // encoder state
    ore_buf            mel, flat, x, xn, h, y, q, kk, v, vt, p, qu, qv, o, gl, cv, pos;
    int                pos_T;  // frames the positional table was built for
    ore_lin_in         in_a, in_pos;
    ore_thread_scratch ts[ORE_MAX_THREADS];
    int                oom;
    // abort
    int (*abort_fn)(void * user);
    void * abort_user;
    // timings of the last run, milliseconds
    double t_mel, t_encode, t_decode;
    // debugging
    ore_dump_fn dump;
    void *      dump_user;
    ore_dec dec;
    void *  res;  // the public result, see ore.c
};

// Greedy TDT decoding of [T][d_model] encoder frames into dec->raw.
// Returns 0 when out of memory or aborted.
int ore_decode(struct ore_session * s, const float * enc, int T);

// Builds the automaton that favours `terms`; replaces any previous one.
// Returns 0 when out of memory.
int  ore_boost_set(struct ore_session * s, const char * const * terms, int n_terms);
void ore_boost_free(struct ore_boost * b);

// A piece's bytes with the word-boundary marker written as a space, appended
// to out (which has room for 4 * len + 1). Returns the bytes written.
size_t ore_piece_text(const struct ore_model * m, int id, char * out);
// Control, unknown and language-tag pieces, which never reach the transcript.
int ore_piece_is_special(const struct ore_model * m, int id);
// True when the piece opens a new word.
int ore_piece_starts_word(const struct ore_model * m, int id);

struct ore_model * ore_model_open_internal(const char * path, const char ** err);
void               ore_model_close_internal(struct ore_model * m);

// Runs the mel front end and the encoder. On success *enc points at
// [*T][d_model] floats owned by the session. Returns 0 on failure
// (out of memory, clip too short, or aborted).
int ore_encode(struct ore_session * s, const float * pcm, int n_samples, const float ** enc, int * T);

double ore_now_ms(void);

#endif  // ORE_INTERNAL_H
