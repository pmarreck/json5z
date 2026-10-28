#!/usr/bin/env bash
# Memory growth and cleanup cases (profiling.json, mode mg) through ./bm.
exec "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/bm" --mode mg "$@"
