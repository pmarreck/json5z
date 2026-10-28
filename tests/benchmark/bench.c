// json5z-bench: fixed JSON5 workloads timed for ./bm, comparing json5z with
// unmodified upstream cj5. It prints one performance-measurement/v1 object
// (see the performance-profile engine) and exits non-zero on any wrong
// verdict, clock failure or allocation failure, so skipped or failed work
// can never look like a fast result.
//
//   json5z-bench measure IMPL KIND SIZES SEED   protocol JSON on stdout
//   json5z-bench emit KIND SIZE SEED            the workload document
//   json5z-bench verdicts KIND SIZE SEED        verdicts on it and on broken copies
//   json5z-bench about                          build mode
//
// IMPL is json5z, cj5-presized (token array sized and touched before timing)
// or cj5-two-pass (count the tokens, allocate, parse: what a caller that does
// not know the document does, all timed). KIND is config, nested, deep,
// strings, numbers or comments. SIZE is the document length in bytes; record
// workloads stop at the first record boundary at or past it.
#define _POSIX_C_SOURCE 200809L

#include <limits.h>
#include <stdarg.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/resource.h>
#include <time.h>

#include "cj5_shim.h"

// Allocator counts from json5z_shim.zig.
typedef struct {
	size_t live, peak, allocations, total;
} bench_counts;

extern int bench_json5z_validate(const uint8_t* data, size_t length, bench_counts* out);
extern const char* bench_build_mode(void);

#ifdef __OPTIMIZE__
static const bool c_optimized = true;
#else
static const bool c_optimized = false;
#endif

enum { WARMUP = 3, SAMPLES = 5, MAX_SIZES = 16 };
enum { VALID = 0, INVALID = 1, INCOMPLETE = 2, NO_VERDICT = -1 };

static void die(const char* fmt, ...)
{
	va_list ap;
	va_start(ap, fmt);
	fputs("json5z-bench: ", stderr);
	vfprintf(stderr, fmt, ap);
	fputc('\n', stderr);
	va_end(ap);
	exit(1);
}

static void usage(const char* fmt, const char* arg)
{
	fputs("json5z-bench: ", stderr);
	fprintf(stderr, fmt, arg);
	fputs("\nusage: json5z-bench measure IMPL KIND SIZES SEED | emit KIND SIZE SEED | verdicts KIND SIZE SEED | about\n", stderr);
	exit(2);
}

// ------------------------------------------------------------ generation

typedef struct {
	char* data;
	size_t len, cap;
} buffer;

static void put(buffer* b, const char* s, size_t n)
{
	if (b->len + n > b->cap) {
		size_t cap = b->cap ? b->cap : 4096;
		while (cap < b->len + n) cap *= 2;
		char* p = realloc(b->data, cap);
		if (!p) die("out of memory generating a workload");
		b->data = p;
		b->cap = cap;
	}
	memcpy(b->data + b->len, s, n);
	b->len += n;
}

#define PUT_LIT(b, s) put((b), (s), sizeof(s) - 1)

static void putf(buffer* b, const char* fmt, ...)
{
	char tmp[1024];
	va_list ap;
	va_start(ap, fmt);
	int n = vsnprintf(tmp, sizeof tmp, fmt, ap);
	va_end(ap);
	if (n < 0 || (size_t)n >= sizeof tmp) die("generator record too long");
	put(b, tmp, (size_t)n);
}

// SplitMix64 (Steele, Lea and Flood, 2014): a published, seedable generator,
// so a seed names the same workload bytes on every platform.
static uint64_t next(uint64_t* state)
{
	uint64_t z = (*state += 0x9E3779B97F4A7C15ull);
	z = (z ^ (z >> 30)) * 0xBF58476D1CE4E5B9ull;
	z = (z ^ (z >> 27)) * 0x94D049BB133111EBull;
	return z ^ (z >> 31);
}

static unsigned below(uint64_t* rng, unsigned n)
{
	return (unsigned)(next(rng) % n);
}

static const char* const words[] = {
	"alpha", "bravo", "charlie", "delta", "echo", "foxtrot", "golf", "hotel",
	"caf\xC3\xA9", "na\xC3\xAFve", "\xE6\xBC\xA2\xE5\xAD\x97", "\xF0\x9F\x98\x80",
	"tab\\there", "line\\nbreak", "quote\\\"d", "back\\\\slash",
};

static void config_record(buffer* b, uint64_t* rng, size_t i)
{
	putf(b, "\t{\n\t\t// entry %zu\n", i);
	putf(b, "\t\tname: 'service-%u',\n", below(rng, 100000));
	putf(b, "\t\tenabled: %s,\n", below(rng, 2) ? "true" : "false");
	putf(b, "\t\tport: %u,\n", 1024 + below(rng, 60000));
	putf(b, "\t\tratio: 0.%03u,\n", below(rng, 1000));
	PUT_LIT(b, "\t\ttags: ['alpha', \"beta\", 'gamma'],\n");
	PUT_LIT(b, "\t\towner: null,\n");
	putf(b, "\t\tlimits: {cpu: %u, memory: '%uMi'},\n\t}", 1 + below(rng, 64), 64 * (1 + below(rng, 64)));
}

static void nested_record(buffer* b, uint64_t* rng)
{
	enum { LEVELS = 8 };
	put(b, "\t", 1);
	for (int i = 0; i < LEVELS; i++) PUT_LIT(b, "{level: [");
	putf(b, "%u", below(rng, 1000000));
	for (int i = 0; i < LEVELS; i++) PUT_LIT(b, "]}");
}

// Upstream cj5 rejects \' inside single quotes and \x escapes, both valid
// JSON5, so the shared workload leaves them out.
static void strings_record(buffer* b, uint64_t* rng)
{
	switch (below(rng, 4)) {
	case 0:
		putf(b, "\t\"plain text %u with \\\"double quotes\\\", a \\\\ backslash, a \\t tab and a \\n newline\"", below(rng, 100000));
		break;
	case 1:
		putf(b, "\t'single quoted %u with \"double quotes\", \\u00e9 escaped, caf\xC3\xA9 raw, \xE6\xBC\xA2\xE5\xAD\x97, \xF0\x9F\x98\x80'", below(rng, 100000));
		break;
	case 2:
		putf(b, "\t\"escapes \\u2603 \\u00fc \\b\\f\\r and number %u\"", below(rng, 100000));
		break;
	default: {
		// A long string of random words, some with escapes.
		put(b, "\t\"", 2);
		unsigned count = 40 + below(rng, 80);
		for (unsigned w = 0; w < count; w++) {
			const char* word = words[below(rng, sizeof words / sizeof words[0])];
			if (w) put(b, " ", 1);
			put(b, word, strlen(word));
		}
		put(b, "\"", 1);
	}
	}
}

// Upstream cj5 rejects exponents (1e5), negative hexadecimal, Infinity and
// NaN, all valid JSON5, so the shared workload leaves them out.
static void numbers_record(buffer* b, uint64_t* rng)
{
	putf(b, "\t[%u, -%u, %u.%03u, -%u.%u, 0x%X, 0x%x, +%u, .%u, %u., -.%u]",
		below(rng, 1000000), below(rng, 1000000), below(rng, 1000), below(rng, 1000),
		below(rng, 10), below(rng, 1000), below(rng, 0x7FFFFFFF), below(rng, 0xFFFF),
		below(rng, 1000), below(rng, 1000), below(rng, 1000), below(rng, 1000));
}

static void comments_record(buffer* b, uint64_t* rng, size_t i)
{
	putf(b, "\t// line comment %zu: the quick brown fox jumps over the lazy dog\n", i);
	putf(b, "\t/* block comment %u */\n", below(rng, 100000));
	if (i % 4 == 0) putf(b, "\t/*\n\t * multi-line block comment %zu\n\t */\n", i);
	putf(b, "\t%u", below(rng, 1000000));
}

typedef enum { CONFIG, NESTED, DEEP, STRINGS, NUMBERS, COMMENTS, KINDS } kind;
static const char* const kind_names[KINDS] = { "config", "nested", "deep", "strings", "numbers", "comments" };

static kind parse_kind(const char* name)
{
	for (int k = 0; k < KINDS; k++)
		if (strcmp(name, kind_names[k]) == 0) return (kind)k;
	usage("unknown workload kind '%s'", name);
	return KINDS;
}

// The workload document for (kind, size, seed). Deep is exactly `size`
// bytes of nested arrays; the others are a top-level array of records with
// a trailing comma, at least `size` bytes long.
static buffer generate(kind k, size_t size, uint64_t seed)
{
	buffer b = { 0 };
	uint64_t rng = seed ^ (0xA5A5A5A5ull * (uint64_t)(k + 1));
	if (k == DEEP) {
		size_t depth = size / 2;
		for (size_t i = 0; i < depth; i++) put(&b, "[", 1);
		for (size_t i = 0; i < depth; i++) put(&b, "]", 1);
		return b;
	}
	put(&b, "[\n", 2);
	for (size_t i = 0; b.len + 4 < size; i++) {
		switch (k) {
		case CONFIG: config_record(&b, &rng, i); break;
		case NESTED: nested_record(&b, &rng); break;
		case STRINGS: strings_record(&b, &rng); break;
		case NUMBERS: numbers_record(&b, &rng); break;
		default: comments_record(&b, &rng, i); break;
		}
		put(&b, ",\n", 2);
	}
	put(&b, "]\n", 2);
	return b;
}

// ------------------------------------------------------------ implementations

typedef enum { JSON5Z, CJ5_PRESIZED, CJ5_TWO_PASS, IMPLS } impl;
static const char* const impl_names[IMPLS] = { "json5z", "cj5-presized", "cj5-two-pass" };

static impl parse_impl(const char* name)
{
	for (int i = 0; i < IMPLS; i++)
		if (strcmp(name, impl_names[i]) == 0) return (impl)i;
	usage("unknown implementation '%s'", name);
	return IMPLS;
}

static int cj5_verdict(int code)
{
	switch (code) {
	case BENCH_CJ5_NONE: return VALID;
	case BENCH_CJ5_INVALID: return INVALID;
	case BENCH_CJ5_INCOMPLETE: return INCOMPLETE;
	default: return NO_VERDICT;
	}
}

static int cj5_length(size_t n)
{
	if (n > INT_MAX) die("document too large for cj5's int length");
	return (int)n;
}

// One token suffices for the counting pass; upstream parses to the end after
// overflow and reports how many tokens the document needs.
static _Alignas(16) unsigned char probe[256];

static int cj5_count(const char* d, size_t n, int* tokens)
{
	if (bench_cj5_token_size() > sizeof probe) die("cj5_token larger than the probe buffer");
	int code = bench_cj5_parse(d, cj5_length(n), probe, 1, tokens);
	return code == BENCH_CJ5_OVERFLOW ? BENCH_CJ5_NONE : code;
}

// cj5-two-pass: count, allocate, parse, free.
static int cj5_two_pass(const char* d, size_t n, bench_counts* counts, int* tokens)
{
	*counts = (bench_counts){ 0 };
	int code = cj5_count(d, n, tokens);
	if (code != BENCH_CJ5_NONE) return cj5_verdict(code);
	size_t bytes = (size_t)*tokens * bench_cj5_token_size();
	void* array = malloc(bytes);
	if (!array) die("out of memory for %d cj5 tokens", *tokens);
	*counts = (bench_counts){ .live = bytes, .peak = bytes, .allocations = 1, .total = bytes };
	int needed = 0;
	code = bench_cj5_parse(d, cj5_length(n), array, *tokens, &needed);
	free(array);
	counts->live = 0;
	return cj5_verdict(code);
}

static int verdict_of(impl which, const char* d, size_t n)
{
	bench_counts counts;
	int tokens;
	if (which == JSON5Z) return bench_json5z_validate((const uint8_t*)d, n, &counts);
	return cj5_two_pass(d, n, &counts, &tokens);
}

// ------------------------------------------------------------ measurement

static int64_t clock_ns(clockid_t id)
{
	struct timespec ts;
	if (clock_gettime(id, &ts) != 0) die("clock_gettime failed");
	return (int64_t)ts.tv_sec * 1000000000 + ts.tv_nsec;
}

typedef struct {
	int64_t cpu_ns[SAMPLES], wall_ns[SAMPLES];
	size_t peak[SAMPLES], allocations[SAMPLES], total[SAMPLES], residual[SAMPLES];
	size_t bytes;
	int tokens;
} row;

static void measure_size(impl which, kind k, size_t size, uint64_t seed, row* r)
{
	buffer doc = generate(k, size, seed);
	const char* d = doc.data;
	size_t n = doc.len;
	r->bytes = n;
	r->tokens = 0;
	if (verdict_of(which, d, n) != VALID) die("%s rejected the %s workload of %zu bytes", impl_names[which], kind_names[k], n);

	void* presized = NULL;
	size_t presized_bytes = 0;
	if (which == CJ5_PRESIZED) {
		if (cj5_count(d, n, &r->tokens) != BENCH_CJ5_NONE) die("cj5 count pass failed");
		presized_bytes = (size_t)r->tokens * bench_cj5_token_size();
		presized = malloc(presized_bytes);
		if (!presized) die("out of memory for %d cj5 tokens", r->tokens);
		memset(presized, 0, presized_bytes); // touch the pages before timing
	}

	for (int i = 0; i < WARMUP + SAMPLES; i++) {
		bench_counts counts = { 0 };
		int verdict;
		int64_t cpu0 = clock_ns(CLOCK_PROCESS_CPUTIME_ID), wall0 = clock_ns(CLOCK_MONOTONIC);
		switch (which) {
		case JSON5Z: verdict = bench_json5z_validate((const uint8_t*)d, n, &counts); break;
		case CJ5_PRESIZED: {
			int needed = 0;
			verdict = cj5_verdict(bench_cj5_parse(d, cj5_length(n), presized, r->tokens, &needed));
			counts = (bench_counts){ .live = 0, .peak = presized_bytes, .allocations = 1, .total = presized_bytes };
			break;
		}
		default: verdict = cj5_two_pass(d, n, &counts, &r->tokens); break;
		}
		int64_t wall1 = clock_ns(CLOCK_MONOTONIC), cpu1 = clock_ns(CLOCK_PROCESS_CPUTIME_ID);
		if (verdict != VALID) die("%s gave a wrong verdict on the %s workload", impl_names[which], kind_names[k]);
		if (i < WARMUP) continue;
		int s = i - WARMUP;
		r->cpu_ns[s] = cpu1 - cpu0 > 0 ? cpu1 - cpu0 : 1;
		r->wall_ns[s] = wall1 - wall0;
		r->peak[s] = counts.peak;
		r->allocations[s] = counts.allocations;
		r->total[s] = counts.total;
		r->residual[s] = counts.live;
		if (r->wall_ns[s] <= 0) die("monotonic clock did not advance");
	}
	free(presized);
	free(doc.data);
}

static void print_i64s(const char* name, const int64_t* v, bool comma)
{
	printf("\"%s\":[", name);
	for (int i = 0; i < SAMPLES; i++) printf("%s%lld", i ? "," : "", (long long)v[i]);
	printf("]%s", comma ? "," : "");
}

static void print_sizes(const char* name, const size_t* v, bool comma)
{
	printf("\"%s\":[", name);
	for (int i = 0; i < SAMPLES; i++) printf("%s%zu", i ? "," : "", v[i]);
	printf("]%s", comma ? "," : "");
}

static uint64_t parse_u64(const char* s, const char* what)
{
	char* end = NULL;
	if (!*s || *s == '-') usage("invalid %s", what);
	unsigned long long v = strtoull(s, &end, 10);
	if (*end) usage("invalid %s", what);
	return (uint64_t)v;
}

static bool debug_build(void)
{
	return strcmp(bench_build_mode(), "Debug") == 0;
}

static int measure(int argc, char** argv)
{
	if (argc != 6) usage("measure takes IMPL KIND SIZES SEED%s", "");
	impl which = parse_impl(argv[2]);
	kind k = parse_kind(argv[3]);
	size_t sizes[MAX_SIZES];
	int count = 0;
	for (char* s = argv[4]; *s;) {
		char* end = NULL;
		unsigned long long v = strtoull(s, &end, 10);
		if (end == s || v == 0 || count == MAX_SIZES || (*end && *end != ',')) usage("invalid sizes '%s'", argv[4]);
		sizes[count++] = (size_t)v;
		s = *end ? end + 1 : end;
	}
	if (count == 0) usage("invalid sizes '%s'", argv[4]);
	uint64_t seed = parse_u64(argv[5], "seed");
	if (debug_build() || !c_optimized) {
		fputs("json5z-bench: refusing to measure an unoptimized build\n", stderr);
		return 2;
	}

	row* rows = calloc((size_t)count, sizeof *rows);
	if (!rows) die("out of memory");
	for (int i = 0; i < count; i++) measure_size(which, k, sizes[i], seed, &rows[i]);

	struct rusage usage_info;
	if (getrusage(RUSAGE_SELF, &usage_info) != 0) die("getrusage failed");
#ifdef __APPLE__
	long long max_rss = (long long)usage_info.ru_maxrss;
#else
	long long max_rss = (long long)usage_info.ru_maxrss * 1024;
#endif
	const char* cores = getenv("PERFORMANCE_CORES");
	bool cores_ok = cores && *cores && strspn(cores, "0123456789") == strlen(cores);

	printf("{\"schema\":\"performance-measurement/v1\",\"correct\":true,\"build_mode\":\"%s\",\"c_optimized\":true,", bench_build_mode());
	printf("\"impl\":\"%s\",\"kind\":\"%s\",\"seed\":%llu,\"generator\":\"splitmix64\",", impl_names[which], kind_names[k], (unsigned long long)seed);
	printf("\"clocks\":{\"cpu_ns\":\"CLOCK_PROCESS_CPUTIME_ID per sample\",\"wall_ns\":\"CLOCK_MONOTONIC per sample\"},\"warmup\":%d,", WARMUP);
	printf("\"allocator_coverage\":\"%s\",",
		which == JSON5Z ? "every allocation json5z's validator requests (counting wrapper over the general-purpose allocator its C ABI uses)"
		: which == CJ5_PRESIZED ? "the cj5 token array, allocated and touched before timing (cj5 itself allocates nothing)"
		: "the cj5 token array, allocated and freed inside each timed sample (cj5 itself allocates nothing)");
	printf("\"max_rss_bytes\":%lld,\"max_rss_scope\":\"whole process peak, including the generated documents\",", max_rss);
	if (cores_ok) printf("\"cores_env\":%s,", cores);
	printf("\"rows\":[");
	for (int i = 0; i < count; i++) {
		row* r = &rows[i];
		int64_t ops[SAMPLES];
		for (int s = 0; s < SAMPLES; s++) ops[s] = (int64_t)r->bytes;
		printf("%s{\"size\":%zu,\"bytes\":%zu,", i ? "," : "", sizes[i], r->bytes);
		if (which != JSON5Z) printf("\"tokens\":%d,", r->tokens);
		printf("\"samples\":{");
		print_i64s("cpu_ns", r->cpu_ns, true);
		print_i64s("wall_ns", r->wall_ns, true);
		print_sizes("peak_bytes", r->peak, true);
		print_sizes("allocation_count", r->allocations, true);
		print_sizes("total_bytes", r->total, true);
		print_i64s("operations", ops, false);
		printf("},");
		print_sizes("residual_bytes", r->residual, false);
		printf("}");
	}
	printf("]}\n");
	free(rows);
	return fflush(stdout) == 0 ? 0 : 1;
}

static const char* verdict_name(int v)
{
	switch (v) {
	case VALID: return "valid";
	case INVALID: return "invalid";
	case INCOMPLETE: return "incomplete";
	default: return "no-verdict";
	}
}

static int verdicts(int argc, char** argv)
{
	if (argc != 5) usage("verdicts takes KIND SIZE SEED%s", "");
	kind k = parse_kind(argv[2]);
	buffer doc = generate(k, (size_t)parse_u64(argv[3], "size"), parse_u64(argv[4], "seed"));
	char* last = NULL;
	for (size_t i = doc.len; i-- > 0;)
		if (doc.data[i] == ']') { last = doc.data + i; break; }
	if (!last) die("workload has no closing bracket");
	size_t truncated = (size_t)(last - doc.data);
	printf("{\"json5z\":\"%s\",\"cj5\":\"%s\",", verdict_name(verdict_of(JSON5Z, doc.data, doc.len)), verdict_name(verdict_of(CJ5_TWO_PASS, doc.data, doc.len)));
	*last = '}';
	printf("\"corrupt_json5z\":\"%s\",\"corrupt_cj5\":\"%s\",", verdict_name(verdict_of(JSON5Z, doc.data, doc.len)), verdict_name(verdict_of(CJ5_TWO_PASS, doc.data, doc.len)));
	printf("\"truncated_json5z\":\"%s\",\"truncated_cj5\":\"%s\"}\n", verdict_name(verdict_of(JSON5Z, doc.data, truncated)), verdict_name(verdict_of(CJ5_TWO_PASS, doc.data, truncated)));
	free(doc.data);
	return 0;
}

static int emit(int argc, char** argv)
{
	if (argc != 5) usage("emit takes KIND SIZE SEED%s", "");
	kind k = parse_kind(argv[2]);
	buffer doc = generate(k, (size_t)parse_u64(argv[3], "size"), parse_u64(argv[4], "seed"));
	size_t written = fwrite(doc.data, 1, doc.len, stdout);
	free(doc.data);
	return written == doc.len && fflush(stdout) == 0 ? 0 : 1;
}

int main(int argc, char** argv)
{
	if (debug_build() && !getenv("MUTE_DEBUG_STATUS")) fputs("\x1b[33mDEBUG BUILD\x1b[0m\n", stderr);
	if (argc < 2) usage("missing command%s", "");
	if (strcmp(argv[1], "measure") == 0) return measure(argc, argv);
	if (strcmp(argv[1], "emit") == 0) return emit(argc, argv);
	if (strcmp(argv[1], "verdicts") == 0) return verdicts(argc, argv);
	if (strcmp(argv[1], "about") == 0 && argc == 2) {
		printf("{\"build_mode\":\"%s\",\"c_optimized\":%s}\n", bench_build_mode(), c_optimized ? "true" : "false");
		return 0;
	}
	usage("unknown command '%s'", argv[1]);
	return 2;
}
