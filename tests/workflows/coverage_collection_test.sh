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
case "$*" in
  'llvm-cov show-env --sh --no-cfg-coverage')
    [[ ${FAIL_STAGE:-environment} != environment ]] || exit 19
    echo 'export CYTOVILLE_INSTRUMENTED_TEST=1' ;;
  'llvm-cov clean --workspace')
    [[ ${CYTOVILLE_INSTRUMENTED_TEST:-0} == 1 ]] || exit 99
    [[ $FAIL_STAGE != clean ]] || exit 20 ;;
  'test --workspace --all-targets --locked') exit 21 ;;
  *) echo "unexpected command: $*" >&2; exit 99 ;;
esac
SH
chmod +x "$scratch/bin/git" "$scratch/bin/cargo"
export PATH="$scratch/bin:$PATH"
expected=19
for stage in environment clean test; do
  status=0
  FAIL_STAGE=$stage bash "$root/scripts/collect-coverage.sh" "$scratch/source" "$scratch/failed-$stage" candidate "$scratch/suite" > "$scratch/log" 2>&1 || status=$?
  [[ $status == "$expected" && ! -e $scratch/failed-$stage/receipt.json ]] || {
    cat "$scratch/log"; echo "FAIL: $stage failure was swallowed" >&2; exit 1;
  }
  expected=$((expected + 1))
done
status=0
bash "$root/scripts/collect-coverage.sh" "$scratch/source" "$scratch/wrong" base "$scratch/suite" > "$scratch/log" 2>&1 || status=$?
[[ $status != 0 && ! -e $scratch/wrong ]] || { echo 'FAIL: wrong revision accepted' >&2; exit 1; }
mkdir "$scratch/stale"
printf 'retain\n' > "$scratch/stale/marker"
status=0
bash "$root/scripts/collect-coverage.sh" "$scratch/source" "$scratch/stale" candidate "$scratch/suite" > "$scratch/log" 2>&1 || status=$?
[[ $status != 0 && $(cat "$scratch/stale/marker") == retain ]] || { echo 'FAIL: stale output reused' >&2; exit 1; }
echo 'PASS: collection rejects failed tests, wrong revisions and stale output'
