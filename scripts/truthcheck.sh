#!/bin/sh
# Truth-pin: keeps the product facts in this repo pinned to reality.
# POSIX sh, no dependencies beyond git/grep. Run from anywhere.
#
# Forbidden: stale quota figures, the wrong docs host, personal handles,
# and the "midnight UTC" myth (the daily reset is an absolute instant
# derived from the key's local midnight — read `resets_at`).
# Required (when the repo states quotas at all): the current FREE figure
# and the canonical docs host.
set -u

cd "$(dirname "$0")/.." || exit 1

# Tracked text files, minus CHANGELOG history entries (they may legitimately
# describe old facts) and this script (it names the forbidden strings).
if ! files=$(git ls-files 2>/dev/null) || [ -z "$files" ]; then
    files=$(find . -type f ! -path './.git/*' | sed 's|^\./||')
fi
files=$(printf '%s\n' "$files" | grep -v -e '^CHANGELOG\.md$' -e '^scripts/truthcheck\.sh$')

fail=0

hits_of() {
    printf '%s\n' "$files" | xargs grep -inIE -- "$1" 2>/dev/null
}

forbid() {
    hits=$(hits_of "$1")
    if [ -n "$hits" ]; then
        echo "FORBIDDEN ($2):"
        echo "$hits"
        fail=1
    fi
}

forbid 'livetennisapi\.com/docs' 'docs live at docs.livetennisapi.com, not livetennisapi.com/docs'
forbid 'bensynapse' 'no personal handles in repo metadata or docs'
forbid 'midnight UTC' 'the daily reset is NOT midnight UTC; point to resets_at'
forbid '(100[, ]?000|100k).{0,30}(/|per |a )day' 'stale day quota (the free tier is 100/day)'
forbid '(/|per |a )day.{0,30}(100[, ]?000|100k)' 'stale day quota (the free tier is 100/day)'
forbid 'free.{0,60}(1,?000|1k).{0,20}(/|per |a )day' 'FREE is 100/day; 1,000/day is BASIC'

# If quotas are stated anywhere, the current facts must be present.
if [ -n "$(hits_of '(/|per )day')" ]; then
    if [ -z "$(hits_of '100 ?(requests ?)?(/|per )day')" ]; then
        echo "MISSING: the FREE quota must be stated as '100/day' (or '100 requests/day')"
        fail=1
    fi
    if [ -z "$(hits_of 'docs\.livetennisapi\.com')" ]; then
        echo "MISSING: docs.livetennisapi.com must be referenced"
        fail=1
    fi
fi

if [ "$fail" -ne 0 ]; then
    echo "truthcheck: FAILED"
    exit 1
fi
echo "truthcheck: OK"
