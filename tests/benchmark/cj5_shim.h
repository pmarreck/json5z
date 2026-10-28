// Upstream cj5 for the benchmark (see cj5_shim.c).
#ifndef BENCH_CJ5_SHIM_H
#define BENCH_CJ5_SHIM_H

#include <stddef.h>

enum { BENCH_CJ5_NONE = 0, BENCH_CJ5_INVALID = 1, BENCH_CJ5_INCOMPLETE = 2, BENCH_CJ5_OVERFLOW = 3 };

// cj5_parse into a caller-owned array of max_tokens (>= 1) tokens. Returns a
// BENCH_CJ5_* code; *num_tokens receives the count cj5 needed, which upstream
// computes by parsing to the end even after the array overflows.
int bench_cj5_parse(const char* json5, int len, void* tokens, int max_tokens, int* num_tokens);

// sizeof(cj5_token), for sizing the array.
size_t bench_cj5_token_size(void);

#endif
