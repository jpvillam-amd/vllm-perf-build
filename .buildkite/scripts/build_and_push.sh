#!/usr/bin/env bash
# Check out the resolved vLLM commit and build docker/Dockerfile.rocm from it,
# then push the result to Docker Hub.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

IMAGE_REPO="${IMAGE_REPO:-rocm/vllm-dev}"
BASE_IMAGE="${BASE_IMAGE:-rocm/vllm-dev:base}"
DOCKER_TARGET="${DOCKER_TARGET:-vllm-openai}"
PYTORCH_ROCM_ARCH="${PYTORCH_ROCM_ARCH:-gfx942;gfx950}"
PUSH_IMAGE="${PUSH_IMAGE:-true}"
DOCKERHUB_USER="${DOCKERHUB_USER:-}"
DOCKERHUB_TOKEN_SECRET="${DOCKERHUB_TOKEN_SECRET:-dockerhub_token}"
MAX_JOBS="${MAX_JOBS:-$(nproc)}"
CLONE_DEPTH="${CLONE_DEPTH:-1}"
# Space-separated extra args, e.g. EXTRA_BUILD_ARGS="NIC_BACKEND=none USE_SCCACHE=1"
EXTRA_BUILD_ARGS="${EXTRA_BUILD_ARGS:-}"
# Space-separated additional tags to publish alongside the primary one.
EXTRA_IMAGE_TAGS="${EXTRA_IMAGE_TAGS:-}"

if [[ "$PUSH_IMAGE" == "true" && -z "$DOCKERHUB_USER" ]]; then
  echo "^^^ +++"
  echo "DOCKERHUB_USER is not set but PUSH_IMAGE=true." >&2
  exit 1
fi

meta() { buildkite-agent meta-data get "$1"; }

vllm_repo="$(meta vllm-repo)"
vllm_ref="$(meta vllm-ref)"
commit="$(meta vllm-commit)"
image_ref="$(meta image-ref)"

# build_base.sh publishes this when BUILD_BASE=true; otherwise fall back to the
# prebuilt base from the env block.
base_image="$(buildkite-agent meta-data get base-image --default "" 2>/dev/null || true)"
if [[ -n "$base_image" ]]; then
  echo "Using base image built by this pipeline: ${base_image}"
  BASE_IMAGE="$base_image"
fi

src_dir="${PWD}/.vllm-src"
trap 'rm -rf "$src_dir"' EXIT

echo "--- :git: Fetching vLLM @ ${commit}"
fetch_vllm_source "$src_dir" "$vllm_repo" "$vllm_ref" "$commit" "$CLONE_DEPTH"

if ! dockerfile="$(find_dockerfile "$src_dir" "docker/Dockerfile.rocm" "Dockerfile.rocm")"; then
  echo "^^^ +++"
  echo "No ROCm Dockerfile found at this commit (looked for docker/Dockerfile.rocm and Dockerfile.rocm)." >&2
  exit 1
fi
echo "Using ${dockerfile}"

if [[ "$PUSH_IMAGE" == "true" ]]; then
  echo "--- :docker: Logging in to Docker Hub as ${DOCKERHUB_USER}"
  docker_hub_login "$DOCKERHUB_USER" "$DOCKERHUB_TOKEN_SECRET"
fi

echo "--- :hammer: Building ${image_ref}"
echo "Base image : ${BASE_IMAGE}"
echo "Target     : ${DOCKER_TARGET}"
echo "GPU archs  : ${PYTORCH_ROCM_ARCH}"
echo "max_jobs   : ${MAX_JOBS}"
df -h "$PWD" || true

build_cmd=(
  docker build
  --file "${src_dir}/${dockerfile}"
  --target "$DOCKER_TARGET"
  --tag "$image_ref"
  --build-arg "REMOTE_VLLM=0"
  --build-arg "BASE_IMAGE=${BASE_IMAGE}"
  --build-arg "ARG_PYTORCH_ROCM_ARCH=${PYTORCH_ROCM_ARCH}"
  --build-arg "max_jobs=${MAX_JOBS}"
  --build-arg "GIT_REPO_CHECK=0"
  --label "org.opencontainers.image.source=${vllm_repo%.git}"
  --label "org.opencontainers.image.revision=${commit}"
  --label "buildkite.build.url=${BUILDKITE_BUILD_URL:-}"
)

for extra in $EXTRA_BUILD_ARGS; do
  build_cmd+=(--build-arg "$extra")
done

all_tags=("$image_ref")
for tag in $EXTRA_IMAGE_TAGS; do
  all_tags+=("${IMAGE_REPO}:${tag}")
  build_cmd+=(--tag "${IMAGE_REPO}:${tag}")
done

build_cmd+=("$src_dir")
"${build_cmd[@]}"

echo "--- :mag: Image summary"
docker image inspect "$image_ref" \
  --format 'size={{.Size}} arch={{.Architecture}} created={{.Created}}'

if [[ "$PUSH_IMAGE" != "true" ]]; then
  echo "--- :no_entry: PUSH_IMAGE is '${PUSH_IMAGE}', not pushing"
  buildkite-agent annotate --style warning --context "image" \
    "Built \`${image_ref}\` locally. Not pushed (\`PUSH_IMAGE=${PUSH_IMAGE}\`)."
  exit 0
fi

echo "--- :rocket: Pushing"
for tag in "${all_tags[@]}"; do
  echo "Pushing ${tag}"
  docker push "$tag"
done

digest="$(docker image inspect "$image_ref" \
  --format '{{if .RepoDigests}}{{index .RepoDigests 0}}{{end}}')"

{
  echo "Pushed **\`${image_ref}\`**"
  echo ""
  echo '```'
  echo "docker pull ${image_ref}"
  echo '```'
  [[ -n "$digest" ]] && echo "Digest: \`${digest}\`"
} | buildkite-agent annotate --style success --context "image"
