#!/usr/bin/env bash
# Resolve the inputs for an AITER-overlay build and pin them into meta-data.
#
# The overlay is built on top of a published vLLM ROCm nightly:
#   vllm/vllm-openai-rocm:nightly-<vllm-commit>
# and swaps in AITER built from a chosen ref (main by default). Both inputs are
# resolved to immutable shas up front, so a scheduled job is reproducible and
# the resulting tag is traceable to exactly what went into it.
#
# Inputs (all optional; sensible defaults for a nightly scheduled job):
#   VLLM_COMMIT   pin the vLLM nightly commit; otherwise resolve the newest
#                 nightly-<sha> tag on NIGHTLY_REPO from Docker Hub
#   NIGHTLY_REPO  published nightly repo (default vllm/vllm-openai-rocm)
#   OVERLAY_BASE_IMAGE  override the base image entirely (skips the lookup)
#   AITER_REPO    AITER git repo (default https://github.com/ROCm/aiter.git)
#   AITER_BRANCH  AITER branch to build (default main)
#   AITER_COMMIT  pin AITER to an exact sha instead of resolving AITER_BRANCH
#   IMAGE_REPO    destination repo (default rocm/vllm-dev)
#   IMAGE_TAG     override the computed tag entirely
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

NIGHTLY_REPO="${NIGHTLY_REPO:-vllm/vllm-openai-rocm}"
VLLM_COMMIT="${VLLM_COMMIT:-}"
OVERLAY_BASE_IMAGE="${OVERLAY_BASE_IMAGE:-}"
AITER_REPO="${AITER_REPO:-https://github.com/ROCm/aiter.git}"
AITER_BRANCH="${AITER_BRANCH:-main}"
AITER_COMMIT="${AITER_COMMIT:-}"
IMAGE_REPO="${IMAGE_REPO:-rocm/vllm-dev}"

# --- Resolve the vLLM nightly commit -----------------------------------------
if [[ -n "$VLLM_COMMIT" ]]; then
  if [[ ! "$VLLM_COMMIT" =~ ^[0-9a-fA-F]{7,40}$ ]]; then
    echo "^^^ +++"
    echo "VLLM_COMMIT must be a hex sha, got '${VLLM_COMMIT}'." >&2
    exit 1
  fi
  vllm_commit="$(printf '%s' "$VLLM_COMMIT" | tr '[:upper:]' '[:lower:]')"
  echo "--- Using pinned vLLM commit ${vllm_commit}"
else
  echo "--- Resolving newest ${NIGHTLY_REPO}:nightly-<sha> from Docker Hub"
  vllm_commit="$(resolve_latest_nightly_commit "$NIGHTLY_REPO")"
  if [[ -z "$vllm_commit" ]]; then
    echo "^^^ +++"
    echo "Could not find a nightly-<sha> tag on ${NIGHTLY_REPO}." >&2
    echo "Pass VLLM_COMMIT explicitly to bypass the Docker Hub lookup." >&2
    exit 1
  fi
  echo "Resolved nightly commit ${vllm_commit}"
fi
vllm_short="${vllm_commit:0:8}"

if [[ -n "$OVERLAY_BASE_IMAGE" ]]; then
  base_image="$OVERLAY_BASE_IMAGE"
else
  base_image="${NIGHTLY_REPO}:nightly-${vllm_commit}"
fi

# --- Resolve the AITER commit ------------------------------------------------
if [[ -n "$AITER_COMMIT" ]]; then
  if [[ ! "$AITER_COMMIT" =~ ^[0-9a-fA-F]{7,40}$ ]]; then
    echo "^^^ +++"
    echo "AITER_COMMIT must be a hex sha, got '${AITER_COMMIT}'." >&2
    exit 1
  fi
  aiter_commit="$(printf '%s' "$AITER_COMMIT" | tr '[:upper:]' '[:lower:]')"
  echo "--- Using pinned AITER commit ${aiter_commit}"
else
  echo "--- Resolving AITER ${AITER_BRANCH} on ${AITER_REPO}"
  aiter_commit="$(git ls-remote "$AITER_REPO" "refs/heads/${AITER_BRANCH}" | awk 'NR==1 {print $1}')"
  if [[ -z "$aiter_commit" ]]; then
    echo "^^^ +++"
    echo "No branch '${AITER_BRANCH}' in ${AITER_REPO}." >&2
    exit 1
  fi
  echo "Resolved AITER ${AITER_BRANCH} to ${aiter_commit}"
fi
aiter_short="${aiter_commit:0:8}"

# --- Compute the destination tag ---------------------------------------------
# Encodes both inputs so the image is traceable to the exact vLLM nightly and
# AITER commit it was built from.
if [[ -n "${IMAGE_TAG:-}" ]]; then
  image_tag="$(sanitize_tag_component "$IMAGE_TAG")"
else
  image_tag="nightly-aiter-${aiter_short}-vllm-${vllm_short}"
fi
image_ref="${IMAGE_REPO}:${image_tag}"

buildkite-agent meta-data set "vllm-commit" "$vllm_commit"
buildkite-agent meta-data set "overlay-base-image" "$base_image"
buildkite-agent meta-data set "aiter-repo" "$AITER_REPO"
buildkite-agent meta-data set "aiter-commit" "$aiter_commit"
buildkite-agent meta-data set "image-tag" "$image_tag"
buildkite-agent meta-data set "image-ref" "$image_ref"

echo "vLLM commit : ${vllm_commit}"
echo "Base image  : ${base_image}"
echo "AITER repo  : ${AITER_REPO}"
echo "AITER commit: ${aiter_commit}"
echo "Image       : ${image_ref}"

vllm_commit_url="https://github.com/vllm-project/vllm/commit/${vllm_commit}"
aiter_commit_url="${AITER_REPO%.git}/commit/${aiter_commit}"
buildkite-agent annotate --style info --context "aiter-overlay" <<EOF
AITER-overlay build

- Base nightly: \`${base_image}\` (vLLM [\`${vllm_short}\`](${vllm_commit_url}))
- AITER: [\`${aiter_short}\`](${aiter_commit_url}) from \`${AITER_BRANCH}\`
- Target image: \`${image_ref}\`
EOF
