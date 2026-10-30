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
        printf 'Name: %s\nDigest: sha256:%064d\n' "$4" 0
        exit 0
      fi
    done
    echo "ERROR: $4: not found" >&2; exit 1 ;;
  "buildx bake")
    env | grep -E '^(STACK_IMAGE|RUNTIME|CONTEXT)=' >"$BAKE_ENV"
    cp "$CONTEXT/.git_archival.txt" "$ARCHIVAL" 2>/dev/null ;;
esac
exit 0
STUB
chmod +x "$WORK/bin/buildkite-agent" "$WORK/bin/docker"
export PATH="$WORK/bin:$PATH"

# Fake vLLM: a tagged commit with the old Dockerfile, then one on the bake layout.
UPSTREAM="$WORK/vllm"
git init -q "$UPSTREAM"
g() { git -C "$UPSTREAM" -c user.name=t -c user.email=t@t -c core.autocrlf=false "$@"; }
mkdir -p "$UPSTREAM/docker"
printf 'ARG BASE_IMAGE=rocm/vllm-dev:base\nFROM ${BASE_IMAGE} AS base\n' >"$UPSTREAM/docker/Dockerfile.rocm"
g add -A && g commit -qm legacy
LEGACY_SHA="$(g rev-parse HEAD)"
g tag v1.0.0
printf 'FROM stack AS dev\nFROM dev AS vllm-openai\n' >"$UPSTREAM/docker/Dockerfile.rocm"
echo 'target "vllm-openai" {}' >"$UPSTREAM/docker/docker-bake-rocm.hcl"
g add -A && g commit -qm bake
BAKE_SHA="$(g rev-parse HEAD)"
g config uploadpack.allowAnySHA1InWant true
g config uploadpack.allowFilter true

source "$HERE/lib.sh"
read -r stack_key runtime_key <<<"$(rocm_content_keys "$UPSTREAM")"
STACK="rocm/vllm-ci:stack-rocm-$stack_key"
RUNTIME="rocm/vllm-ci:runtime-rocm-$runtime_key"
DIGEST="@sha256:$(printf '%064d' 0)"

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

bake_var() { sed -n "s/^$1=//p" "$BAKE_ENV" 2>/dev/null; }
ran() { grep -c "$1" "$CALLS" 2>/dev/null; }

# build <commit> [env...]: resolve <commit> with fresh meta-data, then build it.
build() {
  local commit=$1; shift
  rm -rf "$META_DIR" "$CALLS" "$BAKE_ENV" "$ARCHIVAL"
  mkdir -p "$META_DIR" "$WORK/agent"
  VLLM_REPO="$UPSTREAM" VLLM_COMMIT="$commit" \
    bash "$HERE/resolve_ref.sh" </dev/null >"$WORK/resolve.out" 2>&1 || return 10
  (cd "$WORK/agent" && env -u BASE_IMAGE -u EXTRA_BUILD_ARGS PUSH_IMAGE=false \
    "$@" bash "$HERE/build_and_push.sh") </dev/null >"$WORK/build.out" 2>&1
}

# Build #87: a commit has no ref, and setting it as empty meta-data failed.
# Build #86: Dockerfile.rocm now starts FROM stack, which only the bake file provides.
FAKE_IMAGES="$STACK $RUNTIME" build "$BAKE_SHA"
check "commit build succeeds" "$?" "0"
check "new layout builds through the bake file" "$(ran '^docker buildx bake')" "1"
check "new layout never runs docker build" "$(ran '^docker build ')" "0"
check "stack is vLLM CI's, pinned" "$(bake_var STACK_IMAGE)" "$STACK$DIGEST"
check "runtime is vLLM CI's, pinned" "$(bake_var RUNTIME)" "$RUNTIME$DIGEST"
check "context has the version file the Dockerfile needs" \
  "$(sed -n 's/^describe-name: //p' "$ARCHIVAL" 2>/dev/null)" "v1.0.0-1-g$BAKE_SHA"

FAKE_IMAGES="" build "$BAKE_SHA"
check "missing stack is built in the graph" "$(bake_var STACK_IMAGE)|$(bake_var RUNTIME)" "|"

# A registry outage is not a missing image: fail rather than build hours of stack.
FAKE_REGISTRY_ERROR=1 build "$BAKE_SHA"
check "registry error fails the build" "$([[ $? -ne 0 ]] && echo failed)" "failed"
check "registry error does not start a build" "$(ran 'buildx bake')" "0"

build "$LEGACY_SHA"
check "old layout succeeds" "$?" "0"
check "old layout uses docker build" "$(ran '^docker build ')" "1"
check "old layout never bakes" "$(ran 'buildx bake')" "0"

echo
if ((failures)); then
  echo "FAILED: $failures"
  exit 1
fi
echo "all checks passed"
