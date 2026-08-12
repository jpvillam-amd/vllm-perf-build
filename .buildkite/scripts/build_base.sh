#!/usr/bin/env bash
# Optionally build docker/Dockerfile.rocm_base so AITER (and the other pinned
# dependencies) can be swapped, then hand the result to the main build.
#
# AITER is cloned and compiled inside the *base* image, not Dockerfile.rocm, so
# changing it means rebuilding the base. Skipped entirely unless BUILD_BASE=true.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

BUILD_BASE="${BUILD_BASE:-false}"

if [[ "$BUILD_BASE" != "true" ]]; then
  echo "BUILD_BASE is '${BUILD_BASE}' — the main build will use the prebuilt"
  echo "${BASE_IMAGE:-rocm/vllm-dev:base}. Set BUILD_BASE=true to build a base"
  echo "image with a specific AITER."
  exit 0
fi

IMAGE_REPO="${IMAGE_REPO:-rocm/vllm-dev}"
PYTORCH_ROCM_ARCH="${PYTORCH_ROCM_ARCH:-gfx942;gfx950}"
DOCKERHUB_USER="${DOCKERHUB_USER:-}"
DOCKERHUB_TOKEN_SECRET="${DOCKERHUB_TOKEN_SECRET:-dockerhub_token}"
CLONE_DEPTH="${CLONE_DEPTH:-1}"
PUSH_IMAGE="${PUSH_IMAGE:-true}"
# Rebuild even when the computed tag already exists in the registry.
BASE_FORCE_REBUILD="${BASE_FORCE_REBUILD:-false}"
# Dependency pins. Empty means "leave the Dockerfile's own default".
AITER_BRANCH="${AITER_BRANCH:-}"
AITER_REPO="${AITER_REPO:-}"
FA_BRANCH="${FA_BRANCH:-}"
TRITON_BRANCH="${TRITON_BRANCH:-}"
PYTORCH_BRANCH="${PYTORCH_BRANCH:-}"
MORI_BRANCH="${MORI_BRANCH:-}"
# Space-separated extras passed straight through to the base build.
EXTRA_BASE_BUILD_ARGS="${EXTRA_BASE_BUILD_ARGS:-}"

if [[ "$PUSH_IMAGE" == "true" && -z "$DOCKERHUB_USER" ]]; then
  echo "^^^ +++"
  echo "DOCKERHUB_USER is not set but PUSH_IMAGE=true." >&2
  exit 1
fi

vllm_repo="$(buildkite-agent meta-data get vllm-repo)"
vllm_ref="$(buildkite-agent meta-data get vllm-ref)"
commit="$(buildkite-agent meta-data get vllm-commit)"
short_commit="${commit:0:8}"

# The base contents are determined by Dockerfile.rocm_base at this vLLM commit
# plus whatever pins we override, so both go in the tag. Same inputs -> same
# tag -> the existing image is reused instead of rebuilt.
if [[ -n "${BASE_IMAGE_TAG:-}" ]]; then
  base_tag="$(sanitize_tag_component "$BASE_IMAGE_TAG")"
else
  aiter_part="$(sanitize_tag_component "${AITER_BRANCH:-default}")"
  base_tag="base-${short_commit}-aiter-${aiter_part}"
fi
base_image="${IMAGE_REPO}:${base_tag}"

echo "--- :package: Base image: ${base_image}"
echo "vLLM commit  : ${commit}"
echo "AITER branch : ${AITER_BRANCH:-<Dockerfile default>}"
echo "AITER repo   : ${AITER_REPO:-<Dockerfile default>}"
echo "GPU archs    : ${PYTORCH_ROCM_ARCH}"

if [[ "$PUSH_IMAGE" == "true" ]]; then
  docker_hub_login "$DOCKERHUB_USER" "$DOCKERHUB_TOKEN_SECRET"
fi

# Reuse an identical base rather than spending hours rebuilding it.
if [[ "$BASE_FORCE_REBUILD" != "true" ]] && docker manifest inspect "$base_image" >/dev/null 2>&1; then
  echo "--- :recycle: ${base_image} already exists, reusing"
  echo "Set BASE_FORCE_REBUILD=true to rebuild it anyway."
  buildkite-agent meta-data set "base-image" "$base_image"
  buildkite-agent annotate --style info --context "base-image" \
    "Reused existing base image \`${base_image}\`"
  exit 0
fi

src_dir="${PWD}/.vllm-base-src"
trap 'rm -rf "$src_dir"' EXIT

echo "--- :git: Fetching vLLM @ ${commit}"
fetch_vllm_source "$src_dir" "$vllm_repo" "$vllm_ref" "$commit" "$CLONE_DEPTH"

if ! dockerfile="$(find_dockerfile "$src_dir" "docker/Dockerfile.rocm_base" "Dockerfile.rocm_base")"; then
  echo "^^^ +++"
  echo "No ROCm base Dockerfile at this commit (looked for docker/Dockerfile.rocm_base and Dockerfile.rocm_base)." >&2
  exit 1
fi
echo "Using ${dockerfile}"

echo "--- :hammer: Building base image (expect this to take hours)"
df -h "$PWD" || true

build_cmd=(
  docker build
  --file "${src_dir}/${dockerfile}"
  --tag "$base_image"
  --build-arg "PYTORCH_ROCM_ARCH=${PYTORCH_ROCM_ARCH}"
  --label "org.opencontainers.image.revision=${commit}"
  --label "buildkite.build.url=${BUILDKITE_BUILD_URL:-}"
)

# Only pass pins that were actually set, so the Dockerfile's own defaults
# survive untouched otherwise.
for pin in AITER_BRANCH AITER_REPO FA_BRANCH TRITON_BRANCH PYTORCH_BRANCH MORI_BRANCH; do
  value="${!pin}"
  [[ -n "$value" ]] && build_cmd+=(--build-arg "${pin}=${value}")
done

for extra in $EXTRA_BASE_BUILD_ARGS; do
  build_cmd+=(--build-arg "$extra")
done

build_cmd+=("$src_dir")
"${build_cmd[@]}"

docker image inspect "$base_image" --format 'size={{.Size}} created={{.Created}}'

if [[ "$PUSH_IMAGE" == "true" ]]; then
  echo "--- :rocket: Pushing ${base_image}"
  docker push "$base_image"
fi

# The main build reads this and uses it instead of the default BASE_IMAGE.
buildkite-agent meta-data set "base-image" "$base_image"

{
  echo "Built base image \`${base_image}\`"
  echo ""
  echo "- AITER: \`${AITER_BRANCH:-Dockerfile default}\`"
  echo "- vLLM commit: \`${short_commit}\`"
} | buildkite-agent annotate --style info --context "base-image"
