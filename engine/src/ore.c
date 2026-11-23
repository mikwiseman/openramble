// ore.c - the public interface: models, sessions, and turning the decoder's
// tokens into text, words and times.
#include "ore.h"

#include "ore_internal.h"

#define ORE_VERSION "0.1.0"

const char * ore_version(void) { return ORE_VERSION; }

// ---- result -------------------------------------------------------------------

typedef struct {
    int     id;
    float   p;
    int64_t t0, t1;
    size_t  text;  // offset into the arena
} res_token;

typedef struct {
    int64_t t0, t1;
    size_t  text;
} res_word;

typedef struct {
    char *      arena;  // NUL-terminated strings, one after another
    size_t      len, cap;
    char *      text;   // the whole transcript
    size_t      text_len, text_cap;
    res_token * tok;
    int         n_tok, cap_tok;
    res_word *  word;
    int         n_word, cap_word;
} ore_result;

static char * arena_room(ore_result * r, size_t n) {
    if (r->len + n > r->cap) {
        size_t cap = r->cap ? r->cap * 2 : 1024;
        while (cap < r->len + n) cap *= 2;
        char * a = (char *) realloc(r->arena, cap);
        if (!a) return NULL;
        r->arena = a;
        r->cap   = cap;
    }
    return r->arena + r->len;
}

static char * text_room(ore_result * r, size_t n) {
    if (r->text_len + n > r->text_cap) {
        size_t cap = r->text_cap ? r->text_cap * 2 : 1024;
        while (cap < r->text_len + n) cap *= 2;
        char * a = (char *) realloc(r->text, cap);
        if (!a) return NULL;
        r->text     = a;
        r->text_cap = cap;
    }
    return r->text + r->text_len;
}

static int result_clear(ore_result * r) {
    r->len = r->text_len = 0;
    r->n_tok = r->n_word = 0;
    char * t             = text_room(r, 1);
    if (!t) return 0;
    t[0] = 0;
    return 1;
}

// Appends the decoder's raw tokens as tokens, words and transcript text. For
// a piece of a long clip, `offset_ms` moves the times to the piece's place in
// the clip and `end_ms` (when not negative) is the piece's end, which no time
// may pass.
static int result_append(struct ore_session * s, double offset_ms, double end_ms) {
    const struct ore_model * m = s->m;
    ore_result *             r = (ore_result *) s->res;
    const ore_dec *          d = &s->dec;
    // One encoder frame is 8 mel hops.
    const double frame_ms = 1000.0 * 8.0 * (double) m->mel.hop_length / (double) m->mel.sample_rate;
    const int    first    = r->n_tok;

    for (int i = 0; i < d->n_raw; ++i) {
        const ore_raw_token * rt = &d->raw[i];
        if (ore_piece_is_special(m, rt->id)) continue;
        if (r->n_tok == r->cap_tok) {
            const int   cap = r->cap_tok ? r->cap_tok * 2 : 256;
            res_token * nt  = (res_token *) realloc(r->tok, sizeof(res_token) * (size_t) cap);
            if (!nt) return 0;
            r->tok     = nt;
            r->cap_tok = cap;
        }
        char * dst = arena_room(r, (size_t) m->vocab.piece_len[rt->id] + 2);
        if (!dst) return 0;
        const size_t n = ore_piece_text(m, rt->id, dst);
        dst[n]         = 0;
        res_token * t  = &r->tok[r->n_tok++];
        t->id          = rt->id;
        t->p           = rt->p;
        t->t0          = (int64_t) llround(frame_ms * (double) rt->step);
        t->t1          = (int64_t) llround(frame_ms * ((double) rt->step + (double) rt->duration));
        if (end_ms >= 0.0) {
            const double a = (double) t->t0 + offset_ms, b = (double) t->t1 + offset_ms;
            t->t0          = (int64_t) llround(a < end_ms ? a : end_ms);
            t->t1          = (int64_t) llround(b < end_ms ? b : end_ms);
        }
        t->text = r->len;
        r->len += n + 1;
    }
    if (r->n_tok == first) return 1;

    // Words: the first token opens one, and so does every piece that begins
    // with the word marker. A word's text is its pieces without the leading
    // space.
    for (int i = first; i < r->n_tok;) {
        int j = i + 1;
        while (j < r->n_tok && !ore_piece_starts_word(m, r->tok[j].id)) ++j;
        size_t bytes = 1;
        for (int q = i; q < j; ++q) bytes += strlen(r->arena + r->tok[q].text);
        if (r->n_word == r->cap_word) {
            const int  cap = r->cap_word ? r->cap_word * 2 : 128;
            res_word * nw  = (res_word *) realloc(r->word, sizeof(res_word) * (size_t) cap);
            if (!nw) return 0;
            r->word     = nw;
            r->cap_word = cap;
        }
        char * dst = arena_room(r, bytes);
        if (!dst) return 0;
        size_t w = 0;
        for (int q = i; q < j; ++q) {
            const char * tx = r->arena + r->tok[q].text;
            const size_t n  = strlen(tx);
            memcpy(dst + w, tx, n);
            w += n;
        }
        dst[w]        = 0;
        res_word * wd = &r->word[r->n_word++];
        wd->t0        = r->tok[i].t0;
        wd->t1        = r->tok[j - 1].t1;
        wd->text      = r->len + ((w > 0 && dst[0] == ' ') ? 1 : 0);
        r->len += w + 1;
        i = j;
    }

    // The transcript: this piece's text with runs of spaces collapsed and the
    // ends trimmed, joined to what came before by one space.
    size_t bytes = 2;
    for (int i = first; i < r->n_tok; ++i) bytes += strlen(r->arena + r->tok[i].text);
    char * dst = text_room(r, bytes);
    if (!dst) return 0;
    size_t w = 0;
    if (r->text_len > 0) dst[w++] = ' ';
    const size_t start = w;
    for (int i = first; i < r->n_tok; ++i) {
        for (const char * c = r->arena + r->tok[i].text; *c; ++c) {
            if (*c == ' ' && (w == start || dst[w - 1] == ' ')) continue;
            dst[w++] = *c;
        }
    }
    while (w > start && dst[w - 1] == ' ') --w;
    if (w == start) w = 0;  // nothing but spaces: no separator either
    dst[w] = 0;
    r->text_len += w;
    return 1;
}

// ---- model ----------------------------------------------------------------------

ore_model * ore_model_open(const char * path, const char ** error) {
    if (!path) {
        if (error) *error = "no path";
        return NULL;
    }
    return ore_model_open_internal(path, error);
}

void ore_model_close(ore_model * model) { ore_model_close_internal(model); }

// ---- session --------------------------------------------------------------------

// For the tools and tests: a session on a named kernel table.
ore_session * ore_session_open_kernels(const ore_model * model, int threads, const char * kernels) {
    if (!model) return NULL;
    const ore_kernels * k = kernels ? ore_kernels_named(kernels) : ore_kernels_pick();
    if (!k) return NULL;
    ore_session * s = (ore_session *) calloc(1, sizeof(*s));
    if (!s) return NULL;
    s->m    = model;
    s->k    = k;
    s->pool = ore_pool_new(threads);
    s->res  = calloc(1, sizeof(ore_result));
    if (!s->pool || !s->res) {
        ore_session_close(s);
        return NULL;
    }
    s->n_threads = ore_pool_threads(s->pool);
    result_clear((ore_result *) s->res);
    return s;
}

ore_session * ore_session_open(const ore_model * model, int threads) {
    return ore_session_open_kernels(model, threads, NULL);
}

void ore_session_close(ore_session * s) {
    if (!s) return;
    ore_pool_free(s->pool);
    ore_buf * bufs[] = { &s->mel, &s->flat, &s->x,  &s->xn, &s->h,  &s->y,  &s->q,  &s->kk, &s->v,
                         &s->vt,  &s->p,    &s->qu, &s->qv, &s->o,  &s->gl, &s->cv, &s->pos };
    for (size_t i = 0; i < sizeof(bufs) / sizeof(bufs[0]); ++i) ore_free(bufs[i]->p);
    ore_qact_free(&s->in_a.q8k);
    ore_qact_free(&s->in_a.q80);
    ore_free(s->in_a.xp.p);
    ore_qact_free(&s->in_pos.q8k);
    ore_qact_free(&s->in_pos.q80);
    ore_free(s->in_pos.xp.p);
    for (int i = 0; i < ORE_MAX_THREADS; ++i) {
        ore_thread_scratch * t = &s->ts[i];
        ore_free(t->ac.p);
        ore_free(t->bd.p);
        ore_free(t->pk.p);
        ore_free(t->pk2.p);
        ore_free(t->f.p);
        for (int j = 0; j < 8; ++j) ore_free(t->pre[j].p);
    }
    ore_dec * d      = &s->dec;
    ore_buf * dbuf[] = { &d->enc_proj, &d->state, &d->logits, &d->probs, &d->boosted, &d->gates, &d->recur, &d->act, &d->x };
    for (size_t i = 0; i < sizeof(dbuf) / sizeof(dbuf[0]); ++i) ore_free(dbuf[i]->p);
    free(d->raw);
    ore_boost_free(d->boost);
    ore_result * r = (ore_result *) s->res;
    if (r) {
        free(r->arena);
        free(r->text);
        free(r->tok);
        free(r->word);
        free(r);
    }
    free(s);
}

ore_status ore_session_set_vocabulary(ore_session * s, const char * const * terms, int n_terms) {
    if (!s) return ORE_ERR_INVALID;
    return ore_boost_set(s, terms, n_terms) ? ORE_OK : ORE_ERR_MEMORY;
}

void ore_session_set_abort(ore_session * s, int (*callback)(void * user), void * user) {
    if (!s) return;
    s->abort_fn   = callback;
    s->abort_user = user;
}

void ore_session_set_dump(ore_session * s, ore_dump_fn fn, void * user) {
    s->dump      = fn;
    s->dump_user = user;
}

static ore_status failure(const ore_session * s) {
    if (s->abort_fn && s->abort_fn(s->abort_user)) return ORE_ERR_ABORTED;
    return s->oom ? ORE_ERR_MEMORY : ORE_ERR_INVALID;
}

// One stretch of audio, short enough to recognize whole.
static ore_status run_piece(ore_session * s, const float * samples, int n_samples, double offset_ms, double end_ms) {
    s->dec.n_raw = 0;
    // Fewer than three mel frames cannot be normalized, and hold no word.
    if (ore_mel_frames(&s->m->mel, n_samples) < 3) return ORE_OK;
    const float * enc = NULL;
    int           T   = 0;
    if (!ore_encode(s, samples, n_samples, &enc, &T)) return failure(s);
    const double t0 = ore_now_ms();
    if (!ore_decode(s, enc, T)) {
        if (s->abort_fn && s->abort_fn(s->abort_user)) return ORE_ERR_ABORTED;
        return ORE_ERR_MEMORY;
    }
    if (!result_append(s, offset_ms, end_ms)) return ORE_ERR_MEMORY;
    s->t_decode += ore_now_ms() - t0;
    return ORE_OK;
}

ore_status ore_run(ore_session * s, const float * samples, int n_samples) {
    if (!s || !samples || n_samples < 0) return ORE_ERR_INVALID;
    const struct ore_model * m = s->m;
    s->dec.n_raw               = 0;
    s->oom                     = 0;
    s->t_mel = s->t_encode = s->t_decode = 0.0;
    if (!result_clear((ore_result *) s->res)) return ORE_ERR_MEMORY;

    if (!ore_needs_segments(m, n_samples)) {
        // Attention over a whole clip needs memory that grows with the square
        // of its length. A model with no rule for cutting long audio is given
        // at most two minutes.
        if (!m->has_vad && n_samples > 120 * m->mel.sample_rate) return ORE_ERR_INVALID;
        return run_piece(s, samples, n_samples, 0.0, -1.0);
    }

    // Longer than one segment: cut at pauses, recognize each piece as a clip
    // of its own, and join the results.
    ore_segment * seg   = NULL;
    int           n_seg = 0;
    if (!ore_segments(s, samples, n_samples, &seg, &n_seg)) return failure(s);
    ore_status   st   = ORE_OK;
    const double rate = (double) m->mel.sample_rate;
    for (int i = 0; i < n_seg && st == ORE_OK; ++i) {
        if (s->abort_fn && s->abort_fn(s->abort_user)) {
            st = ORE_ERR_ABORTED;
            break;
        }
        st = run_piece(s, samples + seg[i].start, (int) seg[i].n_samples, 1000.0 * (double) seg[i].start / rate,
                       1000.0 * (double) (seg[i].start + seg[i].n_samples) / rate);
    }
    free(seg);
    if (st != ORE_OK) result_clear((ore_result *) s->res);
    return st;
}

const char * ore_text(const ore_session * s) {
    const ore_result * r = s ? (const ore_result *) s->res : NULL;
    return (r && r->text) ? r->text : "";
}

int ore_word_count(const ore_session * s) { return s ? ((const ore_result *) s->res)->n_word : 0; }

int ore_word_at(const ore_session * s, int index, ore_word * out) {
    const ore_result * r = s ? (const ore_result *) s->res : NULL;
    if (!r || !out || index < 0 || index >= r->n_word) return 0;
    out->text  = r->arena + r->word[index].text;
    out->t0_ms = r->word[index].t0;
    out->t1_ms = r->word[index].t1;
    return 1;
}

int ore_token_count(const ore_session * s) { return s ? ((const ore_result *) s->res)->n_tok : 0; }

int ore_token_at(const ore_session * s, int index, ore_token * out) {
    const ore_result * r = s ? (const ore_result *) s->res : NULL;
    if (!r || !out || index < 0 || index >= r->n_tok) return 0;
    out->id         = r->tok[index].id;
    out->confidence = r->tok[index].p;
    out->t0_ms      = r->tok[index].t0;
    out->t1_ms      = r->tok[index].t1;
    out->text       = r->arena + r->tok[index].text;
    return 1;
}

void ore_last_timings(const ore_session * s, ore_timings * out) {
    if (!s || !out) return;
    out->mel_ms    = s->t_mel;
    out->encode_ms = s->t_encode;
    out->decode_ms = s->t_decode;
}

const char * ore_session_kernels(const ore_session * s) { return s ? s->k->name : ""; }
const char * ore_processor_kernels(void) { return ore_kernels_pick()->name; }
int          ore_session_threads(const ore_session * s) { return s ? s->n_threads : 0; }
