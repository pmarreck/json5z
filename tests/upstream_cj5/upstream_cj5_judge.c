// Compiles the unmodified upstream cj5.h with every symbol static, so it can
// be linked beside the interim cj5 without name clashes.
#define CJ5_IMPLEMENT
#define CJ5_API static
#define CJ5_TOKEN_HELPERS 0
#include "cj5.h"

#include <stdlib.h>

#include "upstream_cj5_judge.h"

_Static_assert(UPSTREAM_CJ5_VALID == CJ5_ERROR_NONE, "verdict mapping");
_Static_assert(UPSTREAM_CJ5_INVALID == CJ5_ERROR_INVALID, "verdict mapping");
_Static_assert(UPSTREAM_CJ5_INCOMPLETE == CJ5_ERROR_INCOMPLETE, "verdict mapping");
_Static_assert(UPSTREAM_CJ5_OVERFLOW == CJ5_ERROR_OVERFLOW, "verdict mapping");

int upstream_cj5_judge(const char* json5, int len, int* error_line, int* error_col)
{
	int cap = 64;
	for (;;) {
		cj5_token* tokens = malloc(sizeof(cj5_token) * (size_t)cap);
		if (!tokens) return UPSTREAM_CJ5_OUT_OF_MEMORY;
		cj5_result r = cj5_parse(json5, len, tokens, cap);
		free(tokens);
		// Upstream parses to the end on overflow and reports the tokens it
		// needed; retry once that count is known to be larger.
		if (r.error == CJ5_ERROR_OVERFLOW && r.num_tokens > cap) {
			cap = r.num_tokens;
			continue;
		}
		*error_line = r.error_line;
		*error_col = r.error_col;
		return (int)r.error;
	}
}
