// ore_gguf.h - read-only, memory-mapped GGUF model file.
//
// The file is mapped, never copied: tensor data pointers point into the
// mapping, so the weights are clean file-backed pages the system can share
// and reclaim.
#ifndef ORE_GGUF_H
#define ORE_GGUF_H

#include "ore_base.h"

typedef struct ore_gguf ore_gguf;

typedef struct {
    const char *    name;      // not NUL-terminated; see name_len
    size_t          name_len;
    uint32_t        type;      // ORE_T_*
    uint32_t        n_dims;
    uint64_t        dims[4];   // GGUF order: dims[0] is the innermost axis
    const uint8_t * data;      // inside the mapping
    size_t          bytes;     // size of the tensor data
} ore_tensor;

// Opens and validates a file. Returns NULL on any failure; `err` (may be NULL)
// receives a short static description.
ore_gguf * ore_gguf_open(const char * path, const char ** err);
void       ore_gguf_close(ore_gguf * g);

// Tensor by exact name. Returns 0 when absent.
int ore_gguf_tensor(const ore_gguf * g, const char * name, ore_tensor * out);

// Metadata. Each returns 0 when the key is absent or has another type.
int ore_gguf_u32(const ore_gguf * g, const char * key, uint32_t * out);
int ore_gguf_f32(const ore_gguf * g, const char * key, float * out);
int ore_gguf_bool(const ore_gguf * g, const char * key, int * out);
// String value: pointer into the mapping and its length (not NUL-terminated).
int ore_gguf_str(const ore_gguf * g, const char * key, const char ** s, size_t * len);
// Array of strings: count, then item i.
int ore_gguf_str_array(const ore_gguf * g, const char * key, uint64_t * count);
int ore_gguf_str_array_item(const ore_gguf * g, const char * key, uint64_t i, const char ** s, size_t * len);
// Array of u32/i32 values copied out (up to cap). Returns the count or -1.
int ore_gguf_u32_array(const ore_gguf * g, const char * key, uint32_t * out, int cap);

size_t ore_gguf_file_bytes(const ore_gguf * g);

#endif  // ORE_GGUF_H
