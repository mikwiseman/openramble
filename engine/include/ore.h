// ore.h - OpenRamble's speech recognition engine.
//
// Runs NVIDIA Parakeet TDT models (FastConformer encoder, transducer decoder)
// from the GGUF files OpenRamble ships, on the CPU, on any 64-bit x86 or Arm
// processor. Plain C, no dependencies, no network, no files other than the
// model it is given.
//
//   ore_model *   m = ore_model_open("parakeet-ultra-Q4_K_M.gguf", NULL);
//   ore_session * s = ore_session_open(m, 0);
//   if (ore_run(s, samples, n_samples) == ORE_OK) puts(ore_text(s));
//   ore_session_close(s);
//   ore_model_close(m);
//
// A model may be shared by any number of sessions on any threads. A session
// is used by one thread at a time.
#ifndef ORE_H
#define ORE_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct ore_model   ore_model;
typedef struct ore_session ore_session;

typedef enum {
    ORE_OK          = 0,
    ORE_ERR_INVALID = 1,  // a NULL argument, or a clip the model cannot take
    ORE_ERR_MEMORY  = 2,
    ORE_ERR_ABORTED = 3,  // the abort callback returned nonzero
} ore_status;

// The version of this library, for example "0.1.0".
const char * ore_version(void);

// Opens a model file. The file is memory-mapped and must stay in place,
// unchanged, until the model is closed. Returns NULL on failure; `error`, when
// not NULL, then receives a short description that stays valid forever.
ore_model * ore_model_open(const char * path, const char ** error);
void        ore_model_close(ore_model * model);

// Opens a session. `threads` is the number of threads one recognition may
// use; 0 picks a default for this machine. Returns NULL when out of memory.
ore_session * ore_session_open(const ore_model * model, int threads);
void          ore_session_close(ore_session * session);

// Words and names to favour, as they should be written. The strings are
// copied. Passing NULL or 0 clears the list.
ore_status ore_session_set_vocabulary(ore_session * session, const char * const * terms, int n_terms);

// `callback` is asked between steps of a recognition; a nonzero answer stops
// it and ore_run returns ORE_ERR_ABORTED. Pass NULL to remove it.
void ore_session_set_abort(ore_session * session, int (*callback)(void * user), void * user);

// Recognizes one clip: mono, 16 kHz, samples in [-1, 1]. The result replaces
// the session's previous one. A clip too short to hold speech gives ORE_OK and
// empty text.
//
// A clip longer than the model's segment limit (30 s for Parakeet Ultra) is
// cut at pauses with the model's own speech detector and recognized piece by
// piece, as the model's reference implementation does. A model without that
// detector takes clips of at most two minutes; longer ones give
// ORE_ERR_INVALID.
ore_status ore_run(ore_session * session, const float * samples, int n_samples);

// The result of the last ore_run. Strings are UTF-8 and stay valid until the
// next ore_run on the session or until it is closed.
const char * ore_text(const ore_session * session);

typedef struct {
    const char * text;
    int64_t      t0_ms;  // start and end within the clip
    int64_t      t1_ms;
} ore_word;

int ore_word_count(const ore_session * session);
// Fills `out` and returns 1, or returns 0 when `index` is out of range.
int ore_word_at(const ore_session * session, int index, ore_word * out);

typedef struct {
    int32_t      id;
    float        confidence;  // 0..1
    int64_t      t0_ms;
    int64_t      t1_ms;
    const char * text;
} ore_token;

int ore_token_count(const ore_session * session);
int ore_token_at(const ore_session * session, int index, ore_token * out);

// How long each stage of the last ore_run took, in milliseconds.
typedef struct {
    double mel_ms;
    double encode_ms;
    double decode_ms;
} ore_timings;
void ore_last_timings(const ore_session * session, ore_timings * out);

// The instruction set the session computes with ("neon", "avx2", "generic")
// and its thread count, for logs and reports.
const char * ore_session_kernels(const ore_session * session);
int          ore_session_threads(const ore_session * session);

#ifdef __cplusplus
}
#endif

#endif  // ORE_H
