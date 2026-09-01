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

# resolve_latest_nightly_commit <repo>
# Prints the vLLM sha of the most recently pushed `nightly-<sha>` tag on the
# given Docker Hub repo (e.g. vllm/vllm-openai-rocm). Empty on no match.
#
# We resolve the concrete commit rather than trusting the mutable `:nightly`
# tag so the build pins an immutable input and the resulting image tag is
# traceable to an exact vLLM commit.
resolve_latest_nightly_commit() {
  local repo="$1"
  local url="https://hub.docker.com/v2/repositories/${repo}/tags?page_size=100&ordering=last_updated"
  curl -fsSL "$url" | python3 -c '
import sys, json, re
pat = re.compile(r"^nightly-([0-9a-f]{7,40})$")
data = json.load(sys.stdin)
for t in data.get("results", []):
    m = pat.match(t.get("name", ""))
    if m:
        print(m.group(1))
        break
'
}

# Reduce a string to something usable inside a docker tag.
sanitize_tag_component() {
  local s
  s="$(printf '%s' "$1" | tr -c 'a-zA-Z0-9_.-' '-')"
  s="${s##[-._]}"
  printf '%s' "${s:0:80}"
}
