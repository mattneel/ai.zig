#!/bin/sh
set -eu

if [ "$(uname -s)" != "Linux" ]; then
    exit 0
fi

library=$1
bad_symbols=$(nm -D --defined-only "$library" | awk 'NF >= 3 { print $3 }' | awk '$0 !~ /^ai_/ { print }')
if [ -n "$bad_symbols" ]; then
    echo "non-ai_ dynamic symbols exported by $library:" >&2
    echo "$bad_symbols" >&2
    exit 1
fi
