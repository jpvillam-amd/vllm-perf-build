#!/usr/bin/env bash
# Build docker/Dockerfile.aiter-overlay on top of the resolved nightly image
# (swapping in AITER built from the resolved commit) and push the result.
#
# All inputs come from meta-data set by resolve_nightly.sh, so this step is a
# pure function of that resolution.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

IMAGE_REPO="${IMAGE_REPO:-rocm/vllm-dev}"
PUSH_IMAGE="${PUSH_IMAGE:-true}"
DOCKERHUB_USER="${DOCKERHUB_USER:-}"
DOCKERHUB_TOKEN_SECRET="${DOCKERHUB_TOKEN_SECRET:-dockerhub_token}"
# Pull the base first so a missing/renamed nightly fails here with a clear
# message rather than mid-build. Set false if the agent already has it cached.
PULL_BASE="${PULL_BASE:-true}"
# Space-separated additional tags to publish alongside the primary one.
EXTRA_IMAGE_TAGS="${EXTRA_IMAGE_TAGS:-}"

if [[ "$PUSH_IMAGE" == "true" && -z "$DOCKERHUB_USER" ]]; then
  echo "^^^ +++"
  echo "DOCKERHUB_USER is not set but PUSH_IMAGE=true." >&2
  exit 1
fi

meta() { buildkite-agent meta-data get "$1"; }

vllm_commit="$(meta vllm-commit)"
base_image="$(meta overlay-base-image)"
aiter_repo="$(meta aiter-repo)"
aiter_commit="$(meta aiter-commit)"
image_ref="$(meta image-ref)"

# Dockerfile lives in this repo, checked out by the agent. It COPYs nothing, so
# the build context is irrelevant — use the directory it sits in.
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
dockerfile="${repo_root}/docker/Dockerfile.aiter-overlay"
context_dir="${repo_root}/docker"

if [[ ! -f "$dockerfile" ]]; then
  echo "^^^ +++"
  echo "Overlay Dockerfile not found at ${dockerfile}." >&2
  exit 1
fi

if [[ "$PUSH_IMAGE" == "true" ]]; then
  echo "--- :docker: Logging in to Docker Hub as ${DOCKERHUB_USER}"
  docker_hub_login "$DOCKERHUB_USER" "$DOCKERHUB_TOKEN_SECRET"
fi

if [[ "$PULL_BASE" == "true" ]]; then
  echo "--- :arrow_down: Pulling base nightly ${base_image}"
  docker pull "$base_image"
fi

echo "--- :hammer: Building ${image_ref}"
echo "Base image  : ${base_image}"
echo "vLLM commit : ${vllm_commit}"
echo "AITER repo  : ${aiter_repo}"
echo "AITER commit: ${aiter_commit}"
df -h "$PWD" || true

build_cmd=(
  docker build
  --file "$dockerfile"
  --tag "$image_ref"
  --build-arg "BASE_IMAGE=${base_image}"
  --build-arg "AITER_REPO=${aiter_repo}"
  --build-arg "AITER_COMMIT=${aiter_commit}"
  --build-arg "VLLM_COMMIT=${vllm_commit}"
  --label "org.opencontainers.image.source=${aiter_repo%.git}"
  --label "org.opencontainers.image.revision=${aiter_commit}"
  --label "vllm.commit=${vllm_commit}"
  --label "buildkite.build.url=${BUILDKITE_BUILD_URL:-}"
)

all_tags=("$image_ref")
for tag in $EXTRA_IMAGE_TAGS; do
  all_tags+=("${IMAGE_REPO}:${tag}")
  build_cmd+=(--tag "${IMAGE_REPO}:${tag}")
done

build_cmd+=("$context_dir")
"${build_cmd[@]}"

echo "--- :mag: Verifying AITER came from ${aiter_commit:0:8}"
docker run --rm --entrypoint cat "$image_ref" /app/versions.txt || true

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
  echo "- vLLM commit: \`${vllm_commit}\`"
  echo "- AITER commit: \`${aiter_commit}\`"
  [[ -n "$digest" ]] && echo "- Digest: \`${digest}\`"
} | buildkite-agent annotate --style success --context "image"
