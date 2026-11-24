#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
set -euo pipefail
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
scratch=$(mktemp -d)
trap 'rm -rf -- "$scratch"' EXIT
mkdir -p "$scratch/bin" "$scratch/source" "$scratch/suite"
export BASE_SHA=1111111111111111111111111111111111111111
export CANDIDATE_SHA=2222222222222222222222222222222222222222
export GITHUB_RUN_ID=17 GITHUB_RUN_ATTEMPT=2 GITHUB_EVENT_NAME=pull_request
export GITHUB_REPOSITORY=catachresis-colloquium/Cytoville
cat > "$scratch/bin/git" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$CANDIDATE_SHA"
SH
cat > "$scratch/bin/cargo" <<'SH'
#!/usr/bin/env bash
echo 'intentional test failure' >&2
exit 19
SH
chmod +x "$scratch/bin/git" "$scratch/bin/cargo"
export PATH="$scratch/bin:$PATH"
status=0
bash "$root/scripts/collect-coverage.sh" "$scratch/source" "$scratch/failed" candidate "$scratch/suite" > "$scratch/log" 2>&1 || status=$?
[[ $status == 19 && ! -e $scratch/failed/receipt.json ]] || {
  cat "$scratch/log"; echo 'FAIL: test failure was swallowed' >&2; exit 1;
}
status=0
bash "$root/scripts/collect-coverage.sh" "$scratch/source" "$scratch/wrong" base "$scratch/suite" > "$scratch/log" 2>&1 || status=$?
[[ $status != 0 && ! -e $scratch/wrong ]] || { echo 'FAIL: wrong revision accepted' >&2; exit 1; }
mkdir "$scratch/stale"
printf 'retain\n' > "$scratch/stale/marker"
status=0
bash "$root/scripts/collect-coverage.sh" "$scratch/source" "$scratch/stale" candidate "$scratch/suite" > "$scratch/log" 2>&1 || status=$?
[[ $status != 0 && $(cat "$scratch/stale/marker") == retain ]] || { echo 'FAIL: stale output reused' >&2; exit 1; }
echo 'PASS: collection rejects failed tests, wrong revisions and stale output'
