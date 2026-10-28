// Upstream cj5 (tests/upstream_cj5/cj5.h, hash-checked, never edited) behind
// two plain functions for the benchmark. Every cj5 symbol stays static.
#define CJ5_IMPLEMENT
#define CJ5_API static
#define CJ5_TOKEN_HELPERS 0
#include "cj5.h"

#include "cj5_shim.h"

int bench_cj5_parse(const char* json5, int len, void* tokens, int max_tokens, int* num_tokens)
{
	cj5_result r = cj5_parse(json5, len, (cj5_token*)tokens, max_tokens);
	*num_tokens = r.num_tokens;
	return (int)r.error;
}

size_t bench_cj5_token_size(void)
{
	return sizeof(cj5_token);
}
