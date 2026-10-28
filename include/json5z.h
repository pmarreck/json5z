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
	JSON5Z_INVALID_ARGUMENT = -2, /* NULL data with a nonzero length, or a bad option */
	JSON5Z_OUT_OF_MEMORY = -1,    /* a limit was reached: no verdict */
	JSON5Z_VALID = 0,
	JSON5Z_INVALID = 1,           /* the input cannot be valid JSON5 */
	JSON5Z_INCOMPLETE = 2,        /* the input ended before the document did */
} json5z_status;

/* A position in the input: a byte offset and its 1-based line and column.
 * Columns count code points. Lines end at LF, CR, CR LF, and, unless
 * json5z_options.line_separators says otherwise, U+2028 and U+2029. */
typedef struct json5z_location {
	size_t offset;
	size_t line;
	size_t column;
} json5z_location;

/* Choices where JSON5, or the tools around it, allow more than one reading.
 * Each default is 0, so a zeroed json5z_options, or a NULL pointer, selects
 * the defaults. See docs/plan_context/settings_and_notes.md. */
typedef enum json5z_line_separators {
	JSON5Z_LINE_SEPARATORS_END_LINE = 0,  /* U+2028 and U+2029 end a line in positions */
	JSON5Z_LINE_SEPARATORS_SAME_LINE = 1, /* they count as one column on the same line */
} json5z_line_separators;

typedef enum json5z_astral_identifiers {
	JSON5Z_ASTRAL_IDENTIFIERS_REJECT = 0, /* unquoted keys stay within U+FFFF */
	JSON5Z_ASTRAL_IDENTIFIERS_ACCEPT = 1, /* letters beyond U+FFFF, raw or as escaped pairs */
} json5z_astral_identifiers;

typedef struct json5z_options {
	int line_separators;    /* a json5z_line_separators value */
	int astral_identifiers; /* a json5z_astral_identifiers value */
} json5z_options;

/* How many times a setting decided the result (the other value would have
 * given a different verdict or position), and where it first did. `first`
 * is meaningful only when `count` is nonzero. */
typedef struct json5z_note {
	size_t count;
	json5z_location first;
} json5z_note;

typedef struct json5z_notes {
	json5z_note line_separators;
	json5z_note astral_identifiers;
} json5z_notes;

/* Streaming validator. Not thread-safe; use one per document and thread. */
typedef struct json5z_validator json5z_validator;

/* Creates a validator in *validator. `options` may be NULL for the defaults.
 * Returns JSON5Z_VALID, JSON5Z_INVALID_ARGUMENT (NULL `validator` or an
 * option out of range; *validator is then left untouched) or
 * JSON5Z_OUT_OF_MEMORY. */
int json5z_validator_create(const json5z_options* options, json5z_validator** validator);

/* Accepts NULL. */
void json5z_validator_free(json5z_validator* validator);

/* Feed the next chunk; a chunk may end anywhere, even inside a UTF-8
 * sequence. Returns JSON5Z_VALID (0) on success, JSON5Z_INVALID_ARGUMENT or
 * JSON5Z_OUT_OF_MEMORY. After JSON5Z_OUT_OF_MEMORY the validator may only be
 * freed. Input after the first failure is ignored. */
int json5z_validator_feed(json5z_validator* validator, const uint8_t* data, size_t length);

/* End of input. Returns JSON5Z_VALID, JSON5Z_INVALID or JSON5Z_INCOMPLETE.
 * Unless VALID, stores the failure's location in *failure when failure is not
 * NULL; otherwise *failure is left untouched. Stores the notes in *notes
 * whenever notes is not NULL. */
int json5z_validator_finish(json5z_validator* validator, json5z_location* failure, json5z_notes* notes);

/* Validate a whole document in one call. Returns any json5z_status. On
 * JSON5Z_INVALID_ARGUMENT or JSON5Z_OUT_OF_MEMORY, *failure and *notes are
 * left untouched. */
int json5z_validate(const uint8_t* data, size_t length, const json5z_options* options, json5z_location* failure, json5z_notes* notes);

#ifdef __cplusplus
}
#endif

#endif
