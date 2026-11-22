// ore_model.c - open a model file and check that it is one this engine
// computes: a Parakeet TDT FastConformer with full attention. Anything else
// is refused by name rather than run wrong.
#include "ore_internal.h"

#include <stdio.h>

static int key_is(const ore_gguf * g, const char * key, const char * want) {
    const char * s;
    size_t       n;
    return ore_gguf_str(g, key, &s, &n) && n == strlen(want) && memcmp(s, want, n) == 0;
}

static int get_int(const ore_gguf * g, const char * key, int * out) {
    uint32_t v;
    if (!ore_gguf_u32(g, key, &v)) return 0;
    *out = (int) v;
    return 1;
}

// A tensor that must exist with the given number of elements along each axis
// (0 = any). Sets *bad when it does not.
static void bind(const ore_gguf * g, const char * name, ore_tensor * t, uint64_t d0, uint64_t d1, uint64_t d2,
                 int * bad) {
    if (!ore_gguf_tensor(g, name, t)) {
        *bad = 1;
        return;
    }
    const uint64_t want[3] = { d0, d1, d2 };
    for (int i = 0; i < 3; ++i) {
        if (want[i] && t->dims[i] != want[i]) *bad = 1;
    }
}

static void bind_f32(const ore_gguf * g, const char * name, ore_tensor * t, uint64_t d0, uint64_t d1, uint64_t d2,
                     int * bad) {
    bind(g, name, t, d0, d1, d2, bad);
    if (!*bad && t->type != ORE_T_F32) *bad = 1;
}

// A weight matrix the products accept: Q4_K, Q8_0, F16 or F32, with rows no
// wider than the kernels' scratch.
static void bind_matrix(const ore_gguf * g, const char * name, ore_tensor * t, uint64_t n_in, uint64_t n_out,
                        int conv, int * bad) {
    if (conv) {
        bind(g, name, t, 1, n_in, n_out, bad);
    } else {
        bind(g, name, t, n_in, n_out, 0, bad);
    }
    if (*bad) return;
    if (n_in > ORE_Q4K_MAX_COLS) *bad = 1;
    if (t->type == ORE_T_Q4_K && n_in % ORE_Q4K_BLOCK) *bad = 1;
    if (t->type == ORE_T_Q8_0 && n_in % ORE_Q80_BLOCK) *bad = 1;
}

// Every element as single precision, in a new buffer.
static float * to_f32(const ore_tensor * t) {
    size_t n = 1;
    for (uint32_t i = 0; i < t->n_dims; ++i) n *= (size_t) t->dims[i];
    float * out = (float *) ore_alloc(n * sizeof(float));
    if (!out) return NULL;
    if (t->type == ORE_T_F32) {
        memcpy(out, t->data, n * sizeof(float));
    } else if (t->type == ORE_T_F16) {
        for (size_t i = 0; i < n; ++i) out[i] = ore_f16_to_f32(ore_rd16(t->data + 2 * i));
    } else if (t->type == ORE_T_Q8_0) {
        for (size_t b = 0; b < n / ORE_Q80_BLOCK; ++b) {
            const uint8_t * blk = t->data + b * ORE_Q80_BYTES;
            const float     d   = ore_f16_to_f32(ore_rd16(blk));
            for (int i = 0; i < 32; ++i) out[b * 32 + i] = (float) ((const int8_t *) blk)[2 + i] * d;
        }
    } else {  // Q4_K, as ggml dequantizes it
        for (size_t b = 0; b < n / ORE_Q4K_BLOCK; ++b) {
            const uint8_t * blk  = t->data + b * ORE_Q4K_BYTES;
            const float     d    = ore_f16_to_f32(ore_rd16(blk));
            const float     dmin = ore_f16_to_f32(ore_rd16(blk + 2));
            uint8_t         sc[8], mn[8];
            ore_q4k_scales(blk, sc, mn);
            const uint8_t * qs = blk + 16;
            for (int g = 0; g < 8; ++g) {
                const float d1 = d * (float) sc[g], m1 = dmin * (float) mn[g];
                for (int i = 0; i < 32; ++i) {
                    const int q                   = (qs[(g / 2) * 32 + i] >> ((g & 1) * 4)) & 0x0f;
                    out[b * 256 + g * 32 + i] = fmaf(d1, (float) q, -m1);
                }
            }
        }
    }
    return out;
}

static int load_vocab(struct ore_model * m) {
    ore_vocab * v = &m->vocab;
    uint64_t    n = 0;
    if (!ore_gguf_str_array(m->g, "tokenizer.ggml.tokens", &n) || n == 0 || n > 1u << 20) return 0;
    v->n_tokens  = (int) n;
    v->piece     = (const char **) calloc((size_t) n, sizeof(char *));
    v->piece_len = (uint32_t *) calloc((size_t) n, sizeof(uint32_t));
    v->type      = (uint8_t *) calloc((size_t) n, 1);
    uint32_t * types = (uint32_t *) calloc((size_t) n, sizeof(uint32_t));
    if (!v->piece || !v->piece_len || !v->type || !types) {
        free(types);
        return 0;
    }
    for (uint64_t i = 0; i < n; ++i) {
        size_t len;
        if (!ore_gguf_str_array_item(m->g, "tokenizer.ggml.tokens", i, &v->piece[i], &len)) {
            free(types);
            return 0;
        }
        v->piece_len[i] = (uint32_t) len;
        v->type[i]      = 1;
    }
    if (ore_gguf_u32_array(m->g, "tokenizer.ggml.token_type", types, (int) n) == (int) n) {
        for (uint64_t i = 0; i < n; ++i) v->type[i] = (uint8_t) types[i];
    }
    free(types);
    v->unk_id = -1;
    get_int(m->g, "tokenizer.ggml.unknown_token_id", &v->unk_id);
    return 1;
}

void ore_model_close_internal(struct ore_model * m) {
    if (!m) return;
    if (m->blocks) {
        for (int i = 0; i < m->n_layers; ++i) {
            ore_free(m->blocks[i].bn_scale);
            ore_free(m->blocks[i].bn_bias);
            ore_free(m->blocks[i].dw_t);
        }
        free(m->blocks);
    }
    ore_free(m->c2_t);
    ore_free(m->c5_t);
    ore_free(m->embed);
    ore_free(m->lstm_wx);
    ore_free(m->lstm_wh);
    ore_free(m->lstm_b);
    ore_free(m->enc_w);
    ore_free(m->enc_b);
    ore_free(m->pred_w);
    ore_free(m->pred_b);
    ore_free(m->out_w);
    ore_free(m->out_b);
    free((void *) m->vocab.piece);
    free(m->vocab.piece_len);
    free(m->vocab.score);
    free(m->vocab.type);
    free(m->vocab.sorted);
    ore_mel_free(&m->mel);
    ore_gguf_close(m->g);
    free(m);
}

// [taps][channels] from ggml's depthwise layout, where each channel's taps are
// contiguous.
static float * transpose_taps(const ore_tensor * t, int taps, int channels) {
    float * out = (float *) ore_alloc((size_t) taps * channels * sizeof(float));
    if (!out) return NULL;
    const float * w = (const float *) t->data;
    for (int c = 0; c < channels; ++c) {
        for (int j = 0; j < taps; ++j) out[(size_t) j * channels + c] = w[(size_t) c * taps + j];
    }
    return out;
}

struct ore_model * ore_model_open_internal(const char * path, const char ** err) {
    const char *       e = "out of memory";
    struct ore_model * m = (struct ore_model *) calloc(1, sizeof(*m));
    if (!m) goto fail;
    m->g = ore_gguf_open(path, &e);
    if (!m->g) goto fail;
    const ore_gguf * g = m->g;

    // ---- what kind of model ----
    e = "not a Parakeet TDT model this engine supports";
    int   sub = 0, xscale = 1, use_bias = 1, ctx_l = 0, ctx_r = 0, sr = 0, n_fft = 0, win = 0, hop = 0;
    int   extra = 0, pred_vocab = 0;
    float f_min = 0, f_max = 0, preemph = 0, dither = 1;
    if (!key_is(g, "general.architecture", "parakeet") || !key_is(g, "stt.parakeet.head_kind", "tdt") ||
        !key_is(g, "stt.parakeet.encoder.att_context_style", "regular") ||
        !key_is(g, "stt.parakeet.encoder.conv_norm_type", "batch_norm") ||
        !key_is(g, "stt.parakeet.encoder.length_masking", "kestrel") ||
        !key_is(g, "stt.parakeet.joint.activation", "relu") || !key_is(g, "stt.frontend.type", "mel") ||
        !key_is(g, "stt.frontend.window", "hann") || !key_is(g, "stt.frontend.normalize", "per_feature")) {
        goto fail;
    }
    if (!get_int(g, "stt.parakeet.encoder.n_layers", &m->n_layers) ||
        !get_int(g, "stt.parakeet.encoder.d_model", &m->d_model) ||
        !get_int(g, "stt.parakeet.encoder.n_heads", &m->n_heads) ||
        !get_int(g, "stt.parakeet.encoder.d_ff", &m->d_ff) ||
        !get_int(g, "stt.parakeet.encoder.conv_kernel", &m->conv_kernel) ||
        !get_int(g, "stt.parakeet.encoder.subsampling_factor", &sub) ||
        !get_int(g, "stt.parakeet.encoder.subsampling_channels", &m->sub_ch) ||
        !ore_gguf_bool(g, "stt.parakeet.encoder.use_bias", &use_bias) ||
        !ore_gguf_bool(g, "stt.parakeet.encoder.xscaling", &xscale) ||
        !get_int(g, "stt.parakeet.encoder.att_context_left", &ctx_l) ||
        !get_int(g, "stt.parakeet.encoder.att_context_right", &ctx_r) ||
        !get_int(g, "stt.parakeet.predictor.hidden", &m->pred_hidden) ||
        !get_int(g, "stt.parakeet.predictor.n_layers", &m->pred_layers) ||
        !get_int(g, "stt.parakeet.predictor.vocab", &pred_vocab) ||
        !get_int(g, "stt.parakeet.joint.hidden", &m->joint_hidden) ||
        !get_int(g, "stt.parakeet.joint.num_extra_outputs", &extra) ||
        !get_int(g, "tokenizer.ggml.blank_token_id", &m->blank_id) || !get_int(g, "stt.frontend.num_mels", &m->n_mels) ||
        !get_int(g, "stt.frontend.sample_rate", &sr) || !get_int(g, "stt.frontend.n_fft", &n_fft) ||
        !get_int(g, "stt.frontend.win_length", &win) || !get_int(g, "stt.frontend.hop_length", &hop) ||
        !ore_gguf_f32(g, "stt.frontend.f_min", &f_min) || !ore_gguf_f32(g, "stt.frontend.f_max", &f_max) ||
        !ore_gguf_f32(g, "stt.frontend.pre_emphasis", &preemph) || !ore_gguf_f32(g, "stt.frontend.dither", &dither)) {
        goto fail;
    }
    const int d = m->d_model, C = m->sub_ch, H = m->pred_hidden;
    if (sub != 8 || xscale || use_bias || ctx_l != -1 || ctx_r != -1 || dither != 0.0f || sr != 16000 ||
        m->n_layers < 1 || m->n_layers > 64 || d < 16 || d % 16 || m->n_heads < 1 || d % m->n_heads ||
        m->conv_kernel < 1 || m->conv_kernel > 63 || !(m->conv_kernel & 1) || m->n_mels % 8 || C < 1 ||
        m->pred_layers < 1 || m->pred_layers > 8 || H < 1 || extra < 1 || extra > ORE_MAX_DURATIONS ||
        pred_vocab < 2 || m->blank_id != pred_vocab - 1) {
        goto fail;
    }
    m->n_token_cls = pred_vocab;
    m->joint_n     = pred_vocab + extra;
    m->n_dur       = extra;
    {
        uint32_t dur[ORE_MAX_DURATIONS];
        if (ore_gguf_u32_array(g, "stt.parakeet.tdt.durations", dur, ORE_MAX_DURATIONS) != extra) goto fail;
        for (int i = 0; i < extra; ++i) {
            m->durations[i] = (int) dur[i];
            if (m->durations[i] < 0 || m->durations[i] > 64) goto fail;
        }
        m->max_symbols = 10;
        get_int(g, "stt.parakeet.tdt.max_symbols", &m->max_symbols);
        m->global_budget = key_is(g, "stt.parakeet.tdt.symbol_budget", "global");
    }
    e = "out of memory";
    if (!ore_mel_init(&m->mel, sr, n_fft, win, hop, m->n_mels, f_min, f_max, preemph)) goto fail;

    // ---- tensors ----
    e       = "a tensor is missing or has an unexpected shape";
    int bad = 0;
    const uint64_t uC = (uint64_t) C, ud = (uint64_t) d, uff = (uint64_t) m->d_ff;
    bind_f32(g, "enc.pre_encode.conv.0.weight", &m->c0w, 3, 3, 1, &bad);
    bind_f32(g, "enc.pre_encode.conv.0.bias", &m->c0b, uC, 0, 0, &bad);
    ore_tensor c2w, c5w;
    bind_f32(g, "enc.pre_encode.conv.2.weight", &c2w, 3, 3, 1, &bad);
    bind_f32(g, "enc.pre_encode.conv.2.bias", &m->c2b, uC, 0, 0, &bad);
    bind_f32(g, "enc.pre_encode.conv.3.weight", &m->c3w, 1, 1, uC, &bad);
    bind_f32(g, "enc.pre_encode.conv.3.bias", &m->c3b, uC, 0, 0, &bad);
    bind_f32(g, "enc.pre_encode.conv.5.weight", &c5w, 3, 3, 1, &bad);
    bind_f32(g, "enc.pre_encode.conv.5.bias", &m->c5b, uC, 0, 0, &bad);
    bind_f32(g, "enc.pre_encode.conv.6.weight", &m->c6w, 1, 1, uC, &bad);
    bind_f32(g, "enc.pre_encode.conv.6.bias", &m->c6b, uC, 0, 0, &bad);
    bind_matrix(g, "enc.pre_encode.out.weight", &m->pre_out_w, uC * (uint64_t) (m->n_mels / 8), ud, 0, &bad);
    bind_f32(g, "enc.pre_encode.out.bias", &m->pre_out_b, ud, 0, 0, &bad);
    if (bad || m->c0w.dims[3] != uC || c2w.dims[3] != uC || c5w.dims[3] != uC || m->c3w.dims[3] != uC ||
        m->c6w.dims[3] != uC) {
        goto fail;
    }
    m->c2_t   = transpose_taps(&c2w, 9, C);
    m->c5_t   = transpose_taps(&c5w, 9, C);
    m->blocks = (ore_block *) calloc((size_t) m->n_layers, sizeof(ore_block));
    if (!m->c2_t || !m->c5_t || !m->blocks) {
        e = "out of memory";
        goto fail;
    }
    for (int l = 0; l < m->n_layers; ++l) {
        ore_block * b = &m->blocks[l];
        char        n[96];
#define NAME(suffix) (snprintf(n, sizeof n, "enc.blocks.%d." suffix, l), n)
        bind_f32(g, NAME("norm_ff1.weight"), &b->norm_ff1_w, ud, 0, 0, &bad);
        bind_f32(g, NAME("norm_ff1.bias"), &b->norm_ff1_b, ud, 0, 0, &bad);
        bind_matrix(g, NAME("ff1.linear1.weight"), &b->ff1_l1, ud, uff, 0, &bad);
        bind_matrix(g, NAME("ff1.linear2.weight"), &b->ff1_l2, uff, ud, 0, &bad);
        bind_f32(g, NAME("norm_attn.weight"), &b->norm_attn_w, ud, 0, 0, &bad);
        bind_f32(g, NAME("norm_attn.bias"), &b->norm_attn_b, ud, 0, 0, &bad);
        bind_matrix(g, NAME("attn.linear_q.weight"), &b->att_q, ud, ud, 0, &bad);
        bind_matrix(g, NAME("attn.linear_k.weight"), &b->att_k, ud, ud, 0, &bad);
        bind_matrix(g, NAME("attn.linear_v.weight"), &b->att_v, ud, ud, 0, &bad);
        bind_matrix(g, NAME("attn.linear_out.weight"), &b->att_out, ud, ud, 0, &bad);
        bind_matrix(g, NAME("attn.linear_pos.weight"), &b->att_pos, ud, ud, 0, &bad);
        bind_f32(g, NAME("attn.pos_bias_u"), &b->pos_u, (uint64_t) (d / m->n_heads), (uint64_t) m->n_heads, 0, &bad);
        bind_f32(g, NAME("attn.pos_bias_v"), &b->pos_v, (uint64_t) (d / m->n_heads), (uint64_t) m->n_heads, 0, &bad);
        bind_f32(g, NAME("norm_conv.weight"), &b->norm_conv_w, ud, 0, 0, &bad);
        bind_f32(g, NAME("norm_conv.bias"), &b->norm_conv_b, ud, 0, 0, &bad);
        bind_matrix(g, NAME("conv.pointwise1.weight"), &b->pw1, ud, 2 * ud, 1, &bad);
        bind_matrix(g, NAME("conv.pointwise2.weight"), &b->pw2, ud, ud, 1, &bad);
        bind_f32(g, NAME("norm_ff2.weight"), &b->norm_ff2_w, ud, 0, 0, &bad);
        bind_f32(g, NAME("norm_ff2.bias"), &b->norm_ff2_b, ud, 0, 0, &bad);
        bind_matrix(g, NAME("ff2.linear1.weight"), &b->ff2_l1, ud, uff, 0, &bad);
        bind_matrix(g, NAME("ff2.linear2.weight"), &b->ff2_l2, uff, ud, 0, &bad);
        bind_f32(g, NAME("norm_out.weight"), &b->norm_out_w, ud, 0, 0, &bad);
        bind_f32(g, NAME("norm_out.bias"), &b->norm_out_b, ud, 0, 0, &bad);
        ore_tensor dw, bw, bb, rm, rv;
        bind_f32(g, NAME("conv.depthwise.weight"), &dw, (uint64_t) m->conv_kernel, 1, ud, &bad);
        bind_f32(g, NAME("conv.bn.weight"), &bw, ud, 0, 0, &bad);
        bind_f32(g, NAME("conv.bn.bias"), &bb, ud, 0, 0, &bad);
        bind_f32(g, NAME("conv.bn.running_mean"), &rm, ud, 0, 0, &bad);
        bind_f32(g, NAME("conv.bn.running_var"), &rv, ud, 0, 0, &bad);
#undef NAME
        if (bad) goto fail;
        b->dw_t     = transpose_taps(&dw, m->conv_kernel, d);
        b->bn_scale = (float *) ore_alloc((size_t) d * sizeof(float));
        b->bn_bias  = (float *) ore_alloc((size_t) d * sizeof(float));
        if (!b->dw_t || !b->bn_scale || !b->bn_bias) {
            e = "out of memory";
            goto fail;
        }
        // Batch norm at inference is one multiply and one add per channel.
        for (int c = 0; c < d; ++c) {
            const float sc = ((const float *) bw.data)[c] / sqrtf(((const float *) rv.data)[c] + 1e-5f);
            b->bn_scale[c] = sc;
            b->bn_bias[c]  = ((const float *) bb.data)[c] - ((const float *) rm.data)[c] * sc;
        }
    }

    // ---- decoder: small, and stepped one vector at a time, so its weights
    // are expanded to single precision once ----
    {
        ore_tensor t, tb;
        bind(g, "pred.embed.weight", &t, (uint64_t) H, (uint64_t) pred_vocab, 0, &bad);
        if (bad) goto fail;
        m->embed   = to_f32(&t);
        m->lstm_wx = (float *) ore_alloc((size_t) m->pred_layers * 4 * H * H * sizeof(float));
        m->lstm_wh = (float *) ore_alloc((size_t) m->pred_layers * 4 * H * H * sizeof(float));
        m->lstm_b  = (float *) ore_alloc((size_t) m->pred_layers * 4 * H * sizeof(float));
        e          = "out of memory";
        if (!m->embed || !m->lstm_wx || !m->lstm_wh || !m->lstm_b) goto fail;
        e = "a tensor is missing or has an unexpected shape";
        for (int l = 0; l < m->pred_layers; ++l) {
            char n[64];
            for (int which = 0; which < 2; ++which) {
                snprintf(n, sizeof n, "pred.lstm.%d.%s", l, which ? "Wh" : "Wx");
                bind(g, n, &t, (uint64_t) H, (uint64_t) (4 * H), 0, &bad);
                if (bad) goto fail;
                float * f = to_f32(&t);
                if (!f) {
                    e = "out of memory";
                    goto fail;
                }
                memcpy((which ? m->lstm_wh : m->lstm_wx) + (size_t) l * 4 * H * H, f, (size_t) 4 * H * H * sizeof(float));
                ore_free(f);
            }
            snprintf(n, sizeof n, "pred.lstm.%d.bias", l);
            bind_f32(g, n, &tb, (uint64_t) (4 * H), 0, 0, &bad);
            if (bad) goto fail;
            memcpy(m->lstm_b + (size_t) l * 4 * H, tb.data, (size_t) 4 * H * sizeof(float));
        }
        const uint64_t jh = (uint64_t) m->joint_hidden;
        bind(g, "joint.enc.weight", &t, ud, jh, 0, &bad);
        if (!bad) m->enc_w = to_f32(&t);
        bind_f32(g, "joint.enc.bias", &tb, jh, 0, 0, &bad);
        if (!bad) m->enc_b = to_f32(&tb);
        bind(g, "joint.pred.weight", &t, (uint64_t) H, jh, 0, &bad);
        if (!bad) m->pred_w = to_f32(&t);
        bind_f32(g, "joint.pred.bias", &tb, jh, 0, 0, &bad);
        if (!bad) m->pred_b = to_f32(&tb);
        bind(g, "joint.out.weight", &t, jh, (uint64_t) m->joint_n, 0, &bad);
        if (!bad) m->out_w = to_f32(&t);
        bind_f32(g, "joint.out.bias", &tb, (uint64_t) m->joint_n, 0, 0, &bad);
        if (!bad) m->out_b = to_f32(&tb);
        if (bad) goto fail;
        if (!m->enc_w || !m->enc_b || !m->pred_w || !m->pred_b || !m->out_w || !m->out_b) {
            e = "out of memory";
            goto fail;
        }
    }
    e = "the tokenizer is missing or damaged";
    if (!load_vocab(m) || m->vocab.n_tokens < pred_vocab - 1) goto fail;
    return m;

fail:
    if (err) *err = e;
    ore_model_close_internal(m);
    return NULL;
}
