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
