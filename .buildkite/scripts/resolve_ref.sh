#!/usr/bin/env bash
# Work out which vLLM commit this build is for, and what to tag the image.
# Everything downstream reads the answers back out of Buildkite meta-data so
# the resolution happens exactly once per build.
set -euo pipefail

VLLM_REPO="${VLLM_REPO:-https://github.com/vllm-project/vllm.git}"
VLLM_PR="${VLLM_PR:-}"
VLLM_BRANCH="${VLLM_BRANCH:-}"
VLLM_COMMIT="${VLLM_COMMIT:-}"
IMAGE_REPO="${IMAGE_REPO:-rocm/vllm-dev}"

# Docker tags allow [a-zA-Z0-9_.-], must start alphanumeric, max 128 chars.
sanitize_tag_component() {
  local s
  s="$(printf '%s' "$1" | tr -c 'a-zA-Z0-9_.-' '-')"
  s="${s##[-._]}"
  printf '%s' "${s:0:80}"
}

selectors=0
[[ -n "$VLLM_PR" ]] && selectors=$((selectors + 1))
[[ -n "$VLLM_BRANCH" ]] && selectors=$((selectors + 1))
[[ -n "$VLLM_COMMIT" ]] && selectors=$((selectors + 1))

if [[ "$selectors" -gt 1 ]]; then
  echo "^^^ +++"
  echo "Set only one of VLLM_PR, VLLM_BRANCH, VLLM_COMMIT (got ${selectors})." >&2
  exit 1
fi

if [[ -n "$VLLM_PR" ]]; then
  if [[ ! "$VLLM_PR" =~ ^[0-9]+$ ]]; then
    echo "^^^ +++"
    echo "VLLM_PR must be a number, got '${VLLM_PR}'." >&2
    exit 1
  fi
  ref_kind="pr"
  git_ref="refs/pull/${VLLM_PR}/head"
  tag_prefix="pr-${VLLM_PR}"
  human_ref="PR #${VLLM_PR}"
elif [[ -n "$VLLM_BRANCH" ]]; then
  ref_kind="branch"
  git_ref="refs/heads/${VLLM_BRANCH}"
  tag_prefix="$(sanitize_tag_component "$VLLM_BRANCH")"
  human_ref="branch ${VLLM_BRANCH}"
elif [[ -n "$VLLM_COMMIT" ]]; then
  ref_kind="commit"
  git_ref=""
  tag_prefix="commit"
  human_ref="commit ${VLLM_COMMIT}"
else
  ref_kind="branch"
  git_ref="refs/heads/main"
  tag_prefix="main"
  human_ref="branch main (default — no VLLM_PR/VLLM_BRANCH/VLLM_COMMIT set)"
fi

echo "--- Resolving ${human_ref} on ${VLLM_REPO}"

if [[ -n "$git_ref" ]]; then
  # ls-remote so we pin an immutable sha before the (long) build starts; a
  # branch moving mid-build would otherwise silently change what we shipped.
  resolved="$(git ls-remote "$VLLM_REPO" "$git_ref" | awk 'NR==1 {print $1}')"
  if [[ -z "$resolved" ]]; then
    echo "^^^ +++"
    echo "No such ref '${git_ref}' in ${VLLM_REPO}." >&2
    if [[ "$ref_kind" == "pr" ]]; then
      echo "Note: PRs from forks still live on the upstream repo as refs/pull/N/head," >&2
      echo "so VLLM_REPO should stay pointed at vllm-project/vllm for those." >&2
    fi
    exit 1
  fi
  commit="$resolved"
else
  if [[ ! "$VLLM_COMMIT" =~ ^[0-9a-fA-F]{7,40}$ ]]; then
    echo "^^^ +++"
    echo "VLLM_COMMIT must be a hex sha, got '${VLLM_COMMIT}'." >&2
    exit 1
  fi
  commit="$(printf '%s' "$VLLM_COMMIT" | tr '[:upper:]' '[:lower:]')"
fi

short_commit="${commit:0:8}"

if [[ -n "${IMAGE_TAG:-}" ]]; then
  image_tag="$(sanitize_tag_component "$IMAGE_TAG")"
else
  image_tag="${tag_prefix}-${short_commit}"
fi
image_ref="${IMAGE_REPO}:${image_tag}"

buildkite-agent meta-data set "vllm-repo" "$VLLM_REPO"
buildkite-agent meta-data set "vllm-ref" "$git_ref"
buildkite-agent meta-data set "vllm-ref-kind" "$ref_kind"
buildkite-agent meta-data set "vllm-commit" "$commit"
buildkite-agent meta-data set "image-tag" "$image_tag"
buildkite-agent meta-data set "image-ref" "$image_ref"

echo "vLLM repo   : ${VLLM_REPO}"
echo "vLLM ref    : ${git_ref:-<none, direct commit>}"
echo "vLLM commit : ${commit}"
echo "Image       : ${image_ref}"

commit_url="${VLLM_REPO%.git}/commit/${commit}"
buildkite-agent annotate --style info --context "vllm-ref" <<EOF
Building **${human_ref}** at [\`${short_commit}\`](${commit_url})
Target image: \`${image_ref}\`
EOF
