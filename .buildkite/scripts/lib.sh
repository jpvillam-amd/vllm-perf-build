#!/usr/bin/env bash
# Shared helpers. Sourced by the build scripts, not executed directly.

# fetch_vllm_source <dest> <repo> <ref> <commit> [depth]
# Leaves <dest> as a detached checkout of exactly <commit>.
fetch_vllm_source() {
  local dest="$1" repo="$2" ref="$3" commit="$4" depth="${5:-1}"

  rm -rf "$dest"
  git init -q "$dest"
  git -C "$dest" remote add origin "$repo"

  # Prefer fetching the sha directly (GitHub allows it) so a ref that moved
  # since resolve_ref.sh ran can't change what we build.
  if ! git -C "$dest" fetch --quiet --depth "$depth" origin "$commit" 2>/dev/null; then
    if [[ -z "$ref" ]]; then
      echo "^^^ +++"
      echo "Could not fetch commit ${commit} from ${repo}." >&2
      return 1
    fi
    echo "Direct sha fetch unavailable, falling back to ${ref}"
    git -C "$dest" fetch --quiet --depth "$depth" origin "$ref" \
      || git -C "$dest" fetch --quiet origin "$ref"
  fi

  if ! git -C "$dest" checkout -q --detach "$commit" 2>/dev/null; then
    # The ref moved past our pinned sha and the shallow fetch missed it.
    echo "Pinned commit not in shallow history, deepening..."
    git -C "$dest" fetch --quiet --unshallow origin "$ref" 2>/dev/null \
      || git -C "$dest" fetch --quiet origin "$ref"
    git -C "$dest" checkout -q --detach "$commit"
  fi

  echo "Checked out $(git -C "$dest" rev-parse HEAD)"
}

# Prints whether to push the image. perf-eval pulls the image it is handed, so
# TRIGGER_PERF_EVAL=true pushes even when PUSH_IMAGE=false.
push_image() {
  if [[ "${TRIGGER_PERF_EVAL:-false}" == "true" ]]; then
    if [[ "${PUSH_IMAGE:-true}" != "true" ]]; then
      echo "TRIGGER_PERF_EVAL=true: pushing despite PUSH_IMAGE=${PUSH_IMAGE}." >&2
    fi
    echo true
  else
    echo "${PUSH_IMAGE:-true}"
  fi
}

# find_dockerfile <checkout> <candidate>... -> prints the first that exists
find_dockerfile() {
  local dest="$1"; shift
  local candidate
  for candidate in "$@"; do
    if [[ -f "${dest}/${candidate}" ]]; then
      printf '%s' "$candidate"
      return 0
    fi
  done
  return 1
}

# uses_stack_context <dockerfile>
# True for vLLM's bake-driven Dockerfile.rocm (vllm#61939 on): it starts from a
# `stack` named context that only docker/docker-bake-rocm.hcl provides, so a
# plain `docker build` tries to pull docker.io/library/stack.
uses_stack_context() {
  grep -qE '^FROM[[:space:]]+stack([[:space:]]|$)' "$1"
}

# rocm_content_keys <checkout> -> prints "<Ks> <Kr>"
# The stack and runtime keys vLLM CI tags its prebuilt images with
# (stack-rocm-<Ks>, runtime-rocm-<Kr>). Must match the "Content keys" section
# of .buildkite/scripts/rocm/build.sh in vLLM; if that recipe changes, the
# lookups miss and the build compiles the stack and runtime itself.
rocm_content_keys() {
  local src="$1" ks kr
  ks="$( { echo "layers: zstd-3, mtimes kept"
           git -C "$src" ls-tree HEAD -- docker/Dockerfile.rocm_base tools/vllm-rocm/therock_wheels.py
         } | sha256sum | cut -c1-16)"
  kr="$( { echo "$ks"
           sed '/^# ==== per-commit stages/q' "${src}/docker/Dockerfile.rocm"
           git -C "$src" ls-tree HEAD -- \
             requirements/common.txt requirements/rocm.txt requirements/test/rocm.txt \
             rust-toolchain.toml tests/vllm_test_utils tools/install_torchcodec_rocm.sh
         } | sha256sum | cut -c1-16)"
  printf '%s %s' "$ks" "$kr"
}

# image_digest <ref> -> prints the sha256 digest of <ref>
# Returns 1 if the tag does not exist, 2 on any other registry error (after
# retries), so a flaky registry is not mistaken for a missing image.
image_digest() {
  local out rc d try
  for try in 1 2 3; do
    rc=0
    out="$(docker buildx imagetools inspect "$1" 2>&1)" || rc=$?
    d="$(awk '$1 == "Digest:" { print $2; exit }' <<<"$out")"
    if ((rc == 0)) && [[ "$d" =~ ^sha256:[0-9a-f]{64}$ ]]; then
      echo "$d"
      return 0
    fi
    if ((rc != 0)) && grep -qiE 'manifest unknown|no such manifest|name unknown|not found|does not exist' <<<"$out"; then
      return 1
    fi
    ((try == 3)) || sleep 5
  done
  echo "registry error for $1 (exit ${rc}): ${out}" >&2
  return 2
}

# find_pinned_image <ref>... -> prints the first <ref> that exists, as ref@digest
# Returns 1 if none exist, 2 on a registry error.
find_pinned_image() {
  local ref d rc
  for ref in "$@"; do
    if d="$(image_digest "$ref")"; then
      echo "${ref}@${d}"
      return 0
    else
      rc=$?
      ((rc == 1)) || return "$rc"
    fi
  done
  return 1
}

# export_build_context <checkout> <dest>
# Exports HEAD of <checkout> into <dest> with the .git_archival.txt that vLLM's
# version stage reads in place of .git, as vLLM's build.sh does. The stage
# fails without a reachable v* tag, which a shallow checkout does not have.
export_build_context() {
  local src="$1" dest="$2" head
  head="$(git -C "$src" rev-parse HEAD)"
  git -C "$src" fetch -q --force --tags --filter=tree:0 origin
  git -C "$src" describe --tags --match 'v[0-9]*' >/dev/null 2>&1 \
    || git -C "$src" fetch -q --unshallow --filter=tree:0 origin "$head"

  rm -rf "$dest"
  mkdir -p "$dest"
  # BuildKit keys COPY on file modes; umask 022 gives every agent git's modes.
  (umask 022 && git -C "$src" archive HEAD | tar -x --no-same-permissions -C "$dest" -f -)
  printf 'node: %s\nnode-date: %s\ndescribe-name: %s\n' "$head" \
    "$(git -C "$src" log -1 --format=%cI)" \
    "$(git -C "$src" describe --tags --long --abbrev=40 --match 'v[0-9]*')" \
    > "${dest}/.git_archival.txt"
}

# docker_hub_login <user> <secret-name>
# Prefers a DOCKERHUB_TOKEN already in the environment (agent hook) and falls
# back to the Buildkite secrets backend.
docker_hub_login() {
  local user="$1" secret_name="$2" token
  if [[ -n "${DOCKERHUB_TOKEN:-}" ]]; then
    token="$DOCKERHUB_TOKEN"
  else
    token="$(buildkite-agent secret get "$secret_name")"
  fi
  printf '%s' "$token" | docker login --username "$user" --password-stdin
}

# Reduce a string to something usable inside a docker tag.
sanitize_tag_component() {
  local s
  s="$(printf '%s' "$1" | tr -c 'a-zA-Z0-9_.-' '-')"
  s="${s##[-._]}"
  printf '%s' "${s:0:80}"
}
