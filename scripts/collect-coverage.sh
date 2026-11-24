#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# Repository adapter for the canonical Proven raw collectors. No proven-test claim.
# Arguments: checkout output-directory role canonical-suite
set -euo pipefail
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
# Same workspace command as the canonical collector, with all targets explicit.
# No package, path or test-name exclusion; no --ignore-run-fail or cfg(coverage).
cargo llvm-cov --workspace --all-targets --locked --no-cfg-coverage --json --output-path "$output/llvm.json"
cargo build --locked -p cytoville-runtime --bin cytoville-server
worker="$(cargo metadata --format-version 1 --no-deps | jq -er .target_directory)/debug/cytoville-server"
(
  cd server
  # Export suppresses Mix's independent default 90% summary. The judge enforces 80/5.
  [[ ! -e cover/queue.coverdata ]] || { echo 'Refusing stale BEAM coverage' >&2; exit 1; }
  CYTOVILLE_WORKER="$worker" MIX_ENV=test mix test --cover --export-coverage queue
  MIX_ENV=test mix run --no-start "$suite/scripts/coverdata-to-lcov.exs" cover/queue.coverdata "$output/elixir.lcov"
)
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
  '{schema:"cytoville.raw-coverage/1",scope:"linux-rust-workspace-all-targets+elixir-server-v1",
    repo:$repo,commit:$commit,base:$base,candidate:$candidate,event:$event,
    run_id:$run,run_attempt:$attempt,role:$role,tests_passed:true,
    sha256:{"llvm.json":$rust,"elixir.lcov":$elixir}}' > "$output/receipt.json"
