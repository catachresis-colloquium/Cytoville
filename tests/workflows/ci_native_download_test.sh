#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# No network, extraction or compiler: exercise downloader refusal boundaries.
set -euo pipefail
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
scratch=$(mktemp -d)
trap 'rm -rf -- "$scratch"' EXIT
mkdir -p "$scratch/bin"
cat > "$scratch/bin/curl" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
[[ " $* " == *' --connect-timeout 15 '* && " $* " == *' --max-time 180 '* ]] || exit 95
printf 'attempt\n' >> "$RUNNER_TEMP/attempts"
[[ $CASE != unavailable ]] || exit 28
# The first mirror times out; the next supplies an archive for hash validation.
[[ $(wc -l < "$RUNNER_TEMP/attempts") -gt 1 ]] || exit 28
while [[ $# -gt 0 ]]; do
  if [[ $1 == -o ]]; then printf 'untrusted fixture\n' > "$2"; exit 0; fi
  shift
done
exit 96
SH
cat > "$scratch/bin/sha256sum" <<'SH'
#!/usr/bin/env bash
read -r expected archive
[[ $expected == 70e49664a74374b48b51e6f3fdfbf437f6395d42509050588bd49abe52ba3d00 && -s $archive ]] || exit 97
[[ $CASE != tampered ]]
SH
cat > "$scratch/bin/tar" <<'SH'
#!/usr/bin/env bash
touch "$RUNNER_TEMP/extracted"
SH
cat > "$scratch/bin/sudo" <<'SH'
#!/usr/bin/env bash
touch "$RUNNER_TEMP/unexpected-install"
exit 98
SH
chmod +x "$scratch/bin/"*
export PATH="$scratch/bin:$PATH"
for CASE in valid tampered unavailable; do
  export CASE RUNNER_TEMP="$scratch/$CASE" GITHUB_PATH="$scratch/$CASE/path"
  mkdir "$RUNNER_TEMP"
  status=0
  bash "$root/scripts/install-ci-native.sh" --zig-only > "$RUNNER_TEMP/log" 2>&1 || status=$?
  [[ ! -e $RUNNER_TEMP/unexpected-install ]] || exit 1
  if [[ $CASE == valid ]]; then
    [[ $status == 0 && -e $RUNNER_TEMP/extracted && -s $GITHUB_PATH ]] || exit 1
    [[ $(wc -l < "$RUNNER_TEMP/attempts") == 2 ]] || exit 1
  else
    [[ $status != 0 && ! -e $RUNNER_TEMP/extracted && ! -e $GITHUB_PATH ]] || exit 1
  fi
done
echo 'PASS: bounded fallback, pinned hash refusal and Zig-only isolation'
