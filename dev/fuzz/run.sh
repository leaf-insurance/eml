#!/usr/bin/env bash
# Fuzzes eml's JavaScript build with jazzer.js (assumptions.md §B.6).
#
# Usage: dev/fuzz/run.sh [seconds]   (default 600)
#
# Seeds are go-fuzz-corpus/mail (Apache-2.0), fetched at a pinned commit,
# and the messages under test/fixtures. New inputs go to dev/fuzz/corpus,
# and findings to dev/fuzz/findings. A finding is reproduced with
#   npx jazzer fuzz.js --sync <file>
set -euo pipefail

seconds="${1:-600}"
seeds_commit=c42c1b2914c7503500996ee15927d3ab3d2ba968
here="$(cd "$(dirname "$0")" && pwd)"
root="$here/../.."

cd "$root"
gleam build --target javascript

cd "$here"
npm ci --no-audit --no-fund

if [ ! -d seeds/go-fuzz-corpus ]; then
  mkdir -p seeds/go-fuzz-corpus
  git -C seeds/go-fuzz-corpus init -q
  git -C seeds/go-fuzz-corpus fetch -q --depth 1 \
    https://github.com/dvyukov/go-fuzz-corpus.git "$seeds_commit"
  git -C seeds/go-fuzz-corpus checkout -q FETCH_HEAD -- mail/corpus
fi
mkdir -p seeds/fixtures corpus findings
find "$root/test/fixtures" -type f \
  -not -name '*.expected' -not -name '*.md' -not -name '*.txt' \
  -not -name LICENSE -not -name NOTICE \
  -exec sh -c 'cp "$1" "seeds/fixtures/$(basename "$(dirname "$1")")-$(basename "$1")"' _ {} \;

# Inputs are capped at 64 KiB, and an input that takes more than 10 seconds
# is a finding: the parser is meant to be linear.
npx jazzer fuzz.js --sync corpus seeds/go-fuzz-corpus/mail/corpus seeds/fixtures \
  -- -max_total_time="$seconds" -max_len=65536 -timeout=10 \
  -artifact_prefix=findings/
