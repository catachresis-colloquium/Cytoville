#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# Repository adapter for the canonical Proven raw collectors. No proven-test claim.
# Arguments: checkout output-directory role canonical-suite
set -euo pipefail
policy=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
checkout=$(realpath "${1:?}")
output=$(realpath -m "${2:?}")
role=${3:?}
suite=$(realpath "${4:?}")
[[ $role == base || $role == candidate ]] || exit 2
: "${BASE_SHA:?}" "${CANDIDATE_SHA:?}" "${GITHUB_RUN_ID:?}" "${GITHUB_RUN_ATTEMPT:?}"
: "${GITHUB_REPOSITORY:?}" "${GITHUB_EVENT_NAME:?}"
[[ $BASE_SHA =~ ^[0-9a-f]{40}$ && $CANDIDATE_SHA =~ ^[0-9a-f]{40}$ ]] || exit 2
commit=$CANDIDATE_SHA
[[ $role != base ]] || commit=$BASE_SHA
cd "$checkout"
[[ $(git rev-parse HEAD) == "$commit" ]] || { echo 'Wrong coverage checkout' >&2; exit 1; }
[[ ! -e $output ]] || { echo 'Refusing stale coverage output' >&2; exit 1; }
mkdir -p "$output"
# Instrument both Cargo tests and the binaries exercised by real input journeys.
# Read the pinned tool's environment as data, never as executable shell input.
# This hosted Linux adapter accepts plain or single-quoted simple values only;
# unsupported quoting, metacharacters, duplicate or unexpected keys fail closed.
coverage_env=$(cargo llvm-cov show-env --no-cfg-coverage)
declare -A coverage_keys=()
safe_value='^[-a-zA-Z0-9_./:%=,+ ]*$'
single_quote="'"
while IFS='=' read -r key value; do
  case "$key" in
    LLVM_PROFILE_FILE|RUSTFLAGS|RUSTDOCFLAGS|CARGO_LLVM_COV|CARGO_LLVM_COV_SHOW_ENV|CARGO_LLVM_COV_TARGET_DIR|CARGO_LLVM_COV_BUILD_DIR) ;;
    *) echo 'Unsupported coverage environment key' >&2; exit 2 ;;
  esac
  [[ ! -v coverage_keys[$key] ]] || { echo 'Duplicate coverage environment key' >&2; exit 2; }
  coverage_keys[$key]=1
  if [[ ${#value} -ge 2 && $value == "$single_quote"*"$single_quote" ]]; then value=${value:1:${#value}-2}; fi
  [[ $value =~ $safe_value ]] || { echo 'Unsupported coverage environment value' >&2; exit 2; }
  export "$key=$value"
done <<< "$coverage_env"
[[ -v coverage_keys[RUSTFLAGS] && -v coverage_keys[LLVM_PROFILE_FILE] && -v coverage_keys[CARGO_LLVM_COV_TARGET_DIR] ]] || exit 2
[[ $RUSTFLAGS == *'-C instrument-coverage'* && $LLVM_PROFILE_FILE == *%p* && -n $CARGO_LLVM_COV_TARGET_DIR ]] || exit 2
unset CARGO_ENCODED_RUSTFLAGS CARGO_ENCODED_RUSTDOCFLAGS
cargo llvm-cov clean --workspace
cargo test --workspace --all-targets --locked
CYTOVILLE_ACCEPTANCE_ROOT="$checkout" bash "$policy/scripts/cytoville-e2e.sh"
CYTOVILLE_ACCEPTANCE_ROOT="$checkout" CYTOVILLE_E2E_TLS=1 bash "$policy/scripts/cytoville-e2e.sh"
CYTOVILLE_ACCEPTANCE_ROOT="$checkout" CYTOVILLE_ACCEPTANCE_OUTPUT="$output/graphical" \
  CYTOVILLE_ACCEPTANCE_COVERAGE=1 \
  xvfb-run -a -s '-screen 0 1440x960x24 -nolisten tcp' bash "$policy/scripts/cytoville-graphical-acceptance.sh"
cargo build --locked -p cytoville-runtime --bin cytoville-server
worker="$(cargo metadata --format-version 1 --no-deps | jq -er .target_directory)/debug/cytoville-server"
(
  cd server
  # Export suppresses Mix's independent default 90% summary. The judge enforces 80/5.
  [[ ! -e cover/queue.coverdata ]] || { echo 'Refusing stale BEAM coverage' >&2; exit 1; }
  CYTOVILLE_WORKER="$worker" MIX_ENV=test mix test --cover --export-coverage queue
  MIX_ENV=test mix run --no-start "$suite/scripts/coverdata-to-lcov.exs" cover/queue.coverdata "$output/elixir.lcov"
)
cargo llvm-cov report --json --output-path "$output/llvm.json"
for report in llvm.json elixir.lcov; do
  tool=cargo-llvm-cov
  version=$(cargo llvm-cov --version)
  if [[ $report == elixir.lcov ]]; then tool=erlang-cover; version=$(elixir --version); fi
  jq -n --arg repo "$GITHUB_REPOSITORY" --arg commit "$commit" --arg run "$GITHUB_RUN_ID" \
    --arg tool "$tool" --arg version "$version" \
    '{schema:"hypatia.proven-coverage.report-meta/1",repo:$repo,commit:$commit,run_id:$run,
      role:"raw",tool:$tool,tool_version:$version}' > "$output/$report.meta.json"
done
jq -n --arg repo "$GITHUB_REPOSITORY" --arg commit "$commit" --arg role "$role" \
  --arg base "$BASE_SHA" --arg candidate "$CANDIDATE_SHA" --arg event "$GITHUB_EVENT_NAME" \
  --arg run "$GITHUB_RUN_ID" --arg attempt "$GITHUB_RUN_ATTEMPT" \
  --arg rust "$(sha256sum "$output/llvm.json" | cut -d ' ' -f 1)" \
  --arg elixir "$(sha256sum "$output/elixir.lcov" | cut -d ' ' -f 1)" \
  '{schema:"cytoville.raw-coverage/1",scope:"linux-rust-workspace+graphical+tls+elixir-server-v2",
    repo:$repo,commit:$commit,base:$base,candidate:$candidate,event:$event,
    run_id:$run,run_attempt:$attempt,role:$role,tests_passed:true,
    sha256:{"llvm.json":$rust,"elixir.lcov":$elixir}}' > "$output/receipt.json"
