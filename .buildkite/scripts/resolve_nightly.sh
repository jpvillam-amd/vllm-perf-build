#!/usr/bin/env bash
# Resolve the inputs for an AITER-overlay build and pin them into meta-data.
#
# The overlay is built on top of a published vLLM ROCm nightly:
#   vllm/vllm-openai-rocm:nightly-<vllm-commit>
# and swaps in AITER from the newest published nightly wheel (rocm7.2.3 by
# default) rather than compiling it from source. Both inputs are resolved to
# immutable references up front, so a scheduled job is reproducible and the
# resulting tag is traceable to exactly what went into it.
#
# Inputs (all optional; sensible defaults for a nightly scheduled job):
#   VLLM_COMMIT   pin the vLLM nightly commit; otherwise resolve the newest
#                 nightly-<sha> tag on NIGHTLY_REPO from Docker Hub
#   NIGHTLY_REPO  published nightly repo (default vllm/vllm-openai-rocm)
#   OVERLAY_BASE_IMAGE  override the base image entirely (skips the lookup)
#   AITER_WHEEL_URL   pin an exact wheel URL, skipping the index lookup
#   AITER_WHEEL_INDEX AITER nightly wheel index (default the AMD nightlies page)
#   AITER_ROCM_VARIANT  ROCm build variant to match (default rocm7.2.3)
#   IMAGE_REPO    destination repo (default rocm/vllm-dev)
#   IMAGE_TAG     override the computed tag entirely
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

NIGHTLY_REPO="${NIGHTLY_REPO:-vllm/vllm-openai-rocm}"
VLLM_COMMIT="${VLLM_COMMIT:-}"
OVERLAY_BASE_IMAGE="${OVERLAY_BASE_IMAGE:-}"
AITER_WHEEL_URL="${AITER_WHEEL_URL:-}"
AITER_WHEEL_INDEX="${AITER_WHEEL_INDEX:-https://rocm.frameworks-nightlies.amd.com/whl-multi-arch/amd-aiter/}"
AITER_ROCM_VARIANT="${AITER_ROCM_VARIANT:-rocm7.2.3}"
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

# --- Resolve the AITER nightly wheel -----------------------------------------
if [[ -n "$AITER_WHEEL_URL" ]]; then
  echo "--- Using pinned AITER wheel"
  aiter_wheel_url="$AITER_WHEEL_URL"
else
  echo "--- Resolving newest ${AITER_ROCM_VARIANT} amd-aiter wheel from ${AITER_WHEEL_INDEX}"
  aiter_wheel_url="$(resolve_latest_aiter_wheel "$AITER_WHEEL_INDEX" "$AITER_ROCM_VARIANT")"
  if [[ -z "$aiter_wheel_url" ]]; then
    echo "^^^ +++"
    echo "No ${AITER_ROCM_VARIANT} cp312 amd-aiter wheel found at ${AITER_WHEEL_INDEX}." >&2
    echo "Pass AITER_WHEEL_URL explicitly, or check AITER_ROCM_VARIANT." >&2
    exit 1
  fi
fi

# Decoded filename, e.g. amd_aiter-0.1.23+rocm7.2.3.76cd9af.d20260914-cp312-...
aiter_wheel_file="$(python3 -c 'import sys,urllib.parse as u; print(u.unquote(sys.argv[1].split("/")[-1]))' "$aiter_wheel_url")"
# Version between "amd_aiter-" and "-cp312".
aiter_version="$(printf '%s' "$aiter_wheel_file" | sed -E 's/^amd_aiter-(.+)-cp312-cp312-linux_x86_64\.whl$/\1/')"
# The git short-sha token that follows the +rocmX.Y.Z. local-version prefix.
aiter_short="$(printf '%s' "$aiter_version" | sed -E 's/.*\+rocm[0-9.]+\.([0-9a-fA-F]+).*/\1/')"
aiter_short="${aiter_short:0:8}"

echo "AITER wheel : ${aiter_wheel_file}"

# --- Compute the destination tag ---------------------------------------------
# Encodes both inputs so the image is traceable to the exact vLLM nightly and
# AITER wheel it was built from.
if [[ -n "${IMAGE_TAG:-}" ]]; then
  image_tag="$(sanitize_tag_component "$IMAGE_TAG")"
else
  image_tag="nightly-aiter-${aiter_short}-vllm-${vllm_short}"
fi
image_ref="${IMAGE_REPO}:${image_tag}"

buildkite-agent meta-data set "vllm-commit" "$vllm_commit"
buildkite-agent meta-data set "overlay-base-image" "$base_image"
buildkite-agent meta-data set "aiter-wheel-url" "$aiter_wheel_url"
buildkite-agent meta-data set "aiter-version" "$aiter_version"
buildkite-agent meta-data set "image-tag" "$image_tag"
buildkite-agent meta-data set "image-ref" "$image_ref"

echo "vLLM commit  : ${vllm_commit}"
echo "Base image   : ${base_image}"
echo "AITER version: ${aiter_version}"
echo "AITER wheel  : ${aiter_wheel_url}"
echo "Image        : ${image_ref}"

vllm_commit_url="https://github.com/vllm-project/vllm/commit/${vllm_commit}"
buildkite-agent annotate --style info --context "aiter-overlay" <<EOF
AITER-overlay build

- Base nightly: \`${base_image}\` (vLLM [\`${vllm_short}\`](${vllm_commit_url}))
- AITER wheel: \`${aiter_version}\`
- Target image: \`${image_ref}\`
EOF
