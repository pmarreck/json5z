/* json5z command-line tool: validates JSON5 files through the C ABI in
 * include/json5z.h, streaming each input in fixed-size chunks so memory does
 * not grow with file size. All I/O lives here; the library does none. */

#ifndef _WIN32
#define _POSIX_C_SOURCE 200809L /* fileno, isatty */
#endif

#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "json5z.h"

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

typedef struct options {
	enum output_mode mode;
	int color;
	int ascii;
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
	"Later options override earlier ones.\n"
	"Exit status: 0 all inputs valid, 1 some input invalid or incomplete,\n"
	"2 usage error, unreadable input, or no verdict (out of memory).\n";

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

static void report(const options* opt, const char* name, int status, const json5z_location* at)
{
	const char* verdict = status == JSON5Z_VALID ? "valid" : status == JSON5Z_INVALID ? "invalid" : "incomplete";
	if (opt->mode == OUTPUT_QUIET) return;
	if (opt->mode == OUTPUT_JSON) {
		fputs("{\"path\":", stdout);
		print_json_string(stdout, name);
		fprintf(stdout, ",\"verdict\":\"%s\"", verdict);
		if (status != JSON5Z_VALID) fprintf(stdout, ",\"offset\":%zu,\"line\":%zu,\"column\":%zu", at->offset, at->line, at->column);
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
}

/* Validate one input stream. Returns a json5z_status, or -3 on read error. */
static int validate_stream(FILE* in, json5z_location* at)
{
	static uint8_t buffer[64 * 1024];
	json5z_validator* v = json5z_validator_new();
	if (!v) return JSON5Z_OUT_OF_MEMORY;
	int status = JSON5Z_VALID;
	size_t n;
	while ((n = fread(buffer, 1, sizeof buffer, in)) > 0) {
		status = json5z_validator_feed(v, buffer, n);
		if (status != JSON5Z_VALID) break;
	}
	if (status == JSON5Z_VALID) status = ferror(in) ? -3 : json5z_validator_finish(v, at);
	json5z_validator_free(v);
	return status;
}

/* Returns the exit-status contribution of one input. */
static int check_input(const options* opt, const char* arg)
{
	const int use_stdin = strcmp(arg, "-") == 0 || strcmp(arg, "@stdin") == 0;
	const char* name = use_stdin ? "-" : arg;
	FILE* in = use_stdin ? stdin : fopen(arg, "rb");
	if (!in) {
		fprintf(stderr, "json5z: cannot open '%s': %s\n", arg, strerror(errno));
		return EXIT_TROUBLE;
	}
	json5z_location at = { 0, 0, 0 };
	const int status = validate_stream(in, &at);
	if (!use_stdin) fclose(in);
	switch (status) {
	case JSON5Z_VALID: report(opt, name, status, &at); return EXIT_ALL_VALID;
	case JSON5Z_INVALID:
	case JSON5Z_INCOMPLETE: report(opt, name, status, &at); return EXIT_SOME_INVALID;
	case JSON5Z_OUT_OF_MEMORY: fprintf(stderr, "json5z: %s: out of memory, no verdict\n", name); return EXIT_TROUBLE;
	default: fprintf(stderr, "json5z: %s: read error\n", name); return EXIT_TROUBLE;
	}
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
	options opt = { OUTPUT_TEXT, isatty(fileno(stdout)) && !(no_color && *no_color), 0 };
	/* Options may appear anywhere before "--"; everything else is a FILE. */
	const char** files = malloc(sizeof(char*) * (size_t)(argc > 1 ? argc : 1));
	if (!files) {
		fputs("json5z: out of memory\n", stderr);
		return EXIT_TROUBLE;
	}
	int file_count = 0;
	int only_files = 0;
	for (int i = 1; i < argc; i++) {
		const char* a = argv[i];
		if (only_files || a[0] != '-' || strcmp(a, "-") == 0) {
			if (!only_files && strcmp(a, "/?") == 0) a = "--help";
			else {
				files[file_count++] = a;
				continue;
			}
		}
		if (strcmp(a, "--") == 0) {
			only_files = 1;
		} else if (strcmp(a, "-h") == 0 || strcmp(a, "--help") == 0) {
			fputs(usage, stdout);
			return EXIT_ALL_VALID;
		} else if (strcmp(a, "--about") == 0) {
			printf("json5z %s: spec-accurate JSON5 validator (%s, %s build)\n", JSON5Z_VERSION, JSON5Z_TARGET, JSON5Z_BUILD_MODE);
			return EXIT_ALL_VALID;
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
