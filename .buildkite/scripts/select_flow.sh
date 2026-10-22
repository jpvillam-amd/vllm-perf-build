#!/usr/bin/env bash
# Uploads the steps for the flow named by FLOW. Each flow lives in its own
# pipeline file, so neither needs to know the other exists.
set -euo pipefail

case "${FLOW:-}" in
  "")
    pipeline=".buildkite/pipeline.source.yml"
    ;;
  aiter-nightly)
    pipeline=".buildkite/pipeline.aiter-nightly.yml"
    ;;
  *)
    # Fail rather than fall back to a source build: a typo such as
    # FLOW=aiter_nightly would otherwise start an hours-long build.
    echo "^^^ +++"
    echo "Unknown FLOW '${FLOW}'. Leave it unset to build vLLM from source, or set FLOW=aiter-nightly." >&2
    exit 1
    ;;
esac

echo "FLOW='${FLOW:-}' -> uploading ${pipeline}"
buildkite-agent pipeline upload "$pipeline"
