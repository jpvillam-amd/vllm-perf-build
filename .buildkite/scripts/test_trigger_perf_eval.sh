#!/usr/bin/env bash
# Checks the perf-eval trigger step without a Buildkite agent: stubs
# buildkite-agent, runs trigger_perf_eval.sh, and asserts on the YAML it
# uploads. Run it directly: .buildkite/scripts/test_trigger_perf_eval.sh
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/trigger_perf_eval.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# Stub agent: serves the metadata the script reads and saves whatever it is
# asked to upload, so assertions see the generated YAML rather than the
# script's own progress output.
mkdir -p "$WORK/bin"
export UPLOADED="$WORK/uploaded.yml"
cat >"$WORK/bin/buildkite-agent" <<'STUB'
#!/usr/bin/env bash
case "$1 $2" in
  "meta-data get")
    case "$3" in
      image-ref)   echo "rocm/vllm-dev:pr-52052-73b53742" ;;
      vllm-commit) echo "73b537428f0e4d2a0c6b9f1e5a3d8c7b6e4f2a19" ;;
    esac
    ;;
  "pipeline upload") cp "$3" "$UPLOADED" ;;
  *) cat >/dev/null ;;
esac
STUB
chmod +x "$WORK/bin/buildkite-agent"
export PATH="$WORK/bin:$PATH"

failures=0

run() {
  rm -f "$UPLOADED"
  TRIGGER_PERF_EVAL=true BUILDKITE_BUILD_URL="https://buildkite.test/1" "$@" \
    bash "$SCRIPT" >"$WORK/stdout" 2>&1
}

uploaded() { cat "$UPLOADED" 2>/dev/null; }
output() { cat "$WORK/stdout"; }

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

workload_line() {
  grep -E "^\s+WORKLOADS:" <<<"$1" | sed 's/^[[:space:]]*//' | tr '\n' '|'
}

# A comma-separated list must reach perf-eval unchanged.
run env PERF_EVAL_WORKLOADS="qwen3_5_mi355x,kimi_k2_6_mi355x"
check "comma-separated list stays comma-separated" \
  "$(workload_line "$(uploaded)")" 'WORKLOADS: "qwen3_5_mi355x,kimi_k2_6_mi355x"|'

# The web trigger sends spaces; perf-eval only splits on commas and newlines,
# so this is the case that silently generated no workload steps.
run env PERF_EVAL_WORKLOADS="qwen3_5_mi355x kimi_k2_6_mi355x glm_5_2_fp8_mi355x"
check "space-separated list is rejoined with commas" \
  "$(workload_line "$(uploaded)")" \
  'WORKLOADS: "qwen3_5_mi355x,kimi_k2_6_mi355x,glm_5_2_fp8_mi355x"|'

# Mixed separators and stray whitespace collapse the same way.
run env PERF_EVAL_WORKLOADS="  a, b   c,,d "
check "mixed separators collapse" "$(workload_line "$(uploaded)")" 'WORKLOADS: "a,b,c,d"|'

run env PERF_EVAL_WORKLOADS="qwen3_5_mi355x"
check "single workload" "$(workload_line "$(uploaded)")" 'WORKLOADS: "qwen3_5_mi355x"|'

# No workloads: the variable is omitted so perf-eval falls back to its nightly set.
run env PERF_EVAL_WORKLOADS=""
check "empty list omits the variable" "$(workload_line "$(uploaded)")" ""
check "empty list still triggers a build" \
  "$(grep -c 'trigger: "perf-eval"' <<<"$(uploaded)")" "1"

# Fan-out emits one build per workload, each with a single name.
run env PERF_EVAL_WORKLOADS="a,b c" PERF_EVAL_FANOUT=true
check "fanout emits one build per workload" \
  "$(grep -c 'trigger: "perf-eval"' <<<"$(uploaded)")" "3"
check "fanout passes one name per build" \
  "$(workload_line "$(uploaded)")" 'WORKLOADS: "a"|WORKLOADS: "b"|WORKLOADS: "c"|'

# The image and branch still ride along.
run env PERF_EVAL_WORKLOADS="a" PERF_EVAL_BRANCH="micah/migrate-vllm-dashboard-nightly"
check "image is passed through" \
  "$(grep -c 'VLLM_IMAGE: "rocm/vllm-dev:pr-52052-73b53742"' <<<"$(uploaded)")" "1"
check "branch is passed through" \
  "$(grep -c 'branch: "micah/migrate-vllm-dashboard-nightly"' <<<"$(uploaded)")" "1"

# A trigger step forwards only the variables it names, so the run type has to
# be written into the downstream build explicitly.
run_type_line() {
  grep -E "^\s+PERF_EVAL_RUN_TYPE:" <<<"$1" | sed 's/^[[:space:]]*//' | tr '\n' '|'
}

run env PERF_EVAL_WORKLOADS="a" PERF_EVAL_RUN_TYPE="aiter-nightly"
check "run type reaches the downstream build" \
  "$(run_type_line "$(uploaded)")" 'PERF_EVAL_RUN_TYPE: "aiter-nightly"|'

run env PERF_EVAL_WORKLOADS="a"
check "no run type leaves the variable off" "$(run_type_line "$(uploaded)")" ""

# Fan-out labels every build it starts.
run env PERF_EVAL_WORKLOADS="a,b" PERF_EVAL_FANOUT=true PERF_EVAL_RUN_TYPE="nightly-rocm10"
check "fanout labels each build" "$(run_type_line "$(uploaded)")" \
  'PERF_EVAL_RUN_TYPE: "nightly-rocm10"|PERF_EVAL_RUN_TYPE: "nightly-rocm10"|'

# Values that could break out of the generated YAML are still refused.
run env PERF_EVAL_WORKLOADS='ok_name,bad"name'
check "invalid workload name is rejected" "$(grep -c 'Invalid workload name' <<<"$(output)")" "1"
check "invalid workload name uploads nothing" "$(uploaded)" ""

run env PERF_EVAL_WORKLOADS="a" PERF_EVAL_RUN_TYPE='bad" nightly'
check "invalid run type is rejected" "$(grep -c 'Invalid run type' <<<"$(output)")" "1"
check "invalid run type uploads nothing" "$(uploaded)" ""

# The master switch still short-circuits.
TRIGGER_PERF_EVAL=false bash "$SCRIPT" >"$WORK/stdout" 2>&1
check "disabled trigger does nothing" "$(grep -c 'not triggering perf-eval' <<<"$(output)")" "1"

echo
if ((failures)); then
  echo "FAILED: $failures"
  exit 1
fi
echo "all checks passed"
