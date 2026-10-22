#!/usr/bin/env bash
# Pin the vllm/vllm-openai-rocm nightly to overlay: VLLM_COMMIT if set, else the
# newest nightly-<sha> on Docker Hub.
set -euo pipefail

NIGHTLY_REPO="vllm/vllm-openai-rocm"
VLLM_COMMIT="${VLLM_COMMIT:-}"

# Prints the sha of the newest nightly-<sha> tag, or nothing if there is none.
latest_nightly_commit() {
  curl -fsSL "https://hub.docker.com/v2/repositories/${NIGHTLY_REPO}/tags?name=nightly-&ordering=last_updated&page_size=100" \
    | grep -oP '"nightly-\K[0-9a-f]{40}(?=")' | head -n 1
}

if [[ -n "$VLLM_COMMIT" ]]; then
  # Nightlies are tagged with the full sha.
  if [[ ! "$VLLM_COMMIT" =~ ^[0-9a-f]{40}$ ]]; then
    echo "^^^ +++"
    echo "VLLM_COMMIT must be a full 40-character lowercase sha, got '${VLLM_COMMIT}'." >&2
    exit 1
  fi
  vllm_commit="$VLLM_COMMIT"
  echo "--- Using pinned vLLM commit ${vllm_commit}"
else
  echo "--- Resolving newest ${NIGHTLY_REPO}:nightly-<sha> from Docker Hub"
  vllm_commit="$(latest_nightly_commit || true)"
  if [[ -z "$vllm_commit" ]]; then
    echo "^^^ +++"
    echo "Could not find a nightly-<sha> tag on ${NIGHTLY_REPO}." >&2
    echo "Pass VLLM_COMMIT explicitly to bypass the Docker Hub lookup." >&2
    exit 1
  fi
  echo "Resolved nightly commit ${vllm_commit}"
fi
vllm_short="${vllm_commit:0:8}"
base_image="${NIGHTLY_REPO}:nightly-${vllm_commit}"

buildkite-agent meta-data set "vllm-commit" "$vllm_commit"
buildkite-agent meta-data set "overlay-base-image" "$base_image"

echo "vLLM commit  : ${vllm_commit}"
echo "Base image   : ${base_image}"

vllm_commit_url="https://github.com/vllm-project/vllm/commit/${vllm_commit}"
buildkite-agent annotate --style info --context "aiter-overlay" <<EOF
AITER-overlay build

- Base nightly: \`${base_image}\` (vLLM [\`${vllm_short}\`](${vllm_commit_url}))
EOF
