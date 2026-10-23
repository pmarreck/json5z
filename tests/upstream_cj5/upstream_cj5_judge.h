// Degraded oracle: unmodified septag/cj5 (5fe4821) reduced to a verdict.
// cj5.h in this directory is byte-identical to upstream and hash-checked by
// upstream_cj5_test.zig; never edit it.
#ifndef UPSTREAM_CJ5_JUDGE_H
#define UPSTREAM_CJ5_JUDGE_H

enum {
	UPSTREAM_CJ5_OUT_OF_MEMORY = -1,
	UPSTREAM_CJ5_VALID = 0,
	UPSTREAM_CJ5_INVALID = 1,
	UPSTREAM_CJ5_INCOMPLETE = 2,
	UPSTREAM_CJ5_OVERFLOW = 3,
};

// Judge a whole document with upstream cj5, growing the token buffer until
// the document fits. Returns one of the UPSTREAM_CJ5_* values; on INVALID or
// INCOMPLETE, *error_line and *error_col receive cj5's reported position.
int upstream_cj5_judge(const char* json5, int len, int* error_line, int* error_col);

#endif
