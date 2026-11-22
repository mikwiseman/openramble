// ore_decoder.c - the transducer decoder: a two-layer LSTM over the tokens
// written so far, a joint network that scores the next token and how many
// frames to skip, and the greedy loop over them. Also the tokenizer's two
// directions and the automaton that favours taught words.
#include "ore_internal.h"

// ---- pieces -------------------------------------------------------------------

static const char   k_marker[]   = "\xE2\x96\x81";  // U+2581, opens a word
static const size_t k_marker_len = 3;

static int hex_nibble(char c) {
    if (c >= '0' && c <= '9') return c - '0';
    if (c >= 'A' && c <= 'F') return 10 + (c - 'A');
    if (c >= 'a' && c <= 'f') return 10 + (c - 'a');
    return -1;
}

size_t ore_piece_text(const struct ore_model * m, int id, char * out) {
    if (id < 0 || id >= m->vocab.n_tokens) return 0;
    const char * p = m->vocab.piece[id];
    const size_t n = m->vocab.piece_len[id];
    // "<0xHH>" stands for one raw byte.
    if (n == 6 && p[0] == '<' && p[1] == '0' && p[2] == 'x' && p[5] == '>') {
        const int hi = hex_nibble(p[3]), lo = hex_nibble(p[4]);
        if (hi >= 0 && lo >= 0) {
            out[0] = (char) ((hi << 4) | lo);
            return 1;
        }
    }
    size_t w = 0;
    for (size_t j = 0; j < n;) {
        if (j + k_marker_len <= n && memcmp(p + j, k_marker, k_marker_len) == 0) {
            out[w++] = ' ';
            j += k_marker_len;
        } else {
            out[w++] = p[j++];
        }
    }
    return w;
}

int ore_piece_starts_word(const struct ore_model * m, int id) {
    if (id < 0 || id >= m->vocab.n_tokens) return 0;
    return m->vocab.piece_len[id] >= k_marker_len && memcmp(m->vocab.piece[id], k_marker, k_marker_len) == 0;
}

// "<ll-RR>": two or three lower-case letters, a dash, two to four letters.
static int is_lang_tag(const char * p, size_t n) {
    if (n < 7 || p[0] != '<' || p[n - 1] != '>') return 0;
    size_t i = 1, end = n - 1, lang = 0, reg = 0;
    while (i < end && p[i] >= 'a' && p[i] <= 'z') {
        ++i;
        ++lang;
    }
    if (lang < 2 || lang > 3 || i >= end || p[i] != '-') return 0;
    ++i;
    while (i < end && ((p[i] >= 'a' && p[i] <= 'z') || (p[i] >= 'A' && p[i] <= 'Z'))) {
        ++i;
        ++reg;
    }
    return reg >= 2 && reg <= 4 && i == end;
}

int ore_piece_is_special(const struct ore_model * m, int id) {
    if (id < 0 || id >= m->vocab.n_tokens) return 1;
    const char * p = m->vocab.piece[id];
    const size_t n = m->vocab.piece_len[id];
    if (m->vocab.type[id] == 3 || m->vocab.type[id] == 2 || id == m->vocab.unk_id) return 1;
    if (n == 5 && memcmp(p, "<unk>", 5) == 0) return 1;
    return is_lang_tag(p, n);
}

// ---- encoding a term into pieces (SentencePiece BPE) -----------------------------

typedef struct {
    const char * s;
    size_t       n;
} span_t;

static uint32_t hash_bytes(const char * s, size_t n) {
    uint32_t h = 2166136261u;
    for (size_t i = 0; i < n; ++i) h = (h ^ (uint8_t) s[i]) * 16777619u;
    return h;
}

// Open-addressing table from piece bytes to the lowest id that spells them.
// Control and unknown pieces never match text.
typedef struct {
    int *    slot;
    uint32_t mask;
} piece_map;

static int piece_map_build(const struct ore_model * m, piece_map * pm) {
    uint32_t cap = 64;
    while (cap < (uint32_t) m->vocab.n_tokens * 2u) cap *= 2;
    pm->slot = (int *) malloc(sizeof(int) * cap);
    if (!pm->slot) return 0;
    pm->mask = cap - 1;
    for (uint32_t i = 0; i < cap; ++i) pm->slot[i] = -1;
    for (int id = 0; id < m->vocab.n_tokens; ++id) {
        const char * p = m->vocab.piece[id];
        const size_t n = m->vocab.piece_len[id];
        if (n == 0 || m->vocab.type[id] == 2 || m->vocab.type[id] == 3) continue;
        if (n == 5 && memcmp(p, "<unk>", 5) == 0) continue;
        uint32_t h = hash_bytes(p, n) & pm->mask;
        for (;;) {
            const int o = pm->slot[h];
            if (o < 0) {
                pm->slot[h] = id;
                break;
            }
            if (m->vocab.piece_len[o] == n && memcmp(m->vocab.piece[o], p, n) == 0) break;  // the lower id stays
            h = (h + 1) & pm->mask;
        }
    }
    return 1;
}

static int piece_map_find(const struct ore_model * m, const piece_map * pm, const char * p, size_t n) {
    uint32_t h = hash_bytes(p, n) & pm->mask;
    for (;;) {
        const int o = pm->slot[h];
        if (o < 0) return -1;
        if (m->vocab.piece_len[o] == n && memcmp(m->vocab.piece[o], p, n) == 0) return o;
        h = (h + 1) & pm->mask;
    }
}

// Encodes one term. ids has room for strlen(term) + 2 entries. Returns the
// count, or -1 when the term holds something the model cannot write.
static int encode_term(const struct ore_model * m, const piece_map * pm, const char * term, int * ids) {
    const size_t len = strlen(term);
    // Normalized text: tabs and newlines are spaces, runs collapse, ends are
    // trimmed, a few compatibility characters are spelled out, and every
    // space becomes the marker, with one marker in front.
    char * ws = (char *) malloc(len * 3 + 8);
    if (!ws) return -1;
    size_t w = 0;
    for (size_t i = 0; i < len;) {
        const unsigned char c0 = (unsigned char) term[i];
        if (c0 < 0x80) {
            const char c = (c0 == '\t' || c0 == '\n' || c0 == '\r') ? ' ' : (char) c0;
            if (!(c == ' ' && (w == 0 || ws[w - 1] == ' '))) ws[w++] = c;
            ++i;
            continue;
        }
        size_t l = 1;
        while (i + l < len && ((unsigned char) term[i + l] & 0xC0) == 0x80) ++l;
        uint32_t cp = l == 2 ? (c0 & 0x1Fu) : l == 3 ? (c0 & 0x0Fu) : (c0 & 0x07u);
        for (size_t k = 1; k < l; ++k) cp = (cp << 6) | ((unsigned char) term[i + k] & 0x3Fu);
        if (cp == 0x2026) {
            memcpy(ws + w, "...", 3);
            w += 3;
        } else if (cp == 0x00A0 || cp == 0x3000) {
            if (!(w == 0 || ws[w - 1] == ' ')) ws[w++] = ' ';
        } else if (cp >= 0xFF01 && cp <= 0xFF5E) {
            ws[w++] = (char) (cp - 0xFF01 + 0x21);
        } else if (cp >= 0xFB00 && cp <= 0xFB04) {
            static const char * const lig[] = { "ff", "fi", "fl", "ffi", "ffl" };
            const size_t              ll    = strlen(lig[cp - 0xFB00]);
            memcpy(ws + w, lig[cp - 0xFB00], ll);
            w += ll;
        } else {
            memcpy(ws + w, term + i, l);
            w += l;
        }
        i += l;
    }
    while (w > 0 && ws[w - 1] == ' ') --w;
    if (w == 0) {
        free(ws);
        return 0;
    }
    // Symbols: the marker, then one per character (a space is the marker).
    // They are kept as one growing string with split points.
    char *   text = (char *) malloc(w * 3 + 8);
    span_t * sym  = (span_t *) malloc(sizeof(span_t) * (w + 2));
    if (!text || !sym) {
        free(ws);
        free(text);
        free(sym);
        return -1;
    }
    size_t tn = 0;
    int    ns = 0;
    memcpy(text, k_marker, k_marker_len);
    sym[ns].s = text;
    sym[ns].n = k_marker_len;
    ++ns;
    tn = k_marker_len;
    for (size_t i = 0; i < w;) {
        size_t j = i + 1;
        while (j < w && ((unsigned char) ws[j] & 0xC0) == 0x80) ++j;
        sym[ns].s = text + tn;
        if (ws[i] == ' ') {
            memcpy(text + tn, k_marker, k_marker_len);
            sym[ns].n = k_marker_len;
            tn += k_marker_len;
        } else {
            memcpy(text + tn, ws + i, j - i);
            sym[ns].n = j - i;
            tn += j - i;
        }
        ++ns;
        i = j;
    }
    free(ws);
    // Greedy merges: the adjacent pair whose joined bytes are the piece with
    // the lowest id, leftmost on ties. Symbols are contiguous in `text`, so a
    // merged pair is just a longer span.
    for (;;) {
        int best_at = -1, best_id = 0x7fffffff;
        for (int i = 0; i + 1 < ns; ++i) {
            const int id = piece_map_find(m, pm, sym[i].s, sym[i].n + sym[i + 1].n);
            if (id >= 0 && id < best_id) {
                best_id = id;
                best_at = i;
            }
        }
        if (best_at < 0) break;
        sym[best_at].n += sym[best_at + 1].n;
        memmove(sym + best_at + 1, sym + best_at + 2, sizeof(span_t) * (size_t) (ns - best_at - 2));
        --ns;
    }
    int n = 0, unknown = 0;
    for (int i = 0; i < ns; ++i) {
        const int id = piece_map_find(m, pm, sym[i].s, sym[i].n);
        if (id < 0) unknown = 1;
        ids[n++] = id;
    }
    free(text);
    free(sym);
    return unknown ? -1 : n;
}

// ---- favouring taught words ---------------------------------------------------------
//
// An Aho-Corasick automaton over the terms' pieces. Being part-way through a
// term earns a bonus per piece after the first; leaving a term unfinished
// takes the bonus back, finishing it keeps it. The bonus re-ranks tokens only
// when the model has already decided to write one.

typedef struct {
    int   token, target;
    float delta;
} boost_edge;

typedef struct {
    int *        ctok;  // children, sorted by token
    int *        cnode;
    int          nc;
    int          fail;
    float        earned, locked;
    int          end;
    boost_edge * edge;  // sorted by token
    int          ne;
} boost_node;

struct ore_boost {
    boost_node * node;
    int          n, cap;
    float        score;
    int          state;
};

#define ORE_VOCABULARY_BOOST 8.0f

static int boost_child(const struct ore_boost * b, int state, int token) {
    const boost_node * nd = &b->node[state];
    int                lo = 0, hi = nd->nc;
    while (lo < hi) {
        const int mid = (lo + hi) / 2;
        if (nd->ctok[mid] < token) {
            lo = mid + 1;
        } else {
            hi = mid;
        }
    }
    return (lo < nd->nc && nd->ctok[lo] == token) ? nd->cnode[lo] : -1;
}

static int boost_add_node(struct ore_boost * b) {
    if (b->n == b->cap) {
        const int    cap = b->cap ? b->cap * 2 : 64;
        boost_node * nn  = (boost_node *) realloc(b->node, sizeof(boost_node) * (size_t) cap);
        if (!nn) return -1;
        b->node = nn;
        b->cap  = cap;
    }
    memset(&b->node[b->n], 0, sizeof(boost_node));
    return b->n++;
}

static int boost_add_child(struct ore_boost * b, int state, int token, int target) {
    boost_node * nd = &b->node[state];
    int *        ct = (int *) realloc(nd->ctok, sizeof(int) * (size_t) (nd->nc + 1));
    if (!ct) return 0;
    nd->ctok = ct;
    int * cn = (int *) realloc(nd->cnode, sizeof(int) * (size_t) (nd->nc + 1));
    if (!cn) return 0;
    nd->cnode = cn;
    int at    = nd->nc;
    while (at > 0 && nd->ctok[at - 1] > token) {
        nd->ctok[at]  = nd->ctok[at - 1];
        nd->cnode[at] = nd->cnode[at - 1];
        --at;
    }
    nd->ctok[at]  = token;
    nd->cnode[at] = target;
    ++nd->nc;
    return 1;
}

void ore_boost_free(struct ore_boost * b) {
    if (!b) return;
    for (int i = 0; i < b->n; ++i) {
        free(b->node[i].ctok);
        free(b->node[i].cnode);
        free(b->node[i].edge);
    }
    free(b->node);
    free(b);
}

static int boost_edge_find(const boost_node * nd, int token) {
    int lo = 0, hi = nd->ne;
    while (lo < hi) {
        const int mid = (lo + hi) / 2;
        if (nd->edge[mid].token < token) {
            lo = mid + 1;
        } else {
            hi = mid;
        }
    }
    return lo;
}

static int boost_next(const struct ore_boost * b, int state, int token) {
    const boost_node * nd = &b->node[state];
    const int          at = boost_edge_find(nd, token);
    return (at < nd->ne && nd->edge[at].token == token) ? nd->edge[at].target : 0;
}

static void boost_apply(const struct ore_boost * b, int state, float * logits, int n, int blank) {
    const boost_node * nd   = &b->node[state];
    const float        base = nd->locked - nd->earned;
    if (base != 0.0f) {
        for (int t = 0; t < n; ++t) {
            if (t != blank) logits[t] += base;
        }
    }
    for (int i = 0; i < nd->ne; ++i) {
        const boost_edge * e = &nd->edge[i];
        if (e->token >= 0 && e->token < n && e->token != blank) logits[e->token] += e->delta - base;
    }
}

int ore_boost_set(struct ore_session * s, const char * const * terms, int n_terms) {
    const struct ore_model * m = s->m;
    ore_boost_free(s->dec.boost);
    s->dec.boost = NULL;
    if (!terms || n_terms <= 0) return 1;
    piece_map pm;
    if (!piece_map_build(m, &pm)) return 0;
    struct ore_boost * b = (struct ore_boost *) calloc(1, sizeof(*b));
    int                ok = b != NULL && boost_add_node(b) == 0;
    if (ok) b->score = ORE_VOCABULARY_BOOST;
    for (int ti = 0; ok && ti < n_terms; ++ti) {
        if (!terms[ti]) continue;
        int * ids = (int *) malloc(sizeof(int) * (strlen(terms[ti]) + 4));
        if (!ids) {
            ok = 0;
            break;
        }
        const int n = encode_term(m, &pm, terms[ti], ids);  // -1: unwritable, skipped
        int       state = 0;
        for (int i = 0; ok && i < n; ++i) {
            int next = boost_child(b, state, ids[i]);
            if (next < 0) {
                next = boost_add_node(b);
                if (next < 0) {
                    ok = 0;
                    break;
                }
                b->node[next].earned = b->node[state].earned + (state == 0 ? 0.0f : b->score);
                if (!boost_add_child(b, state, ids[i], next)) ok = 0;
            }
            state = next;
        }
        if (ok && n > 0) b->node[state].end = 1;
        free(ids);
    }
    free(pm.slot);
    if (ok && b->n > 1) {
        // Failure links and the bonus kept on leaving, breadth first.
        int * queue = (int *) malloc(sizeof(int) * (size_t) b->n);
        ok          = queue != NULL;
        int head = 0, tail = 0;
        if (ok) {
            for (int i = 0; i < b->node[0].nc; ++i) {
                const int c       = b->node[0].cnode[i];
                b->node[c].fail   = 0;
                b->node[c].locked = b->node[c].end ? b->node[c].earned : 0.0f;
                queue[tail++]     = c;
            }
            while (head < tail) {
                const int u = queue[head++];
                for (int i = 0; i < b->node[u].nc; ++i) {
                    const int token = b->node[u].ctok[i], v = b->node[u].cnode[i];
                    int       f = b->node[u].fail;
                    while (f != 0 && boost_child(b, f, token) < 0) f = b->node[f].fail;
                    const int target  = boost_child(b, f, token);
                    b->node[v].fail   = (target >= 0 && target != v) ? target : 0;
                    b->node[v].locked = b->node[v].end ? b->node[v].earned : b->node[u].locked;
                    queue[tail++]     = v;
                }
            }
            free(queue);
        }
        // Every transition out of every state, with what it changes.
        for (int st = 0; ok && st < b->n; ++st) {
            boost_node * from = &b->node[st];
            for (int f = st;; f = b->node[f].fail) {
                for (int i = 0; ok && i < b->node[f].nc; ++i) {
                    const int token = b->node[f].ctok[i], target = b->node[f].cnode[i];
                    const int at = boost_edge_find(from, token);
                    if (at < from->ne && from->edge[at].token == token) continue;
                    boost_edge * ne = (boost_edge *) realloc(from->edge, sizeof(boost_edge) * (size_t) (from->ne + 1));
                    if (!ne) {
                        ok = 0;
                        break;
                    }
                    from->edge = ne;
                    memmove(ne + at + 1, ne + at, sizeof(boost_edge) * (size_t) (from->ne - at));
                    ne[at].token  = token;
                    ne[at].target = target;
                    ne[at].delta  = b->node[target].earned - from->earned + (f == st ? 0.0f : from->locked);
                    ++from->ne;
                }
                if (f == 0) break;
            }
        }
    }
    if (!ok) {
        ore_boost_free(b);
        return 0;
    }
    if (b->n > 1) {
        s->dec.boost = b;
    } else {
        ore_boost_free(b);
    }
    return 1;
}

// ---- the decoder ----------------------------------------------------------------

static int argmax(const float * v, int n) {
    int   bi = 0;
    float bv = v[0];
    for (int i = 1; i < n; ++i) {
        if (v[i] > bv) {
            bv = v[i];
            bi = i;
        }
    }
    return bi;
}

// 1 - entropy / log(classes) of the token distribution.
static float confidence(const float * logits, int n, float * probs) {
    float mx = logits[0];
    for (int i = 1; i < n; ++i) {
        if (logits[i] > mx) mx = logits[i];
    }
    double sum = 0.0;
    for (int i = 0; i < n; ++i) {
        probs[i] = expf(logits[i] - mx);
        sum += (double) probs[i];
    }
    const float inv     = (float) (1.0 / sum);
    double      entropy = 0.0;
    for (int i = 0; i < n; ++i) {
        const float p = probs[i] * inv;
        entropy -= (double) p * log((double) p + 1e-10);
    }
    const double max_entropy = log((double) n);
    if (max_entropy <= 0.0) return 1.0f;
    return (float) (1.0 - entropy / max_entropy);
}

static int push_token(ore_dec * d, int id, float p, int step, int duration) {
    if (d->n_raw == d->cap_raw) {
        const int       cap = d->cap_raw ? d->cap_raw * 2 : 256;
        ore_raw_token * nn  = (ore_raw_token *) realloc(d->raw, sizeof(ore_raw_token) * (size_t) cap);
        if (!nn) return 0;
        d->raw     = nn;
        d->cap_raw = cap;
    }
    d->raw[d->n_raw].id       = id;
    d->raw[d->n_raw].p        = p;
    d->raw[d->n_raw].step     = step;
    d->raw[d->n_raw].duration = duration;
    ++d->n_raw;
    return 1;
}

typedef struct {
    struct ore_session * s;
    const float *        xp;
    int                  T;
    float *              y;
} proj_ctx;
static void job_proj(void * v, int b, int e, int thread) {
    proj_ctx *               c = (proj_ctx *) v;
    const struct ore_model * m = c->s->m;
    c->s->k->gemm_f32(m->enc_w, 0, (size_t) m->d_model, m->d_model, b, e, c->xp, c->T, c->y, (size_t) m->joint_hidden,
                      c->s->ts[thread].f.p);
}

int ore_decode(struct ore_session * s, const float * enc, int T) {
    const struct ore_model * m  = s->m;
    const ore_kernels *      k  = s->k;
    ore_dec *                d  = &s->dec;
    const int                H  = m->pred_hidden, L = m->pred_layers, JH = m->joint_hidden;
    const int                NT = m->n_token_cls, blank = m->blank_id;
    d->n_raw                    = 0;

    float * proj   = ore_buf_need(&d->enc_proj, (size_t) T * JH);
    float * st     = ore_buf_need(&d->state, (size_t) 4 * L * H);
    float * logits = ore_buf_need(&d->logits, (size_t) m->joint_n);
    float * probs  = ore_buf_need(&d->probs, (size_t) NT);
    float * boost  = ore_buf_need(&d->boosted, (size_t) NT);
    float * ga     = ore_buf_need(&d->gates, (size_t) 4 * H);
    float * re     = ore_buf_need(&d->recur, (size_t) 4 * H);
    float * act    = ore_buf_need(&d->act, (size_t) JH);
    float * xin    = ore_buf_need(&d->x, (size_t) H);
    const int ntb  = ore_frame_blocks(T);
    float *   xp   = ore_buf_need(&s->in_a.xp, (size_t) ntb * m->d_model * ORE_FB);
    if (!proj || !st || !logits || !probs || !boost || !ga || !re || !act || !xin || !xp) return 0;

    // The encoder's side of the joint network, for every frame at once.
    ore_pack16(enc, (size_t) m->d_model, T, m->d_model, 0, ntb, xp);
    {
        proj_ctx c = { s, xp, T, proj };
        ore_parallel_for(s->pool, JH, 48, job_proj, &c);
    }
    for (int t = 0; t < T; ++t) {
        float * row = proj + (size_t) t * JH;
        for (int i = 0; i < JH; ++i) row[i] = row[i] + m->enc_b[i];
    }

    // Committed state, and the state the predictor writes: [h, c] per layer.
    float * cur = st, *nxt = st + (size_t) 2 * L * H;
    memset(st, 0, sizeof(float) * (size_t) 4 * L * H);

    int        last_token = -1, step = 0, new_symbols = 0, iter = 0, dirty = 1;
    const int  max_iters  = 16 * T + 1024;
    int64_t    remaining  = (int64_t) m->max_symbols * T;
    const struct ore_boost * bo = d->boost;
    int        bstate     = 0;

    while (step < T && iter < max_iters && (!m->global_budget || remaining > 0)) {
        ++iter;
        if ((iter & 63) == 0 && s->abort_fn && s->abort_fn(s->abort_user)) return 0;
        // The predictor moves only after a token was written.
        if (dirty) {
            if (last_token < 0) {
                memset(xin, 0, sizeof(float) * (size_t) H);
            } else {
                memcpy(xin, m->embed + (size_t) last_token * H, sizeof(float) * (size_t) H);
            }
            const float * in = xin;
            for (int l = 0; l < L; ++l) {
                const float * hp = cur + (size_t) (2 * l) * H;
                const float * cp = cur + (size_t) (2 * l + 1) * H;
                float *       hn = nxt + (size_t) (2 * l) * H;
                float *       cn = nxt + (size_t) (2 * l + 1) * H;
                const float * b  = m->lstm_b + (size_t) l * 4 * H;
                k->gemv_f32(m->lstm_wx + (size_t) l * 4 * H * H, 4 * H, H, in, ga);
                k->gemv_f32(m->lstm_wh + (size_t) l * 4 * H * H, 4 * H, H, hp, re);
                for (int i = 0; i < 4 * H; ++i) {
                    const float sum = ga[i] + re[i];
                    ga[i]           = sum + b[i];
                }
                for (int i = 0; i < H; ++i) {
                    const float ig = 1.f / (1.f + expf(-ga[i]));
                    const float fg = 1.f / (1.f + expf(-ga[H + i]));
                    const float gg = tanhf(ga[2 * H + i]);
                    const float og = 1.f / (1.f + expf(-ga[3 * H + i]));
                    const float fc = fg * cp[i];
                    const float ii = ig * gg;
                    const float c_ = fc + ii;
                    cn[i]          = c_;
                    hn[i]          = og * tanhf(c_);
                }
                in = hn;
            }
            dirty = 0;
        }
        const float * dec_out = nxt + (size_t) (2 * (L - 1)) * H;

        // Joint network.
        const float * ep = proj + (size_t) step * JH;
        k->gemv_f32(m->pred_w, JH, H, dec_out, act);
        for (int i = 0; i < JH; ++i) {
            const float pp     = act[i] + m->pred_b[i];
            const float summed = ep[i] + pp;
            act[i]             = summed > 0.f ? summed : 0.f;
        }
        k->gemv_f32(m->out_w, m->joint_n, JH, act, logits);
        for (int i = 0; i < m->joint_n; ++i) logits[i] = logits[i] + m->out_b[i];

        // The model alone decides whether to write; taught words only choose
        // among tokens once it has.
        int token = argmax(logits, NT);
        if (bo && token != blank) {
            memcpy(boost, logits, sizeof(float) * (size_t) NT);
            boost_apply(bo, bstate, boost, NT, blank);
            boost[blank] = -INFINITY;
            token        = argmax(boost, NT);
        }
        const int duration = m->durations[argmax(logits + NT, m->n_dur)];
        const int is_blank = token == blank;
        if (!is_blank) {
            if (!push_token(d, token, confidence(logits, NT, probs), step, duration)) return 0;
            last_token   = token;
            float * swap = cur;
            cur          = nxt;
            nxt          = swap;
            dirty        = 1;
            if (bo) bstate = boost_next(bo, bstate, token);
        }
        if (m->global_budget) {
            step += (is_blank && duration == 0) ? 1 : duration;
            --remaining;
            continue;
        }
        step += duration;
        new_symbols += 1;
        if (duration != 0) {
            new_symbols = 0;
        } else if (m->max_symbols > 0 && new_symbols >= m->max_symbols) {
            step += 1;
            new_symbols = 0;
        } else if (is_blank && m->max_symbols > 0) {
            // A blank that does not advance repeats until the per-frame limit
            // moves it on; skip straight there.
            const int skip = m->max_symbols - new_symbols;
            if (skip > 0 && iter + skip < max_iters) {
                iter += skip;
                step += 1;
                new_symbols = 0;
            }
        }
    }
    return 1;
}
