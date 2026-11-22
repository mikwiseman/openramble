// ore_gguf.c - memory-mapped GGUF reader. Every read is bounds-checked: a
// truncated or hostile file fails to open, it never reads past the mapping.
#include "ore_gguf.h"

#include <stdlib.h>

#if defined(_WIN32)
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#else
#include <fcntl.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>
#endif

enum {
    GT_U8 = 0, GT_I8, GT_U16, GT_I16, GT_U32, GT_I32, GT_F32, GT_BOOL, GT_STR, GT_ARR, GT_U64, GT_I64, GT_F64,
};

typedef struct {
    const char *    key;
    size_t          key_len;
    uint32_t        type;
    const uint8_t * val;       // start of the value
    uint32_t        arr_type;  // for arrays
    uint64_t        arr_n;
    const uint8_t * arr;       // first array element
    const uint8_t ** str_items; // lazily built index for string arrays
} kv_t;

struct ore_gguf {
    const uint8_t * base;
    size_t          size;
#if defined(_WIN32)
    HANDLE file;
    HANDLE mapping;
#endif
    kv_t *       kv;
    uint64_t     n_kv;
    ore_tensor * tensors;
    uint64_t     n_tensors;
    // open-addressing index over tensor names
    uint32_t *   slots;
    uint32_t     n_slots;
};

typedef struct {
    const uint8_t * p;
    const uint8_t * end;
    int             bad;
} cur_t;

static uint64_t rd_u64(cur_t * c) {
    if (c->bad || (size_t) (c->end - c->p) < 8) {
        c->bad = 1;
        return 0;
    }
    uint64_t v;
    memcpy(&v, c->p, 8);
    c->p += 8;
    return v;
}
static uint32_t rd_u32(cur_t * c) {
    if (c->bad || (size_t) (c->end - c->p) < 4) {
        c->bad = 1;
        return 0;
    }
    uint32_t v;
    memcpy(&v, c->p, 4);
    c->p += 4;
    return v;
}
static const uint8_t * rd_bytes(cur_t * c, uint64_t n) {
    if (c->bad || (uint64_t) (c->end - c->p) < n) {
        c->bad = 1;
        return NULL;
    }
    const uint8_t * p = c->p;
    c->p += n;
    return p;
}
static size_t scalar_size(uint32_t t) {
    switch (t) {
        case GT_U8: case GT_I8: case GT_BOOL: return 1;
        case GT_U16: case GT_I16: return 2;
        case GT_U32: case GT_I32: case GT_F32: return 4;
        case GT_U64: case GT_I64: case GT_F64: return 8;
        default: return 0;
    }
}
// Skips one value of type t; for arrays records the element type and count.
static void skip_value(cur_t * c, uint32_t t, kv_t * kv) {
    size_t s = scalar_size(t);
    if (s) {
        rd_bytes(c, s);
    } else if (t == GT_STR) {
        uint64_t n = rd_u64(c);
        rd_bytes(c, n);
    } else if (t == GT_ARR) {
        uint32_t et = rd_u32(c);
        uint64_t n  = rd_u64(c);
        if (kv) {
            kv->arr_type = et;
            kv->arr_n    = n;
            kv->arr      = c->p;
        }
        size_t es = scalar_size(et);
        if (es) {
            if (n > (uint64_t) (c->end - c->p) / es) {
                c->bad = 1;
            } else {
                rd_bytes(c, n * es);
            }
        } else if (et == GT_STR) {
            for (uint64_t i = 0; i < n && !c->bad; ++i) {
                uint64_t len = rd_u64(c);
                rd_bytes(c, len);
            }
        } else {
            c->bad = 1;  // nested arrays are not used by our files
        }
    } else {
        c->bad = 1;
    }
}

static uint32_t hash_name(const char * s, size_t n) {
    uint32_t h = 2166136261u;
    for (size_t i = 0; i < n; ++i) {
        h = (h ^ (uint8_t) s[i]) * 16777619u;
    }
    return h;
}

static size_t tensor_bytes(uint32_t type, uint64_t n_elem, int * ok) {
    *ok = 1;
    switch (type) {
        case ORE_T_F32: return (size_t) n_elem * 4;
        case ORE_T_F16: return (size_t) n_elem * 2;
        case ORE_T_Q8_0:
            if (n_elem % ORE_Q80_BLOCK) { *ok = 0; return 0; }
            return (size_t) (n_elem / ORE_Q80_BLOCK) * ORE_Q80_BYTES;
        case ORE_T_Q4_K:
            if (n_elem % ORE_Q4K_BLOCK) { *ok = 0; return 0; }
            return (size_t) (n_elem / ORE_Q4K_BLOCK) * ORE_Q4K_BYTES;
        default:
            *ok = 0;
            return 0;
    }
}

static int map_file(ore_gguf * g, const char * path) {
#if defined(_WIN32)
    int      wlen = MultiByteToWideChar(CP_UTF8, 0, path, -1, NULL, 0);
    wchar_t * w   = (wchar_t *) malloc(sizeof(wchar_t) * (size_t) (wlen > 0 ? wlen : 1));
    if (!w || wlen <= 0) { free(w); return 0; }
    MultiByteToWideChar(CP_UTF8, 0, path, -1, w, wlen);
    g->file = CreateFileW(w, GENERIC_READ, FILE_SHARE_READ, NULL, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, NULL);
    free(w);
    if (g->file == INVALID_HANDLE_VALUE) return 0;
    LARGE_INTEGER sz;
    if (!GetFileSizeEx(g->file, &sz) || sz.QuadPart <= 0) return 0;
    g->mapping = CreateFileMappingW(g->file, NULL, PAGE_READONLY, 0, 0, NULL);
    if (!g->mapping) return 0;
    g->base = (const uint8_t *) MapViewOfFile(g->mapping, FILE_MAP_READ, 0, 0, 0);
    if (!g->base) return 0;
    g->size = (size_t) sz.QuadPart;
    return 1;
#else
    int fd = open(path, O_RDONLY);
    if (fd < 0) return 0;
    struct stat st;
    if (fstat(fd, &st) != 0 || st.st_size <= 0) { close(fd); return 0; }
    void * p = mmap(NULL, (size_t) st.st_size, PROT_READ, MAP_PRIVATE, fd, 0);
    close(fd);
    if (p == MAP_FAILED) return 0;
    g->base = (const uint8_t *) p;
    g->size = (size_t) st.st_size;
    return 1;
#endif
}

void ore_gguf_close(ore_gguf * g) {
    if (!g) return;
    if (g->kv) {
        for (uint64_t i = 0; i < g->n_kv; ++i) free((void *) g->kv[i].str_items);
    }
#if defined(_WIN32)
    if (g->base) UnmapViewOfFile(g->base);
    if (g->mapping) CloseHandle(g->mapping);
    if (g->file && g->file != INVALID_HANDLE_VALUE) CloseHandle(g->file);
#else
    if (g->base) munmap((void *) g->base, g->size);
#endif
    free(g->kv);
    free(g->tensors);
    free(g->slots);
    free(g);
}

ore_gguf * ore_gguf_open(const char * path, const char ** err) {
    const char * e = "out of memory";
    ore_gguf *   g = (ore_gguf *) calloc(1, sizeof(*g));
    if (!g) goto fail;
    e = "cannot open or map the file";
    if (!map_file(g, path)) goto fail;

    cur_t c = { g->base, g->base + g->size, 0 };
    e       = "not a GGUF v3 file";
    const uint8_t * magic = rd_bytes(&c, 4);
    if (!magic || memcmp(magic, "GGUF", 4) != 0) goto fail;
    uint32_t version = rd_u32(&c);
    if (version != 3) goto fail;
    g->n_tensors = rd_u64(&c);
    g->n_kv      = rd_u64(&c);
    if (c.bad || g->n_tensors > 1u << 20 || g->n_kv > 1u << 20) goto fail;

    e     = "out of memory";
    g->kv = (kv_t *) calloc((size_t) g->n_kv + 1, sizeof(kv_t));
    g->tensors = (ore_tensor *) calloc((size_t) g->n_tensors + 1, sizeof(ore_tensor));
    if (!g->kv || !g->tensors) goto fail;

    e = "damaged metadata";
    uint32_t alignment = 32;
    for (uint64_t i = 0; i < g->n_kv; ++i) {
        kv_t *   kv  = &g->kv[i];
        uint64_t len = rd_u64(&c);
        kv->key      = (const char *) rd_bytes(&c, len);
        kv->key_len  = (size_t) len;
        kv->type     = rd_u32(&c);
        kv->val      = c.p;
        skip_value(&c, kv->type, kv);
        if (c.bad) goto fail;
        if (kv->type == GT_U32 && kv->key_len == 17 && memcmp(kv->key, "general.alignment", 17) == 0) {
            memcpy(&alignment, kv->val, 4);
        }
    }
    if (alignment == 0 || (alignment & (alignment - 1)) != 0) goto fail;

    e = "damaged tensor table";
    uint64_t * offsets = (uint64_t *) calloc((size_t) g->n_tensors + 1, sizeof(uint64_t));
    if (!offsets) { e = "out of memory"; goto fail; }
    for (uint64_t i = 0; i < g->n_tensors; ++i) {
        ore_tensor * t   = &g->tensors[i];
        uint64_t     len = rd_u64(&c);
        t->name          = (const char *) rd_bytes(&c, len);
        t->name_len      = (size_t) len;
        t->n_dims        = rd_u32(&c);
        if (c.bad || t->n_dims == 0 || t->n_dims > 4) { free(offsets); goto fail; }
        uint64_t n_elem = 1;
        for (uint32_t d = 0; d < 4; ++d) t->dims[d] = 1;
        for (uint32_t d = 0; d < t->n_dims; ++d) {
            t->dims[d] = rd_u64(&c);
            if (t->dims[d] == 0 || t->dims[d] > (1ull << 32) || n_elem > (1ull << 40) / t->dims[d]) {
                free(offsets);
                goto fail;
            }
            n_elem *= t->dims[d];
        }
        t->type    = rd_u32(&c);
        offsets[i] = rd_u64(&c);
        int ok;
        t->bytes = tensor_bytes(t->type, n_elem, &ok);
        if (c.bad || !ok) { free(offsets); e = "unsupported tensor type"; goto fail; }
    }
    size_t header = (size_t) (c.p - g->base);
    size_t data0  = (header + alignment - 1) / alignment * alignment;
    e             = "tensor data outside the file";
    for (uint64_t i = 0; i < g->n_tensors; ++i) {
        ore_tensor * t = &g->tensors[i];
        if (data0 > g->size || offsets[i] > g->size - data0 || t->bytes > g->size - data0 - offsets[i]) {
            free(offsets);
            goto fail;
        }
        t->data = g->base + data0 + offsets[i];
    }
    free(offsets);

    e          = "out of memory";
    g->n_slots = 64;
    while (g->n_slots < g->n_tensors * 2 + 2) g->n_slots *= 2;
    g->slots = (uint32_t *) calloc(g->n_slots, sizeof(uint32_t));
    if (!g->slots) goto fail;
    for (uint64_t i = 0; i < g->n_tensors; ++i) {
        uint32_t h = hash_name(g->tensors[i].name, g->tensors[i].name_len) & (g->n_slots - 1);
        while (g->slots[h]) h = (h + 1) & (g->n_slots - 1);
        g->slots[h] = (uint32_t) i + 1;
    }
    return g;

fail:
    if (err) *err = e;
    ore_gguf_close(g);
    return NULL;
}

int ore_gguf_tensor(const ore_gguf * g, const char * name, ore_tensor * out) {
    size_t   n = strlen(name);
    uint32_t h = hash_name(name, n) & (g->n_slots - 1);
    while (g->slots[h]) {
        const ore_tensor * t = &g->tensors[g->slots[h] - 1];
        if (t->name_len == n && memcmp(t->name, name, n) == 0) {
            *out = *t;
            return 1;
        }
        h = (h + 1) & (g->n_slots - 1);
    }
    return 0;
}

static kv_t * find_kv(const ore_gguf * g, const char * key) {
    size_t n = strlen(key);
    for (uint64_t i = 0; i < g->n_kv; ++i) {
        if (g->kv[i].key_len == n && memcmp(g->kv[i].key, key, n) == 0) return &g->kv[i];
    }
    return NULL;
}

int ore_gguf_u32(const ore_gguf * g, const char * key, uint32_t * out) {
    const kv_t * kv = find_kv(g, key);
    if (!kv) return 0;
    if (kv->type == GT_U32 || kv->type == GT_I32) {
        memcpy(out, kv->val, 4);
        return 1;
    }
    if (kv->type == GT_U64 || kv->type == GT_I64) {
        uint64_t v;
        memcpy(&v, kv->val, 8);
        *out = (uint32_t) v;
        return 1;
    }
    return 0;
}

int ore_gguf_f32(const ore_gguf * g, const char * key, float * out) {
    const kv_t * kv = find_kv(g, key);
    if (!kv) return 0;
    if (kv->type == GT_F32) {
        memcpy(out, kv->val, 4);
        return 1;
    }
    if (kv->type == GT_F64) {
        double v;
        memcpy(&v, kv->val, 8);
        *out = (float) v;
        return 1;
    }
    return 0;
}

int ore_gguf_bool(const ore_gguf * g, const char * key, int * out) {
    const kv_t * kv = find_kv(g, key);
    if (!kv || kv->type != GT_BOOL) return 0;
    *out = kv->val[0] != 0;
    return 1;
}

int ore_gguf_str(const ore_gguf * g, const char * key, const char ** s, size_t * len) {
    const kv_t * kv = find_kv(g, key);
    if (!kv || kv->type != GT_STR) return 0;
    uint64_t n;
    memcpy(&n, kv->val, 8);
    *s   = (const char *) kv->val + 8;
    *len = (size_t) n;
    return 1;
}

int ore_gguf_str_array(const ore_gguf * g, const char * key, uint64_t * count) {
    const kv_t * kv = find_kv(g, key);
    if (!kv || kv->type != GT_ARR || kv->arr_type != GT_STR) return 0;
    *count = kv->arr_n;
    return 1;
}

int ore_gguf_str_array_item(const ore_gguf * g, const char * key, uint64_t i, const char ** s, size_t * len) {
    kv_t * kv = find_kv(g, key);
    if (!kv || kv->type != GT_ARR || kv->arr_type != GT_STR || i >= kv->arr_n) return 0;
    if (!kv->str_items) {
        const uint8_t ** items = (const uint8_t **) malloc(sizeof(uint8_t *) * (size_t) kv->arr_n);
        if (!items) return 0;
        const uint8_t * p = kv->arr;
        for (uint64_t k = 0; k < kv->arr_n; ++k) {
            items[k] = p;
            uint64_t n;
            memcpy(&n, p, 8);
            p += 8 + n;  // validated when the file was opened
        }
        kv->str_items = items;
    }
    uint64_t n;
    memcpy(&n, kv->str_items[i], 8);
    *s   = (const char *) kv->str_items[i] + 8;
    *len = (size_t) n;
    return 1;
}

int ore_gguf_u32_array(const ore_gguf * g, const char * key, uint32_t * out, int cap) {
    const kv_t * kv = find_kv(g, key);
    if (!kv || kv->type != GT_ARR || (kv->arr_type != GT_U32 && kv->arr_type != GT_I32)) return -1;
    int n = (int) ORE_MIN(kv->arr_n, (uint64_t) cap);
    memcpy(out, kv->arr, (size_t) n * 4);
    return (int) kv->arr_n;
}

size_t ore_gguf_file_bytes(const ore_gguf * g) { return g->size; }
