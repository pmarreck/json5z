/* json5z command-line tool: validates JSON5 files through the C ABI in
 * include/json5z.h, streaming each input in fixed-size chunks so memory does
 * not grow with file size. All I/O lives here, including the settings file
 * and environment; the library does none. */

#ifndef _WIN32
#define _POSIX_C_SOURCE 200809L /* fileno, isatty */
#endif

#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "json5z.h"
#include "tomlc17.h"

#ifdef _WIN32
#include <fcntl.h>
#include <io.h>
#define isatty _isatty
#define fileno _fileno
#else
#include <unistd.h>
#endif

#ifndef JSON5Z_VERSION
#define JSON5Z_VERSION "unknown"
#endif
#ifndef JSON5Z_TARGET
#define JSON5Z_TARGET "unknown"
#endif
#ifndef JSON5Z_BUILD_MODE
#define JSON5Z_BUILD_MODE "unknown"
#endif

enum { EXIT_ALL_VALID = 0, EXIT_SOME_INVALID = 1, EXIT_TROUBLE = 2 };
enum output_mode { OUTPUT_TEXT, OUTPUT_JSON, OUTPUT_QUIET };

/* A choice setting's value is its json5z_options enum value, the index into
 * `values`; a depth setting's value is the limit, 0 for "unlimited".
 * docs/plan_context/settings_and_notes.md describes each. */
enum {
	SETTING_LINE_SEPARATORS,
	SETTING_ASTRAL_IDENTIFIERS,
	SETTING_ESCAPED_LITERALS,
	SETTING_NUMBER_RANGE,
	SETTING_MAX_DEPTH,
	SETTING_COUNT
};
enum setting_kind { KIND_CHOICE, KIND_DEPTH };

typedef struct setting_def {
	const char* key;  /* in the settings file */
	const char* env;  /* environment variable */
	const char* flag; /* command-line flag */
	enum setting_kind kind;
	const char* values[2];
	const char* comment; /* for --print-config; the source follows it */
} setting_def;

static const setting_def setting_defs[SETTING_COUNT] = {
	{ "line_separators", "JSON5Z_LINE_SEPARATORS", "--line-separators", KIND_CHOICE, { "end-line", "same-line" },
		"# Whether U+2028 and U+2029 end a line in reported positions:\n"
		"# \"end-line\" or \"same-line\"." },
	{ "astral_identifiers", "JSON5Z_ASTRAL_IDENTIFIERS", "--astral-identifiers", KIND_CHOICE, { "reject", "accept" },
		"# Whether unquoted keys may contain letters beyond U+FFFF, raw or as\n"
		"# escaped surrogate pairs: \"reject\" or \"accept\"." },
	{ "escaped_literals", "JSON5Z_ESCAPED_LITERALS", "--escaped-literals", KIND_CHOICE, { "reject", "accept" },
		"# Whether a \\uXXXX escape may spell a letter of null, true, false,\n"
		"# Infinity or NaN: \"reject\" or \"accept\"." },
	{ "number_range", "JSON5Z_NUMBER_RANGE", "--number-range", KIND_CHOICE, { "unlimited", "binary64" },
		"# Whether a number that rounds to infinity in IEEE 754 binary64 is\n"
		"# rejected: \"unlimited\" or \"binary64\"." },
	{ "max_depth", "JSON5Z_MAX_DEPTH", "--max-depth", KIND_DEPTH, { "unlimited", NULL },
		"# The deepest nesting allowed, counting each open array or object:\n"
		"# \"unlimited\" or a positive integer." },
};

enum source { SOURCE_DEFAULT, SOURCE_FILE, SOURCE_ENVIRONMENT, SOURCE_FLAG };
static const char* const source_names[] = { "default", "file", "environment", "flag" };

/* A setting in effect and where it came from (`from` is NULL for a default). */
typedef struct setting {
	size_t value;
	enum source source;
	const char* from;
} setting;

typedef struct options {
	enum output_mode mode;
	int color;
	int ascii;
	int mute_info;
	setting settings[SETTING_COUNT];
} options;

static const char* const usage =
	"Usage: json5z [OPTIONS] [FILE ...]\n"
	"\n"
	"Validate JSON5 documents against the JSON5 1.0.0 specification.\n"
	"With no FILE, or when FILE is - or @stdin, read standard input.\n"
	"\n"
	"Options:\n"
	"  -h, --help       Show this help and exit\n"
	"      --about      Show a one-line description and exit\n"
	"      --json       Print one JSON object per input (JSON Lines)\n"
	"  -q, --quiet      Print nothing; report through the exit status only\n"
	"      --no-color   Do not use ANSI colors (also: NO_COLOR=1)\n"
	"      --ascii      Plain ASCII output, no colors or symbols (also --simple)\n"
	"  --               Treat every later argument as a FILE\n"
	"\n"
	"Settings for readings the JSON5 specification leaves open (defaults first):\n"
	"      --line-separators end-line|same-line\n"
	"                   Whether U+2028 and U+2029 end a line in reported positions\n"
	"      --astral-identifiers reject|accept\n"
	"                   Whether unquoted keys may contain letters beyond U+FFFF\n"
	"      --escaped-literals reject|accept\n"
	"                   Whether \\uXXXX escapes may spell null, true, false,\n"
	"                   Infinity or NaN\n"
	"      --number-range unlimited|binary64\n"
	"                   Whether numbers that round to infinity in binary64 fail\n"
	"      --max-depth unlimited|N\n"
	"                   The deepest nesting allowed\n"
	"      --config PATH\n"
	"                   Read settings from PATH (- or @stdin for standard input)\n"
	"                   instead of $XDG_CONFIG_HOME/json5z/config.toml\n"
	"      --print-config\n"
	"                   Print the settings in effect, with their sources, as TOML\n"
	"Each source overrides the one before: default, settings file, environment\n"
	"(JSON5Z_ and the setting in capitals, e.g. JSON5Z_MAX_DEPTH), flags. A note on stderr\n"
	"names every setting that decided a result; JSON5Z_MUTE_INFO=1 mutes the notes,\n"
	"and --json output always includes them.\n"
	"\n"
	"Later options override earlier ones.\n"
	"Exit status: 0 all inputs valid, 1 some input invalid or incomplete,\n"
	"2 usage error, unreadable input or settings, or no verdict (out of memory).\n";

static int is_stdin(const char* path)
{
	return strcmp(path, "-") == 0 || strcmp(path, "@stdin") == 0;
}

static void must_be(const setting_def* def, const char* origin)
{
	if (def->kind == KIND_DEPTH) fprintf(stderr, "json5z: %s must be \"unlimited\" or a positive integer", origin);
	else fprintf(stderr, "json5z: %s must be \"%s\" or \"%s\"", origin, def->values[0], def->values[1]);
}

/* A positive decimal integer of digits only, or 0 when `text` is not one. */
static size_t parse_depth(const char* text)
{
	size_t n = 0;
	if (!*text) return 0;
	for (const char* p = text; *p; p++) {
		if (*p < '0' || *p > '9') return 0;
		const size_t d = (size_t)(*p - '0');
		if (n > (SIZE_MAX - d) / 10) return 0;
		n = n * 10 + d;
	}
	return n;
}

/* Sets *s from `text` named by `origin`; returns 0, or reports and returns -1. */
static int set_setting(setting* s, const setting_def* def, const char* text, enum source source, const char* from, const char* origin)
{
	if (def->kind == KIND_DEPTH) {
		const size_t depth = strcmp(text, "unlimited") == 0 ? 0 : parse_depth(text);
		if (depth != 0 || strcmp(text, "unlimited") == 0) {
			*s = (setting){ depth, source, from };
			return 0;
		}
	} else {
		for (size_t i = 0; i < 2; i++) {
			if (strcmp(text, def->values[i]) == 0) {
				*s = (setting){ i, source, from };
				return 0;
			}
		}
	}
	must_be(def, origin);
	fprintf(stderr, ", not \"%s\"\n", text);
	return -1;
}

static const setting_def* find_setting(const char* key, size_t len, int* index)
{
	for (int i = 0; i < SETTING_COUNT; i++) {
		if (strlen(setting_defs[i].key) == len && memcmp(setting_defs[i].key, key, len) == 0) {
			*index = i;
			return &setting_defs[i];
		}
	}
	return NULL;
}

/* Reads all of `in`, NUL-terminated, into a malloc'd buffer; NULL on error. */
static char* read_all(FILE* in, size_t* length)
{
	size_t cap = 4096, len = 0;
	char* buf = malloc(cap);
	while (buf) {
		len += fread(buf + len, 1, cap - len - 1, in);
		if (len < cap - 1) break;
		char* bigger = realloc(buf, cap * 2);
		if (!bigger) {
			free(buf);
			return NULL;
		}
		buf = bigger;
		cap *= 2;
	}
	if (!buf || ferror(in)) {
		free(buf);
		return NULL;
	}
	buf[len] = '\0';
	*length = len;
	return buf;
}

/* Applies the settings file at `path`. A missing file is skipped when
 * `optional`. Returns 0, or reports and returns -1. `path` must outlive opt. */
static int load_settings_file(options* opt, const char* path, int optional)
{
	const int from_stdin = is_stdin(path);
	FILE* in = from_stdin ? stdin : fopen(path, "rb");
	if (!in) {
		if (optional && errno == ENOENT) return 0;
		fprintf(stderr, "json5z: cannot open settings file '%s': %s\n", path, strerror(errno));
		return -1;
	}
	size_t len = 0;
	char* text = read_all(in, &len);
	if (!from_stdin) fclose(in);
	if (!text || len > 0x7FFFFFFF) {
		fprintf(stderr, "json5z: cannot read settings file '%s'\n", path);
		free(text);
		return -1;
	}
	toml_result_t doc = toml_parse(text, (int)len);
	free(text);
	int rc = 0;
	if (!doc.ok) {
		fprintf(stderr, "json5z: %s: %s\n", path, doc.errmsg);
		rc = -1;
	}
	for (int k = 0; rc == 0 && k < doc.toptab.u.tab.size; k++) {
		const char* key = doc.toptab.u.tab.key[k];
		const toml_datum_t value = doc.toptab.u.tab.value[k];
		int index = 0;
		const setting_def* def = find_setting(key, (size_t)doc.toptab.u.tab.len[k], &index);
		if (!def) {
			fprintf(stderr, "json5z: %s: unknown setting '%.*s'\n", path, doc.toptab.u.tab.len[k], key);
			rc = -1;
		} else {
			char origin[1024];
			snprintf(origin, sizeof origin, "%s: %s", path, def->key);
			if (value.type == TOML_STRING) {
				rc = set_setting(&opt->settings[index], def, value.u.s, SOURCE_FILE, path, origin);
			} else if (def->kind == KIND_DEPTH && value.type == TOML_INT64) {
				if (value.u.int64 > 0 && (uint64_t)value.u.int64 <= SIZE_MAX) {
					opt->settings[index] = (setting){ (size_t)value.u.int64, SOURCE_FILE, path };
				} else {
					must_be(def, origin);
					fprintf(stderr, ", not %lld\n", (long long)value.u.int64);
					rc = -1;
				}
			} else if (def->kind == KIND_DEPTH) {
				must_be(def, origin);
				fputc('\n', stderr);
				rc = -1;
			} else {
				fprintf(stderr, "json5z: %s: %s must be a string\n", path, def->key);
				rc = -1;
			}
		}
	}
	if (doc.ok) toml_free(doc);
	return rc;
}

static int load_settings_environment(options* opt)
{
	for (int i = 0; i < SETTING_COUNT; i++) {
		const char* text = getenv(setting_defs[i].env);
		if (text && *text && set_setting(&opt->settings[i], &setting_defs[i], text, SOURCE_ENVIRONMENT, setting_defs[i].env, setting_defs[i].env) != 0) return -1;
	}
	return 0;
}

static const char* source_text(const setting* s, char* buf, size_t size)
{
	if (s->source == SOURCE_DEFAULT) return "default";
	snprintf(buf, size, "from %s", s->from);
	return buf;
}

static void print_config(const options* opt, const char* path)
{
	printf("# json5z settings (TOML). Sources override in this order: default,\n"
	       "# settings file, environment (JSON5Z_*), flags. Values below are in effect.\n"
	       "# Settings file: %s\n",
		path ? path : "(none)");
	for (int i = 0; i < SETTING_COUNT; i++) {
		const setting* s = &opt->settings[i];
		const setting_def* def = &setting_defs[i];
		printf("\n%s Source: %s.\n%s = ", def->comment, s->source == SOURCE_DEFAULT ? "default" : s->from, def->key);
		if (def->kind == KIND_DEPTH && s->value != 0) printf("%zu\n", s->value);
		else printf("\"%s\"\n", def->values[def->kind == KIND_DEPTH ? 0 : s->value]);
	}
}

static void print_json_string(FILE* out, const char* s)
{
	fputc('"', out);
	for (const unsigned char* p = (const unsigned char*)s; *p; p++) {
		switch (*p) {
		case '"': fputs("\\\"", out); break;
		case '\\': fputs("\\\\", out); break;
		case '\n': fputs("\\n", out); break;
		case '\r': fputs("\\r", out); break;
		case '\t': fputs("\\t", out); break;
		default:
			if (*p < 0x20) fprintf(out, "\\u%04x", *p);
			else fputc(*p, out);
		}
	}
	fputc('"', out);
}

static const json5z_note* note_for(const json5z_notes* notes, int i)
{
	switch (i) {
	case SETTING_LINE_SEPARATORS: return &notes->line_separators;
	case SETTING_ASTRAL_IDENTIFIERS: return &notes->astral_identifiers;
	case SETTING_ESCAPED_LITERALS: return &notes->escaped_literals;
	case SETTING_NUMBER_RANGE: return &notes->number_range;
	default: return &notes->max_depth;
	}
}

static void print_json_notes(const options* opt, const json5z_notes* notes)
{
	fputs(",\"notes\":[", stdout);
	int first = 1;
	for (int i = 0; i < SETTING_COUNT; i++) {
		const json5z_note* n = note_for(notes, i);
		if (n->count == 0) continue;
		const setting* s = &opt->settings[i];
		fprintf(stdout, "%s{\"setting\":\"%s\",\"value\":", first ? "" : ",", setting_defs[i].key);
		if (setting_defs[i].kind == KIND_DEPTH && s->value != 0) fprintf(stdout, "%zu", s->value);
		else fprintf(stdout, "\"%s\"", setting_defs[i].values[setting_defs[i].kind == KIND_DEPTH ? 0 : s->value]);
		fprintf(stdout, ",\"source\":\"%s\"", source_names[s->source]);
		if (s->from) {
			fputs(",\"from\":", stdout);
			print_json_string(stdout, s->from);
		}
		fprintf(stdout, ",\"count\":%zu,\"first\":{\"offset\":%zu,\"line\":%zu,\"column\":%zu}}", n->count,
			n->first.offset, n->first.line, n->first.column);
		first = 0;
	}
	fputc(']', stdout);
}

/* One stderr line per setting that decided the result. */
static void print_text_notes(const options* opt, const char* name, const json5z_notes* notes)
{
	static const char mute[] = "Mute with JSON5Z_MUTE_INFO=1.";
	char from[1024];
	const json5z_note* ls = &notes->line_separators;
	if (ls->count) {
		const setting* s = &opt->settings[SETTING_LINE_SEPARATORS];
		const int many = ls->count != 1;
		const char* effect = s->value == JSON5Z_LINE_SEPARATORS_END_LINE ? (many ? "ended lines" : "ended a line")
		                                                                   : (many ? "stayed on their lines" : "stayed on its line");
		fprintf(stderr, "json5z: note: %s: %zu line separator%s (U+2028/U+2029) before the failure %s, first at line %zu, column %zu (byte %zu); line_separators=%s (%s). %s\n",
			name, ls->count, many ? "s" : "", effect, ls->first.line, ls->first.column, ls->first.offset,
			setting_defs[SETTING_LINE_SEPARATORS].values[s->value], source_text(s, from, sizeof from), mute);
	}
	const json5z_note* ai = &notes->astral_identifiers;
	if (ai->count) {
		const setting* s = &opt->settings[SETTING_ASTRAL_IDENTIFIERS];
		const char* value = setting_defs[SETTING_ASTRAL_IDENTIFIERS].values[s->value];
		if (s->value == JSON5Z_ASTRAL_IDENTIFIERS_REJECT)
			fprintf(stderr, "json5z: note: %s: an identifier character beyond U+FFFF in an unquoted key at line %zu, column %zu (byte %zu) was rejected; astral_identifiers=%s (%s). %s\n",
				name, ai->first.line, ai->first.column, ai->first.offset, value, source_text(s, from, sizeof from), mute);
		else
			fprintf(stderr, "json5z: note: %s: %zu identifier character%s beyond U+FFFF in unquoted keys %s accepted, first at line %zu, column %zu (byte %zu); astral_identifiers=%s (%s). %s\n",
				name, ai->count, ai->count != 1 ? "s" : "", ai->count != 1 ? "were" : "was", ai->first.line, ai->first.column,
				ai->first.offset, value, source_text(s, from, sizeof from), mute);
	}
	const json5z_note* el = &notes->escaped_literals;
	if (el->count) {
		const setting* s = &opt->settings[SETTING_ESCAPED_LITERALS];
		const char* value = setting_defs[SETTING_ESCAPED_LITERALS].values[s->value];
		if (s->value == JSON5Z_ESCAPED_LITERALS_REJECT)
			fprintf(stderr, "json5z: note: %s: a Unicode escape in a literal at line %zu, column %zu (byte %zu) was rejected; escaped_literals=%s (%s). %s\n",
				name, el->first.line, el->first.column, el->first.offset, value, source_text(s, from, sizeof from), mute);
		else
			fprintf(stderr, "json5z: note: %s: %zu Unicode escape%s in literals %s read as %s, first at line %zu, column %zu (byte %zu); escaped_literals=%s (%s). %s\n",
				name, el->count, el->count != 1 ? "s" : "", el->count != 1 ? "were" : "was", el->count != 1 ? "letters" : "a letter",
				el->first.line, el->first.column, el->first.offset, value, source_text(s, from, sizeof from), mute);
	}
	const json5z_note* nr = &notes->number_range;
	if (nr->count) {
		const setting* s = &opt->settings[SETTING_NUMBER_RANGE];
		const char* value = setting_defs[SETTING_NUMBER_RANGE].values[s->value];
		if (s->value == JSON5Z_NUMBER_RANGE_BINARY64)
			fprintf(stderr, "json5z: note: %s: a number at line %zu, column %zu (byte %zu) rounds to infinity in binary64 and was rejected; number_range=%s (%s). %s\n",
				name, nr->first.line, nr->first.column, nr->first.offset, value, source_text(s, from, sizeof from), mute);
		else
			fprintf(stderr, "json5z: note: %s: %zu number%s that round%s to infinity in binary64 %s accepted, first at line %zu, column %zu (byte %zu); number_range=%s (%s). %s\n",
				name, nr->count, nr->count != 1 ? "s" : "", nr->count != 1 ? "" : "s", nr->count != 1 ? "were" : "was",
				nr->first.line, nr->first.column, nr->first.offset, value, source_text(s, from, sizeof from), mute);
	}
	const json5z_note* md = &notes->max_depth;
	if (md->count) {
		const setting* s = &opt->settings[SETTING_MAX_DEPTH];
		fprintf(stderr, "json5z: note: %s: nesting deeper than %zu at line %zu, column %zu (byte %zu) was rejected; max_depth=%zu (%s). %s\n",
			name, s->value, md->first.line, md->first.column, md->first.offset, s->value, source_text(s, from, sizeof from), mute);
	}
}

static void report(const options* opt, const char* name, int status, const json5z_location* at, const json5z_notes* notes)
{
	const char* verdict = status == JSON5Z_VALID ? "valid" : status == JSON5Z_INVALID ? "invalid" : "incomplete";
	if (opt->mode == OUTPUT_QUIET) return;
	if (opt->mode == OUTPUT_JSON) {
		fputs("{\"path\":", stdout);
		print_json_string(stdout, name);
		fprintf(stdout, ",\"verdict\":\"%s\"", verdict);
		if (status != JSON5Z_VALID) fprintf(stdout, ",\"offset\":%zu,\"line\":%zu,\"column\":%zu", at->offset, at->line, at->column);
		print_json_notes(opt, notes);
		fputs("}\n", stdout);
		return;
	}
	const int ok = status == JSON5Z_VALID;
	const char* mark = opt->ascii ? (ok ? "OK  " : "FAIL") : (ok ? "✓" : "✗");
	const char* on = opt->color ? (ok ? "\x1b[32m" : "\x1b[31m") : "";
	const char* off = opt->color ? "\x1b[0m" : "";
	if (ok) printf("%s%s%s %s: valid\n", on, mark, off, name);
	else if (status == JSON5Z_INVALID) printf("%s%s%s %s: invalid at line %zu, column %zu (byte %zu)\n", on, mark, off, name, at->line, at->column, at->offset);
	else printf("%s%s%s %s: incomplete, input ended at line %zu, column %zu (byte %zu)\n", on, mark, off, name, at->line, at->column, at->offset);
	if (!opt->mute_info) {
		fflush(stdout);
		print_text_notes(opt, name, notes);
	}
}

/* Validate one input stream. Returns a json5z_status, or -3 on read error. */
static int validate_stream(const options* opt, FILE* in, json5z_location* at, json5z_notes* notes)
{
	static uint8_t buffer[64 * 1024];
	const json5z_options lib = {
		(int)opt->settings[SETTING_LINE_SEPARATORS].value,
		(int)opt->settings[SETTING_ASTRAL_IDENTIFIERS].value,
		(int)opt->settings[SETTING_ESCAPED_LITERALS].value,
		(int)opt->settings[SETTING_NUMBER_RANGE].value,
		opt->settings[SETTING_MAX_DEPTH].value,
	};
	json5z_validator* v = NULL;
	int status = json5z_validator_create(&lib, &v);
	if (status != JSON5Z_VALID) return status;
	size_t n;
	while ((n = fread(buffer, 1, sizeof buffer, in)) > 0) {
		status = json5z_validator_feed(v, buffer, n);
		if (status != JSON5Z_VALID) break;
	}
	if (status == JSON5Z_VALID) status = ferror(in) ? -3 : json5z_validator_finish(v, at, notes);
	json5z_validator_free(v);
	return status;
}

/* Returns the exit-status contribution of one input. */
static int check_input(const options* opt, const char* arg)
{
	const int use_stdin = is_stdin(arg);
	const char* name = use_stdin ? "-" : arg;
	FILE* in = use_stdin ? stdin : fopen(arg, "rb");
	if (!in) {
		fprintf(stderr, "json5z: cannot open '%s': %s\n", arg, strerror(errno));
		return EXIT_TROUBLE;
	}
	json5z_location at = { 0, 0, 0 };
	json5z_notes notes;
	memset(&notes, 0, sizeof notes);
	const int status = validate_stream(opt, in, &at, &notes);
	if (!use_stdin) fclose(in);
	switch (status) {
	case JSON5Z_VALID: report(opt, name, status, &at, &notes); return EXIT_ALL_VALID;
	case JSON5Z_INVALID:
	case JSON5Z_INCOMPLETE: report(opt, name, status, &at, &notes); return EXIT_SOME_INVALID;
	case JSON5Z_OUT_OF_MEMORY: fprintf(stderr, "json5z: %s: out of memory, no verdict\n", name); return EXIT_TROUBLE;
	default: fprintf(stderr, "json5z: %s: read error\n", name); return EXIT_TROUBLE;
	}
}

/* The default settings file path, written to buf, or NULL when there is no
 * home directory to look in. */
static const char* default_settings_path(char* buf, size_t size)
{
#ifdef _WIN32
	const char* appdata = getenv("APPDATA");
	if (appdata && *appdata) {
		snprintf(buf, size, "%s\\json5z\\config.toml", appdata);
		return buf;
	}
	return NULL;
#else
	const char* xdg = getenv("XDG_CONFIG_HOME");
	if (xdg && xdg[0] == '/') {
		snprintf(buf, size, "%s/json5z/config.toml", xdg);
		return buf;
	}
	const char* home = getenv("HOME");
	if (home && *home) {
		snprintf(buf, size, "%s/.config/json5z/config.toml", home);
		return buf;
	}
	return NULL;
#endif
}

/* A flag that takes a value, as --flag=VALUE or --flag VALUE. Returns the
 * value, or NULL when `a` is not this flag; *missing is set when it is but
 * no value follows. */
static const char* flag_value(const char* flag, int argc, char** argv, int* i, int* missing)
{
	const char* a = argv[*i];
	const size_t len = strlen(flag);
	if (strncmp(a, flag, len) != 0) return NULL;
	if (a[len] == '=') return a + len + 1;
	if (a[len] != '\0') return NULL;
	if (*i + 1 >= argc) {
		*missing = 1;
		return NULL;
	}
	return argv[++*i];
}

int main(int argc, char** argv)
{
#ifdef _WIN32
	_setmode(_fileno(stdin), _O_BINARY);
#endif
#ifdef JSON5Z_DEBUG_BUILD
	if (!getenv("MUTE_DEBUG_STATUS")) fputs("\x1b[33mDEBUG BUILD\x1b[0m\n", stderr);
#endif
	const char* no_color = getenv("NO_COLOR");
	const char* mute_info = getenv("JSON5Z_MUTE_INFO");
	options opt;
	memset(&opt, 0, sizeof opt);
	opt.mode = OUTPUT_TEXT;
	opt.color = isatty(fileno(stdout)) && !(no_color && *no_color);
	opt.mute_info = mute_info && *mute_info;
	/* Options may appear anywhere before "--"; everything else is a FILE.
	 * Setting flags are kept in order and applied after the file and
	 * environment, so the last one wins. */
	const char** files = malloc(sizeof(char*) * (size_t)(argc > 1 ? argc : 1));
	const char** flag_values = malloc(sizeof(char*) * (size_t)(argc > 1 ? argc : 1));
	int* flag_settings = malloc(sizeof(int) * (size_t)(argc > 1 ? argc : 1));
	if (!files || !flag_values || !flag_settings) {
		fputs("json5z: out of memory\n", stderr);
		return EXIT_TROUBLE;
	}
	int file_count = 0, flag_count = 0, only_files = 0, want_print_config = 0;
	const char* config_path = NULL;
	for (int i = 1; i < argc; i++) {
		const char* a = argv[i];
		if (only_files || a[0] != '-' || strcmp(a, "-") == 0) {
			if (!only_files && strcmp(a, "/?") == 0) a = "--help";
			else {
				files[file_count++] = a;
				continue;
			}
		}
		int missing = 0;
		const char* value = NULL;
		int setting_index = -1;
		for (int s = 0; s < SETTING_COUNT && !value && !missing; s++) {
			value = flag_value(setting_defs[s].flag, argc, argv, &i, &missing);
			if (value || missing) setting_index = s;
		}
		if (!value && !missing) {
			value = flag_value("--config", argc, argv, &i, &missing);
			if (value) {
				config_path = value;
				continue;
			}
		}
		if (missing) {
			fprintf(stderr, "json5z: %s needs a value (try --help)\n", a);
			return EXIT_TROUBLE;
		}
		if (value) {
			flag_values[flag_count] = value;
			flag_settings[flag_count++] = setting_index;
			continue;
		}
		if (strcmp(a, "--") == 0) {
			only_files = 1;
		} else if (strcmp(a, "-h") == 0 || strcmp(a, "--help") == 0) {
			fputs(usage, stdout);
			return EXIT_ALL_VALID;
		} else if (strcmp(a, "--about") == 0) {
			printf("json5z %s: spec-accurate JSON5 validator (%s, %s build)\n", JSON5Z_VERSION, JSON5Z_TARGET, JSON5Z_BUILD_MODE);
			return EXIT_ALL_VALID;
		} else if (strcmp(a, "--print-config") == 0) {
			want_print_config = 1;
		} else if (strcmp(a, "--json") == 0) {
			opt.mode = OUTPUT_JSON;
		} else if (strcmp(a, "-q") == 0 || strcmp(a, "--quiet") == 0) {
			opt.mode = OUTPUT_QUIET;
		} else if (strcmp(a, "--no-color") == 0 || strcmp(a, "--no-ansi") == 0) {
			opt.color = 0;
		} else if (strcmp(a, "--ascii") == 0 || strcmp(a, "--simple") == 0) {
			opt.ascii = 1;
			opt.color = 0;
		} else {
			fprintf(stderr, "json5z: unknown option '%s' (try --help)\n", a);
			return EXIT_TROUBLE;
		}
	}

	if (config_path && is_stdin(config_path)) {
		int doc_stdin = file_count == 0 && !want_print_config;
		for (int i = 0; i < file_count; i++) doc_stdin |= is_stdin(files[i]);
		if (doc_stdin) {
			fputs("json5z: the settings file and a document cannot both come from standard input\n", stderr);
			return EXIT_TROUBLE;
		}
	}
	char default_path[4096];
	const char* settings_path = config_path ? config_path : default_settings_path(default_path, sizeof default_path);
	if (settings_path && load_settings_file(&opt, settings_path, config_path == NULL) != 0) return EXIT_TROUBLE;
	if (load_settings_environment(&opt) != 0) return EXIT_TROUBLE;
	for (int f = 0; f < flag_count; f++) {
		const setting_def* def = &setting_defs[flag_settings[f]];
		if (set_setting(&opt.settings[flag_settings[f]], def, flag_values[f], SOURCE_FLAG, def->flag, def->flag) != 0) return EXIT_TROUBLE;
	}
	free(flag_values);
	free(flag_settings);
	if (want_print_config) {
		print_config(&opt, settings_path);
		free(files);
		return EXIT_ALL_VALID;
	}

	int worst = EXIT_ALL_VALID;
	if (file_count == 0) {
		worst = check_input(&opt, "-");
	} else {
		for (int i = 0; i < file_count; i++) {
			const int r = check_input(&opt, files[i]);
			if (r > worst) worst = r;
		}
	}
	free(files);
	return worst;
}
