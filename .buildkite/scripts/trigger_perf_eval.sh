#!/usr/bin/env bash
# Optionally hand the freshly-pushed image off to the perf-eval pipeline.
#
# The image tag isn't known until resolve_ref.sh has run, and a trigger step's
# build.env is static YAML, so the step is generated here at runtime and
# uploaded rather than declared in pipeline.yml.
set -euo pipefail

TRIGGER_PERF_EVAL="${TRIGGER_PERF_EVAL:-false}"

if [[ "$TRIGGER_PERF_EVAL" != "true" ]]; then
  echo "TRIGGER_PERF_EVAL is '${TRIGGER_PERF_EVAL}' — not triggering perf-eval."
  echo "Set TRIGGER_PERF_EVAL=true to run perf-eval against this image."
  exit 0
fi

PERF_EVAL_PIPELINE="${PERF_EVAL_PIPELINE:-perf-eval}"
PERF_EVAL_WORKLOADS="${PERF_EVAL_WORKLOADS:-}"
# "true" -> one downstream build per workload; "false" -> a single build that
# receives the whole list.
PERF_EVAL_FANOUT="${PERF_EVAL_FANOUT:-false}"
# "true" -> fire and forget; "false" -> this build waits on perf-eval and
# inherits its pass/fail.
PERF_EVAL_ASYNC="${PERF_EVAL_ASYNC:-true}"
PERF_EVAL_BRANCH="${PERF_EVAL_BRANCH:-main}"
# Names of the env vars perf-eval expects. Override if that pipeline reads
# something other than these.
PERF_EVAL_IMAGE_VAR="${PERF_EVAL_IMAGE_VAR:-VLLM_IMAGE}"
PERF_EVAL_WORKLOAD_VAR="${PERF_EVAL_WORKLOAD_VAR:-WORKLOADS}"

image_ref="$(buildkite-agent meta-data get image-ref)"
commit="$(buildkite-agent meta-data get vllm-commit)"
short_commit="${commit:0:8}"

# Workloads may be comma- or whitespace-separated.
read -r -a workloads <<< "$(printf '%s' "$PERF_EVAL_WORKLOADS" | tr ',' ' ' | tr -s '[:space:]' ' ')"

# These names are interpolated into generated YAML, so keep them to a charset
# that cannot break out of a quoted scalar.
for w in "${workloads[@]:-}"; do
  [[ -z "$w" ]] && continue
  if [[ ! "$w" =~ ^[A-Za-z0-9._/-]+$ ]]; then
    echo "^^^ +++"
    echo "Invalid workload name '${w}'." >&2
    echo "Allowed characters: letters, digits, and . _ / -" >&2
    exit 1
  fi
done

if [[ "$PERF_EVAL_FANOUT" == "true" && "${#workloads[@]}" -eq 0 ]]; then
  echo "^^^ +++"
  echo "PERF_EVAL_FANOUT=true requires PERF_EVAL_WORKLOADS to be set." >&2
  exit 1
fi

steps_file="$(mktemp)"
trap 'rm -f "$steps_file"' EXIT

emit_trigger() {
  # $1 = label suffix, $2 = value for the workload env var ("" to omit)
  local suffix="$1" workload_value="$2"
  cat >>"$steps_file" <<EOF
  - trigger: "${PERF_EVAL_PIPELINE}"
    label: ":chart_with_upwards_trend: perf-eval${suffix}"
    async: ${PERF_EVAL_ASYNC}
    build:
      branch: "${PERF_EVAL_BRANCH}"
      message: "perf-eval for ${image_ref} (vLLM ${short_commit})${suffix}"
      env:
        ${PERF_EVAL_IMAGE_VAR}: "${image_ref}"
        VLLM_COMMIT: "${commit}"
        UPSTREAM_BUILD_URL: "${BUILDKITE_BUILD_URL:-}"
EOF
  if [[ -n "$workload_value" ]]; then
    echo "        ${PERF_EVAL_WORKLOAD_VAR}: \"${workload_value}\"" >>"$steps_file"
  fi
}

echo "steps:" >"$steps_file"

if [[ "$PERF_EVAL_FANOUT" == "true" ]]; then
  echo "--- :chart_with_upwards_trend: Triggering ${#workloads[@]} perf-eval build(s), one per workload"
  for w in "${workloads[@]}"; do
    emit_trigger " ${w}" "$w"
  done
else
  echo "--- :chart_with_upwards_trend: Triggering a single perf-eval build"
  emit_trigger "" "${workloads[*]:-}"
fi

echo "Pipeline : ${PERF_EVAL_PIPELINE}"
echo "Image    : ${image_ref}"
echo "Workloads: ${PERF_EVAL_WORKLOADS:-<none, perf-eval defaults apply>}"
echo "Async    : ${PERF_EVAL_ASYNC}"
echo
echo "Generated steps:"
cat "$steps_file"

buildkite-agent pipeline upload "$steps_file"

{
  echo "Triggered **${PERF_EVAL_PIPELINE}** for \`${image_ref}\`"
  if [[ "${#workloads[@]}" -gt 0 ]]; then
    echo ""
    echo "Workloads: $(printf '`%s` ' "${workloads[@]}")"
  fi
} | buildkite-agent annotate --style info --context "perf-eval"
