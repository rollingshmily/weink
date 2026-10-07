#!/usr/bin/env bash
set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_dir"

if ! command -v rg >/dev/null 2>&1; then
    echo "error: ripgrep (rg) is required for the Lua namespace check" >&2
    exit 1
fi

failed=0

for legacy_dir in lib ui; do
    if [[ -d "$legacy_dir" ]]; then
        echo "error: project modules must not be added to root-level $legacy_dir/" >&2
        failed=1
    fi
done

legacy_pattern='require[[:space:]]*\([[:space:]]*["'\''](lib|ui)\.|package\.(loaded|preload)[[:space:]]*\[[[:space:]]*["'\''](lib|ui)\.'
if rg -n --pcre2 "$legacy_pattern" --glob '*.lua' main.lua _meta.lua weink; then
    echo "error: use weink.lib.* or weink.ui.* for project-owned Lua modules" >&2
    failed=1
fi

if rg -n 'require[[:space:]]*\([[:space:]]*["'\'']logger["'\'']' \
    --glob '*.lua' \
    --glob '!weink/lib/logger.lua' \
    main.lua _meta.lua weink; then
    echo "error: use weink.lib.logger so project log messages receive a consistent prefix" >&2
    failed=1
fi

unexpected_modules="$(
    find weink -type f -name '*.lua' \
        ! -path 'weink/lib/*' \
        ! -path 'weink/ui/*' \
        -print
)"
if [[ -n "$unexpected_modules" ]]; then
    echo "error: Lua modules below weink/ must be classified under lib/ or ui/:" >&2
    echo "$unexpected_modules" >&2
    failed=1
fi

exit "$failed"
