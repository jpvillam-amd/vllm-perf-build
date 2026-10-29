#!/usr/bin/env bash
# Check out the resolved vLLM commit and build docker/Dockerfile.rocm from it,
# then push the result to Docker Hub.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

IMAGE_REPO="${IMAGE_REPO:-rocm/vllm-dev}"
# Empty means the default for the vLLM commit's Dockerfile layout: vLLM CI's
# prebuilt stack for that commit, or rocm/vllm-dev:base for older commits.
BASE_IMAGE="${BASE_IMAGE:-}"
DOCKER_TARGET="${DOCKER_TARGET:-vllm-openai}"
PYTORCH_ROCM_ARCH="${PYTORCH_ROCM_ARCH:-gfx942;gfx950}"
PUSH_IMAGE="$(push_image)"
DOCKERHUB_USER="${DOCKERHUB_USER:-}"
DOCKERHUB_TOKEN_SECRET="${DOCKERHUB_TOKEN_SECRET:-dockerhub_token}"
MAX_JOBS="${MAX_JOBS:-$(nproc)}"
CLONE_DEPTH="${CLONE_DEPTH:-1}"
# Space-separated extra args, e.g. EXTRA_BUILD_ARGS="NIC_BACKEND=none USE_SCCACHE=1"
EXTRA_BUILD_ARGS="${EXTRA_BUILD_ARGS:-}"
# Space-separated additional tags to publish alongside the primary one.
EXTRA_IMAGE_TAGS="${EXTRA_IMAGE_TAGS:-}"
# Where vLLM CI publishes its content-keyed stack and runtime images: trusted
# builds to ROCM_CI_REPO, PR builds to ROCM_CI_PR_REPO under pr<N>- tags.
ROCM_CI_REPO="${ROCM_CI_REPO:-rocm/vllm-ci}"
ROCM_CI_PR_REPO="${ROCM_CI_PR_REPO:-rocm/vllm-dev}"

if [[ "$PUSH_IMAGE" == "true" && -z "$DOCKERHUB_USER" ]]; then
  echo "^^^ +++"
  echo "DOCKERHUB_USER is not set but PUSH_IMAGE=true." >&2
  exit 1
fi

meta() { buildkite-agent meta-data get "$1"; }

vllm_repo="$(meta vllm-repo)"
# Unset for a direct commit build.
vllm_ref="$(buildkite-agent meta-data get vllm-ref --default "")"
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
ctx_dir="${PWD}/.vllm-ctx"
trap 'rm -rf "$src_dir" "$ctx_dir"' EXIT

echo "--- :git: Fetching vLLM @ ${commit}"
fetch_vllm_source "$src_dir" "$vllm_repo" "$vllm_ref" "$commit" "$CLONE_DEPTH"

if ! dockerfile="$(find_dockerfile "$src_dir" "docker/Dockerfile.rocm" "Dockerfile.rocm")"; then
  echo "^^^ +++"
  echo "No ROCm Dockerfile found at this commit (looked for docker/Dockerfile.rocm and Dockerfile.rocm)." >&2
  exit 1
fi
echo "Using ${dockerfile}"

# Before the image lookups below too, so they are not anonymously rate-limited.
if [[ "$PUSH_IMAGE" == "true" ]]; then
  echo "--- :docker: Logging in to Docker Hub as ${DOCKERHUB_USER}"
  docker_hub_login "$DOCKERHUB_USER" "$DOCKERHUB_TOKEN_SECRET"
fi

labels=(
  "org.opencontainers.image.source=${vllm_repo%.git}"
  "org.opencontainers.image.revision=${commit}"
  "buildkite.build.url=${BUILDKITE_BUILD_URL:-}"
)

if uses_stack_context "${src_dir}/${dockerfile}"; then
  # Build through vLLM's bake file, as vLLM CI does.
  bake_file="${src_dir}/docker/docker-bake-rocm.hcl"
  if [[ ! -f "$bake_file" ]]; then
    echo "^^^ +++"
    echo "${dockerfile} needs the 'stack' named context, but docker/docker-bake-rocm.hcl is missing." >&2
    exit 1
  fi

  stack_image=""
  runtime_image=""
  if [[ -n "$BASE_IMAGE" ]]; then
    # A custom stack: the runtime has to be built on top of it.
    stack_image="$BASE_IMAGE"
  else
    read -r ks kr <<<"$(rocm_content_keys "$src_dir")"
    echo "vLLM CI content keys: Ks=${ks} Kr=${kr}"
    pr_prefix="${VLLM_PR:+pr${VLLM_PR}-}"

    stack_refs=("${ROCM_CI_REPO}:stack-rocm-${ks}")
    [[ -n "$pr_prefix" ]] && stack_refs+=("${ROCM_CI_PR_REPO}:${pr_prefix}stack-rocm-${ks}")
    if stack_image="$(find_pinned_image "${stack_refs[@]}")"; then
      runtime_refs=("${ROCM_CI_REPO}:runtime-rocm-${kr}")
      [[ -n "$pr_prefix" ]] && runtime_refs+=("${ROCM_CI_PR_REPO}:${pr_prefix}runtime-rocm-${kr}")
      if [[ -n "$EXTRA_BUILD_ARGS" ]]; then
        # Args such as NIC_BACKEND configure the runtime stage, which a
        # prebuilt runtime would silently ignore.
        echo "EXTRA_BUILD_ARGS is set: building the runtime rather than reusing vLLM CI's."
      elif runtime_image="$(find_pinned_image "${runtime_refs[@]}")"; then
        :
      else
        rc=$?
        ((rc == 1)) || exit 1
        runtime_image=""
        echo "No vLLM CI runtime for Kr=${kr}: building it on the stack (minutes)."
      fi
    else
      rc=$?
      ((rc == 1)) || exit 1
      stack_image=""
      echo "No vLLM CI stack for Ks=${ks} (looked for ${stack_refs[*]})."
      echo "Building the stack from docker/Dockerfile.rocm_base in this build (hours)."
    fi
  fi

  echo "Building ${dockerfile} through docker/docker-bake-rocm.hcl"
  echo "Stack      : ${stack_image:-<built from Dockerfile.rocm_base>}"
  echo "Runtime    : ${runtime_image:-<built from the stack>}"

  echo "--- :package: Preparing the build context"
  export_build_context "$src_dir" "$ctx_dir"
  cat "${ctx_dir}/.git_archival.txt"

  # Every bake variable that would change the image is set explicitly, so a
  # same-named variable in the agent's environment cannot leak in.
  build_cmd=(
    env
    STACK_IMAGE="$stack_image"
    RUNTIME="$runtime_image"
    TEST_DEPS=""
    STACK_WHEELS=""
    CONTEXT="$ctx_dir"
    TAG="$image_ref"
    PUSH=false
    CACHE=""
    CACHE_TO=""
    CI_ARCH="$PYTORCH_ROCM_ARCH"
    AITER_SPEC=""
    AITER_NIGHTLY=""
    SCCACHE_BUCKET_NAME=""
    docker buildx bake
    --file "$bake_file"
    --set "${DOCKER_TARGET}.args.ARCH=${PYTORCH_ROCM_ARCH}"
  )
  for label in "${labels[@]}"; do
    build_cmd+=(--set "${DOCKER_TARGET}.labels.${label}")
  done
  for extra in $EXTRA_BUILD_ARGS; do
    build_cmd+=(--set "${DOCKER_TARGET}.args.${extra}")
  done
  build_cmd+=("$DOCKER_TARGET")
else
  # Legacy path, for vLLM commits from before the bake layout: a single
  # Dockerfile on top of a prebuilt base image.
  BASE_IMAGE="${BASE_IMAGE:-rocm/vllm-dev:base}"
  echo "Base image : ${BASE_IMAGE}"
  echo "max_jobs   : ${MAX_JOBS}"

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
  )
  for label in "${labels[@]}"; do
    build_cmd+=(--label "$label")
  done
  for extra in $EXTRA_BUILD_ARGS; do
    build_cmd+=(--build-arg "$extra")
  done
  build_cmd+=("$src_dir")
fi

echo "--- :hammer: Building ${image_ref}"
echo "Target     : ${DOCKER_TARGET}"
echo "GPU archs  : ${PYTORCH_ROCM_ARCH}"
df -h "$PWD" || true

"${build_cmd[@]}"

all_tags=("$image_ref")
for tag in $EXTRA_IMAGE_TAGS; do
  all_tags+=("${IMAGE_REPO}:${tag}")
  docker tag "$image_ref" "${IMAGE_REPO}:${tag}"
done

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
