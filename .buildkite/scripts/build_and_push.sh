#!/usr/bin/env bash
# Check out the resolved vLLM commit and build docker/Dockerfile.rocm from it,
# then push the result to Docker Hub.
set -euo pipefail

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

src_dir="${PWD}/.vllm-src"
rm -rf "$src_dir"
trap 'rm -rf "$src_dir"' EXIT

echo "--- :git: Fetching vLLM @ ${commit}"
git init -q "$src_dir"
git -C "$src_dir" remote add origin "$vllm_repo"

# Prefer fetching the sha directly (GitHub allows it) so a ref that moved since
# resolve_ref.sh ran can't change what we build. Fall back progressively.
if ! git -C "$src_dir" fetch --quiet --depth "$CLONE_DEPTH" origin "$commit" 2>/dev/null; then
  if [[ -z "$vllm_ref" ]]; then
    echo "^^^ +++"
    echo "Could not fetch commit ${commit} from ${vllm_repo}." >&2
    exit 1
  fi
  echo "Direct sha fetch unavailable, falling back to ${vllm_ref}"
  git -C "$src_dir" fetch --quiet --depth "$CLONE_DEPTH" origin "$vllm_ref" \
    || git -C "$src_dir" fetch --quiet origin "$vllm_ref"
fi

if ! git -C "$src_dir" checkout -q --detach "$commit" 2>/dev/null; then
  # The ref moved past our pinned sha and the shallow fetch didn't include it.
  echo "Pinned commit not in shallow history, deepening..."
  git -C "$src_dir" fetch --quiet --unshallow origin "$vllm_ref" 2>/dev/null \
    || git -C "$src_dir" fetch --quiet origin "$vllm_ref"
  git -C "$src_dir" checkout -q --detach "$commit"
fi

echo "Checked out $(git -C "$src_dir" rev-parse HEAD)"

if [[ -f "${src_dir}/docker/Dockerfile.rocm" ]]; then
  dockerfile="docker/Dockerfile.rocm"
elif [[ -f "${src_dir}/Dockerfile.rocm" ]]; then
  # Pre-2025 layout, before the Dockerfiles moved under docker/.
  dockerfile="Dockerfile.rocm"
else
  echo "^^^ +++"
  echo "No ROCm Dockerfile found at this commit (looked for docker/Dockerfile.rocm and Dockerfile.rocm)." >&2
  exit 1
fi
echo "Using ${dockerfile}"

if [[ "$PUSH_IMAGE" == "true" ]]; then
  echo "--- :docker: Logging in to Docker Hub as ${DOCKERHUB_USER}"
  if [[ -n "${DOCKERHUB_TOKEN:-}" ]]; then
    token="$DOCKERHUB_TOKEN"
  else
    token="$(buildkite-agent secret get "$DOCKERHUB_TOKEN_SECRET")"
  fi
  printf '%s' "$token" | docker login --username "$DOCKERHUB_USER" --password-stdin
  unset token
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
