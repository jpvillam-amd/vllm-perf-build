#!/usr/bin/env bash
# Checks resolve_ref.sh and build_and_push.sh without a Buildkite agent or a
# docker daemon: stubs buildkite-agent and docker, builds against a local fake
# vLLM repo, and asserts on the build command the script runs. Run it directly:
# .buildkite/scripts/test_build_and_push.sh
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

export META_DIR="$WORK/meta" CALLS="$WORK/calls" BAKE_ENV="$WORK/bake.env"
export ARCHIVAL="$WORK/archival.txt"

# Stub agent: meta-data lives in files, and like the real agent it refuses to
# set an empty value.
mkdir -p "$WORK/bin"
cat >"$WORK/bin/buildkite-agent" <<'STUB'
#!/usr/bin/env bash
case "$1 $2" in
  "meta-data set")
    if [[ -z "${4//[[:space:]]/}" ]]; then
      echo "buildkite-agent: fatal: value cannot be empty, or composed of only whitespace characters" >&2
      exit 1
    fi
    printf '%s' "$4" >"$META_DIR/$3" ;;
  "meta-data get")
    if [[ -f "$META_DIR/$3" ]]; then cat "$META_DIR/$3"
    elif [[ "${4:-}" == "--default" ]]; then printf '%s' "${5:-}"
    else echo "buildkite-agent: fatal: no meta-data for $3" >&2; exit 1; fi ;;
  *) cat >/dev/null ;;
esac
STUB

# Stub docker: images listed in FAKE_IMAGES exist, FAKE_REGISTRY_ERROR makes
# every lookup fail, and the build commands are recorded.
cat >"$WORK/bin/docker" <<'STUB'
#!/usr/bin/env bash
echo "docker $*" >>"$CALLS"
case "$1 $2" in
  "buildx imagetools")
    [[ -n "${FAKE_REGISTRY_ERROR:-}" ]] && { echo "dial tcp: i/o timeout" >&2; exit 1; }
    for img in ${FAKE_IMAGES:-}; do
      if [[ "$img" == "$4" ]]; then
        printf 'Name: %s\nMediaType: application/vnd.oci.image.index.v1+json\nDigest: sha256:%s\n' \
          "$4" "$(printf '%s' "$4" | sha256sum | cut -c1-64)"
        exit 0
      fi
    done
    echo "ERROR: $4: not found" >&2; exit 1 ;;
  "buildx bake")
    env | grep -E '^(STACK_IMAGE|RUNTIME|TEST_DEPS|CONTEXT|TAG|PUSH|CACHE|CACHE_TO|CI_ARCH)=' | sort >"$BAKE_ENV"
    ctx="$(sed -n 's/^CONTEXT=//p' "$BAKE_ENV")"
    cp "$ctx/.git_archival.txt" "$ARCHIVAL" 2>/dev/null ;;
esac
exit 0
STUB
chmod +x "$WORK/bin/buildkite-agent" "$WORK/bin/docker"
export PATH="$WORK/bin:$PATH"

# Fake vLLM: an older commit with the pre-bake Dockerfile, then a tagged
# release, then a commit on the bake layout.
UPSTREAM="$WORK/vllm"
git init -q "$UPSTREAM"
g() { git -C "$UPSTREAM" -c user.name=t -c user.email=t@t -c core.autocrlf=false "$@"; }
mkdir -p "$UPSTREAM/docker" "$UPSTREAM/requirements/test" "$UPSTREAM/tools/vllm-rocm"
printf 'ARG BASE_IMAGE=rocm/vllm-dev:base\nFROM ${BASE_IMAGE} AS base\n' >"$UPSTREAM/docker/Dockerfile.rocm"
echo "FROM ubuntu AS final" >"$UPSTREAM/docker/Dockerfile.rocm_base"
echo "torch" >"$UPSTREAM/requirements/rocm.txt"
g add -A && g commit -qm legacy
LEGACY_SHA="$(g rev-parse HEAD)"
g tag v1.0.0
cat >"$UPSTREAM/docker/Dockerfile.rocm" <<'EOF'
# syntax=docker/dockerfile:1.27
FROM stack AS dev
RUN true
FROM dev AS runtime
# ==== per-commit stages: nothing below is part of the runtime key ====
FROM runtime AS vllm-openai
EOF
echo 'target "vllm-openai" {}' >"$UPSTREAM/docker/docker-bake-rocm.hcl"
g add -A && g commit -qm bake
BAKE_SHA="$(g rev-parse HEAD)"
DEFAULT_BRANCH="$(g symbolic-ref --short HEAD)"
g config uploadpack.allowAnySHA1InWant true
g config uploadpack.allowFilter true

source "$HERE/lib.sh"
read -r KS KR <<<"$(rocm_content_keys "$UPSTREAM")"
STACK="rocm/vllm-ci:stack-rocm-$KS"
RUNTIME_IMG="rocm/vllm-ci:runtime-rocm-$KR"

failures=0
check() {
  local name=$1 got=$2 want=$3
  if [[ "$got" == "$want" ]]; then
    echo "ok   $name"
  else
    failures=$((failures + 1))
    echo "FAIL $name"
    echo "       got:  $got"
    echo "       want: $want"
  fi
}

pinned() { printf '%s@sha256:%s' "$1" "$(printf '%s' "$1" | sha256sum | cut -c1-64)"; }
bake_var() { sed -n "s/^$1=//p" "$BAKE_ENV" 2>/dev/null; }
calls() { cat "$CALLS" 2>/dev/null; }

# resolve <env...>: fresh meta-data, then resolve_ref.sh with the given selector.
resolve() {
  rm -rf "$META_DIR" "$CALLS" "$BAKE_ENV" "$ARCHIVAL"
  mkdir -p "$META_DIR"
  env -u VLLM_PR -u VLLM_BRANCH -u VLLM_COMMIT VLLM_REPO="$UPSTREAM" "$@" \
    bash "$HERE/resolve_ref.sh" </dev/null >"$WORK/resolve.out" 2>&1
}

# build <env...>: build_and_push.sh in a scratch agent checkout.
build() {
  mkdir -p "$WORK/agent"
  (cd "$WORK/agent" && env -u BASE_IMAGE -u EXTRA_BUILD_ARGS PUSH_IMAGE=false \
    TRIGGER_PERF_EVAL=false "$@" bash "$HERE/build_and_push.sh") </dev/null >"$WORK/build.out" 2>&1
}

# --- resolve_ref.sh ---------------------------------------------------------

# A direct commit has no ref; setting it as empty meta-data was build #87's failure.
resolve VLLM_COMMIT="$BAKE_SHA"
check "commit build resolves" "$?" "0"
check "commit build leaves vllm-ref unset" "$([[ -e $META_DIR/vllm-ref ]] && echo set || echo unset)" "unset"
check "commit build records the commit" "$(cat "$META_DIR/vllm-commit")" "$BAKE_SHA"

resolve VLLM_BRANCH="$DEFAULT_BRANCH"
check "branch build records its ref" "$(cat "$META_DIR/vllm-ref" 2>/dev/null)" \
  "refs/heads/$DEFAULT_BRANCH"

# --- build_and_push.sh, bake layout -------------------------------------------

resolve VLLM_COMMIT="$BAKE_SHA"
FAKE_IMAGES="$STACK $RUNTIME_IMG" build
check "commit build (no vllm-ref) builds" "$?" "0"
check "bake layout uses the bake file" "$(grep -c 'docker buildx bake --file .*docker-bake-rocm.hcl' <<<"$(calls)")" "1"
check "bake layout never runs plain docker build" "$(grep -c '^docker build ' <<<"$(calls)")" "0"
check "stack is vLLM CI's, pinned" "$(bake_var STACK_IMAGE)" "$(pinned "$STACK")"
check "runtime is vLLM CI's, pinned" "$(bake_var RUNTIME)" "$(pinned "$RUNTIME_IMG")"
check "image is tagged with the resolved ref" "$(bake_var TAG)" "$(cat "$META_DIR/image-ref")"
check "bake does not push or touch vLLM's cache" "$(bake_var PUSH)|$(bake_var CACHE)|$(bake_var CACHE_TO)" "false||"
check "arch reaches the compile" \
  "$(grep -c -- '--set vllm-openai.args.ARCH=gfx942;gfx950' <<<"$(calls)")" "1"
check "revision label is set" \
  "$(grep -c -- "--set vllm-openai.labels.org.opencontainers.image.revision=$BAKE_SHA" <<<"$(calls)")" "1"
check "context carries the version for the version stage" \
  "$(sed -n 's/^describe-name: //p' "$ARCHIVAL" 2>/dev/null)" "v1.0.0-1-g$BAKE_SHA"
check "context is an export, not the checkout" \
  "$(bake_var CONTEXT | grep -c '/.vllm-ctx$')" "1"

resolve VLLM_COMMIT="$BAKE_SHA"
FAKE_IMAGES="$STACK" build
check "missing runtime is built on the stack" "$(bake_var STACK_IMAGE)|$(bake_var RUNTIME)" "$(pinned "$STACK")|"

resolve VLLM_COMMIT="$BAKE_SHA"
FAKE_IMAGES="" build
check "missing stack is built in the graph" "$(bake_var STACK_IMAGE)|$(bake_var RUNTIME)" "|"

resolve VLLM_COMMIT="$BAKE_SHA"
FAKE_IMAGES="$STACK $RUNTIME_IMG" build EXTRA_BUILD_ARGS="NIC_BACKEND=none"
check "extra args rebuild the runtime" "$(bake_var RUNTIME)" ""
check "extra args are passed as bake args" \
  "$(grep -c -- '--set vllm-openai.args.NIC_BACKEND=none' <<<"$(calls)")" "1"

resolve VLLM_COMMIT="$BAKE_SHA"
FAKE_IMAGES="$STACK $RUNTIME_IMG" build BASE_IMAGE="me/custom-stack:1"
check "BASE_IMAGE is the stack" "$(bake_var STACK_IMAGE)|$(bake_var RUNTIME)" "me/custom-stack:1|"
check "BASE_IMAGE skips the lookups" "$(grep -c 'imagetools' <<<"$(calls)")" "0"

resolve VLLM_COMMIT="$BAKE_SHA"
echo "me/aiter-stack:2" >"$META_DIR/base-image"
FAKE_IMAGES="$STACK $RUNTIME_IMG" build
check "BUILD_BASE's image is the stack" "$(bake_var STACK_IMAGE)" "me/aiter-stack:2"

# A PR whose stack changed only has it under vLLM CI's pr<N>- tags.
resolve VLLM_COMMIT="$BAKE_SHA"
FAKE_IMAGES="rocm/vllm-dev:pr42-stack-rocm-$KS rocm/vllm-dev:pr42-runtime-rocm-$KR" build VLLM_PR=42
check "PR stack is found under pr<N>-" "$(bake_var STACK_IMAGE)" "$(pinned "rocm/vllm-dev:pr42-stack-rocm-$KS")"
check "PR runtime is found under pr<N>-" "$(bake_var RUNTIME)" "$(pinned "rocm/vllm-dev:pr42-runtime-rocm-$KR")"

# A registry outage is not a missing image: fail rather than build hours of stack.
resolve VLLM_COMMIT="$BAKE_SHA"
FAKE_REGISTRY_ERROR=1 build
rc=$?
check "registry error fails the build" "$([[ $rc -ne 0 ]] && echo failed || echo passed)" "failed"
check "registry error does not start a build" "$(grep -c 'buildx bake' <<<"$(calls)")" "0"

# --- build_and_push.sh, pre-bake layout --------------------------------------

resolve VLLM_COMMIT="$LEGACY_SHA"
build
check "legacy commit builds" "$?" "0"
check "legacy layout uses docker build" "$(grep -c '^docker build ' <<<"$(calls)")" "1"
check "legacy layout keeps the default base" \
  "$(grep -c -- '--build-arg BASE_IMAGE=rocm/vllm-dev:base ' <<<"$(calls)")" "1"
check "legacy layout never bakes" "$(grep -c 'buildx bake' <<<"$(calls)")" "0"

resolve VLLM_COMMIT="$LEGACY_SHA"
build EXTRA_IMAGE_TAGS="extra-a"
check "extra tags are applied" "$(grep -c "^docker tag .* rocm/vllm-dev:extra-a$" <<<"$(calls)")" "1"

echo
if ((failures)); then
  echo "FAILED: $failures"
  exit 1
fi
echo "all checks passed"
