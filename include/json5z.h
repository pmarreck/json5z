/* json5z: spec-accurate JSON5 validation (JSON5 1.0.0).
 *
 * Input is UTF-8 passed as a pointer and a byte length; it is not
 * NUL-terminated, and a zero byte is ordinary input (JSON5 forbids it only
 * where the grammar does). `data` may be NULL only when `length` is 0. The
 * library keeps no reference to `data` after a call returns.
 *
 * Memory grows with nesting depth only (one bit per open container), so a
 * document of any size can be validated in chunks.
 */
#ifndef JSON5Z_H
#define JSON5Z_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef enum json5z_status {
	JSON5Z_INVALID_ARGUMENT = -2, /* NULL data with a nonzero length */
	JSON5Z_OUT_OF_MEMORY = -1,    /* a limit was reached: no verdict */
	JSON5Z_VALID = 0,
	JSON5Z_INVALID = 1,           /* the input cannot be valid JSON5 */
	JSON5Z_INCOMPLETE = 2,        /* the input ended before the document did */
} json5z_status;

/* Where a document failed: the byte offset of the first character that cannot
 * continue a valid document (for INCOMPLETE, the total length fed), and its
 * 1-based line and column. Columns count code points. Lines end at LF, CR,
 * CR LF, U+2028 and U+2029, JSON5's line terminators. */
typedef struct json5z_location {
	size_t offset;
	size_t line;
	size_t column;
} json5z_location;

/* Streaming validator. Not thread-safe; use one per document and thread. */
typedef struct json5z_validator json5z_validator;

/* Returns NULL when out of memory. */
json5z_validator* json5z_validator_new(void);

/* Accepts NULL. */
void json5z_validator_free(json5z_validator* validator);

/* Feed the next chunk; a chunk may end anywhere, even inside a UTF-8
 * sequence. Returns JSON5Z_VALID (0) on success, JSON5Z_INVALID_ARGUMENT or
 * JSON5Z_OUT_OF_MEMORY. After JSON5Z_OUT_OF_MEMORY the validator may only be
 * freed. Input after the first failure is ignored. */
int json5z_validator_feed(json5z_validator* validator, const uint8_t* data, size_t length);

/* End of input. Returns JSON5Z_VALID, JSON5Z_INVALID or JSON5Z_INCOMPLETE.
 * Unless VALID, stores the failure's location in *failure when failure is not
 * NULL; otherwise *failure is left untouched. */
int json5z_validator_finish(json5z_validator* validator, json5z_location* failure);

/* Validate a whole document in one call. Returns any json5z_status. */
int json5z_validate(const uint8_t* data, size_t length, json5z_location* failure);

#ifdef __cplusplus
}
#endif

#endif
