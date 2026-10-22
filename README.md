# vllm-perf-build

Buildkite pipeline that builds vLLM ROCm docker images from any vLLM PR, branch, or
commit (or overlays an AITER nightly onto the vLLM nightly) and publishes them to
[`rocm/vllm-dev`](https://hub.docker.com/r/rocm/vllm-dev).

## Flows

`FLOW` on the build picks what runs. `pipeline.yml` only picks the flow; each flow's
steps live in their own file:

| `FLOW` | Steps | Runs |
| --- | --- | --- |
| unset | `pipeline.source.yml` | Build vLLM from source for a PR, branch or commit. Takes hours; much longer with `BUILD_BASE=true`. |
| `aiter-nightly` | `pipeline.aiter-nightly.yml` | Install the newest matching AITER nightly wheel over the latest vLLM ROCm nightly. No compile. See [AITER nightly](#aiter-nightly). |

Any other value fails the first step, so a typo cannot start a source build.

## Building from source

Set **one** of these on the build (none builds `main`):

| Variable | Example | Builds |
| --- | --- | --- |
| `VLLM_PR` | `12345` | `refs/pull/12345/head` on `vllm-project/vllm`, fork PRs included |
| `VLLM_BRANCH` | `my-feature` | that branch |
| `VLLM_COMMIT` | `a1b2c3d...` | that exact commit |

Via the API:

```bash
curl -X POST "https://api.buildkite.com/v2/organizations/<org>/pipelines/vllm-perf-build/builds" \
  -H "Authorization: Bearer $BUILDKITE_TOKEN" \
  -d '{"commit":"HEAD","branch":"main","env":{"VLLM_PR":"12345"}}'
```

The image tag is the ref plus the resolved short sha, so every build is traceable
to an exact vLLM commit:

| Trigger | Tag |
| --- | --- |
| `VLLM_PR=12345` | `rocm/vllm-dev:pr-12345-<short-sha>` |
| `VLLM_BRANCH=my-feature` | `rocm/vllm-dev:my-feature-<short-sha>` |
| `VLLM_COMMIT=a1b2c3d…` | `rocm/vllm-dev:commit-<short-sha>` |

`IMAGE_TAG` replaces the tag; `EXTRA_IMAGE_TAGS` (space-separated) adds additional
tags alongside the primary one.

## Configuration

Defaults live in the scripts: a pipeline-level `env:` block would override
variables set when the build is triggered.

| Variable | Default | Purpose |
| --- | --- | --- |
| `FLOW` | — | See [Flows](#flows). |
| `VLLM_REPO` | `https://github.com/vllm-project/vllm.git` | Source repo. Keep upstream for PRs, including fork PRs. |
| `BASE_IMAGE` | `rocm/vllm-dev:base` | ROCm/PyTorch base, pulled rather than built. |
| `DOCKER_TARGET` | `vllm-openai` | Dockerfile stage: `final` (no serving entrypoint) or `test` (CI test image). |
| `PYTORCH_ROCM_ARCH` | `gfx942;gfx950` | GPU targets. Each is a full HIP compile pass. |
| `MAX_JOBS` | `$(nproc)` | Build parallelism. |
| `IMAGE_REPO` | `rocm/vllm-dev` | Destination repo. |
| `DOCKERHUB_USER` | `jpvillam` | Docker Hub push account. |
| `DOCKERHUB_TOKEN_SECRET` | `dockerhub_token` | Buildkite secret holding the token. |
| `PUSH_IMAGE` | `true` | `false` builds only. Ignored when `TRIGGER_PERF_EVAL=true`. |
| `EXTRA_BUILD_ARGS` | — | Space-separated extra `--build-arg`s, e.g. `NIC_BACKEND=none USE_SCCACHE=1`. |
| `CLONE_DEPTH` | `1` | Clone depth of the vLLM checkout. |

## Swapping AITER (base image build)

AITER is compiled in `Dockerfile.rocm_base` and baked into `rocm/vllm-dev:base`;
`Dockerfile.rocm` has no `AITER_BRANCH`, so changing AITER means rebuilding the base.
`BUILD_BASE=true` builds a base, then vLLM on top of it:

```
VLLM_COMMIT=9cc347ae1d5b6f5e7d0a1a2c3d4e5f60718293a4
BUILD_BASE=true
AITER_BRANCH=v0.1.20
```

The base is pushed as `rocm/vllm-dev:base-<vllm-short-sha>-aiter-<aiter-ref>`. If that
tag already exists it is reused, not rebuilt.

| Variable | Default | Purpose |
| --- | --- | --- |
| `BUILD_BASE` | `false` | Build the base first. |
| `AITER_BRANCH` | — | AITER tag or branch. Empty keeps the Dockerfile's pin. |
| `AITER_REPO` | — | AITER repo, e.g. a fork. |
| `FA_BRANCH`, `TRITON_BRANCH`, `PYTORCH_BRANCH`, `MORI_BRANCH` | — | Same, for the other pinned deps. |
| `BASE_IMAGE_TAG` | derived | Override the base tag. |
| `BASE_FORCE_REBUILD` | `false` | Rebuild even if the tag exists. |
| `EXTRA_BASE_BUILD_ARGS` | — | Space-separated extra `--build-arg`s for the base. |

Limits from `Dockerfile.rocm_base`:

- `AITER_BRANCH` goes to `git clone --branch`, so it must be a **tag or branch**, not
  a sha. Tag it in a fork if needed.
- `AITER_ROCM_ARCH` is an `ENV` (`gfx942;gfx950`), so `--build-arg` cannot change it.

The base compiles PyTorch, Triton, flash-attention, AITER and mori from source; the
step allows 10 hours. If you already have a suitable base, set `BASE_IMAGE` instead.

## Triggering perf-eval

`TRIGGER_PERF_EVAL=true` triggers the `perf-eval` pipeline on the pushed image:

```
TRIGGER_PERF_EVAL=true
PERF_EVAL_WORKLOADS=llama3-8b-throughput,mixtral-latency
PERF_EVAL_RUN_TYPE=rc
```

perf-eval receives only these; other variables on this build do not reach it:

| Variable | Value |
| --- | --- |
| `VLLM_IMAGE_ROCM` | the pushed image, e.g. `rocm/vllm-dev:pr-12345-abc123de`. perf-eval runs it on ROCm workloads only. |
| `VLLM_COMMIT` | full vLLM sha |
| `WORKLOADS` | requested workloads, comma-separated |
| `PERF_EVAL_RUN_TYPE` | run label, if set |
| `UPSTREAM_BUILD_URL` | this build |

| Variable | Default | Purpose |
| --- | --- | --- |
| `TRIGGER_PERF_EVAL` | `false` | Master switch. Also forces the image push, since perf-eval pulls it. |
| `PERF_EVAL_PIPELINE` | `perf-eval` | Downstream pipeline slug. |
| `PERF_EVAL_WORKLOADS` | — | Comma- or space-separated workload names. |
| `PERF_EVAL_FANOUT` | `false` | `true`: one perf-eval build per workload. |
| `PERF_EVAL_ASYNC` | `true` | `false`: wait for perf-eval and inherit its result. |
| `PERF_EVAL_BRANCH` | `main` | perf-eval repo branch. |
| `PERF_EVAL_RUN_TYPE` | — | Run label (`nightly`, `rc`, `aiter-nightly`, ...) for the dashboard. Unset is `adhoc`. |

The image tag is only known at runtime, so `.buildkite/scripts/trigger_perf_eval.sh`
generates and uploads the trigger step. Workload names and the run type are limited to
`[A-Za-z0-9._/-]`. `.buildkite/scripts/test_trigger_perf_eval.sh` tests it against a
stubbed `buildkite-agent`; run it directly.

## AITER nightly

`FLOW=aiter-nightly` on a `vllm-perf-build` build uploads
`.buildkite/pipeline.aiter-nightly.yml` instead of `pipeline.source.yml`. It:

1. resolves the newest `vllm/vllm-openai-rocm:nightly-<sha>` (or `VLLM_COMMIT`),
2. picks the AITER nightly wheel built for that image's ROCm, torch and Python,
3. `pip install`s it over the image, as vLLM CI's `aiter-nightly-overlay.sh` does,
4. pushes `rocm/vllm-dev:nightly-aiter-<aiter-sha>-vllm-<vllm-sha>`,
5. with `TRIGGER_PERF_EVAL=true`, triggers perf-eval as above.

The wheel is picked by vLLM's
[`select_aiter_nightly_wheel.py`](https://github.com/vllm-project/vllm/blob/main/.buildkite/scripts/rocm/select_aiter_nightly_wheel.py),
the selector vLLM CI uses for `AITER_NIGHTLY=1`, fetched at the image's vLLM commit and
run inside the image. It takes the newest exact match on
<https://rocm.frameworks-nightlies.amd.com/whl-multi-arch/amd-aiter/>, so this flow and
vLLM CI can differ if a new wheel lands between their runs.

| Exit | Meaning |
| --- | --- |
| 10 | No wheel matches. The annotation lists what the index has, e.g. `No AITER nightly for rocm10.0.0/torch2.12/cp312. Available: rocm10.0.0/torch2.13/cp312, ...` |
| 11 | The wheel does not install. |
| 1 | Fetch or registry error. Retried once, with the same wheel. |

On 10 or 11 nothing is pushed and perf-eval is not triggered, so a night without a
compatible wheel gives no numbers rather than wrong ones.

- **Manual test:** `FLOW=aiter-nightly`. Add `PUSH_IMAGE=false`, without
  `TRIGGER_PERF_EVAL`, for a build-only smoke test.
- **Nightly:** a Schedule (`0 2 * * *` America/Chicago) with `FLOW=aiter-nightly`,
  `TRIGGER_PERF_EVAL=true`, and `PERF_EVAL_BRANCH` and `PERF_EVAL_WORKLOADS` matching
  perf-eval's own nightly baseline schedule, so the two runs differ only in AITER.

Without `PERF_EVAL_WORKLOADS`, perf-eval runs its default ROCm workloads. The step
removes the images it pulled and built when it finishes.

| Variable | Default | Purpose |
| --- | --- | --- |
| `VLLM_COMMIT` | newest nightly | Pin the nightly (full 40-character sha, 2026-10-12 or later, since the selector is fetched at it). |
| `PUSH_IMAGE` | `true` | `false` builds only. Ignored when `TRIGGER_PERF_EVAL=true`. |
| `PERF_EVAL_RUN_TYPE` | `aiter-nightly` | Run label for the dashboard. |

The other perf-eval variables apply as above.

## Setup

1. Create the Buildkite pipeline on this repo with **Pipeline Settings -> Steps**:

   ```yaml
   steps:
     - label: ":pipeline:"
       command: buildkite-agent pipeline upload .buildkite/pipeline.yml
       agents:
         queue: amd-cpu
   ```

   Keep the `agents` block: this step runs before the repo is read, so it does not
   inherit `pipeline.yml`'s queue and would wait on the default queue.

2. Store a Docker Hub token with **Read & Write** on `rocm/vllm-dev` as the Buildkite
   secret `dockerhub_token` (Pipeline Settings -> Secrets). Agents without the secrets
   backend can export `DOCKERHUB_TOKEN` from an `environment` hook instead; it takes
   precedence.

3. Make sure the `amd-cpu` agents have a working docker daemon and plenty of disk.

## How it works

`.buildkite/scripts/resolve_ref.sh` pins the PR or branch to a commit with
`git ls-remote` and records the repo, ref, commit and tag in meta-data, so a branch
that moves mid-build cannot change what ships.

`.buildkite/scripts/build_and_push.sh` fetches that commit, builds
`docker/Dockerfile.rocm` with `REMOTE_VLLM=0` (from the checkout, not a clone inside
the Dockerfile), and pushes. Older commits use the root-level `Dockerfile.rocm`.

## Build cost

Even with a pulled base, the HIP compile of `csrc`, the Rust frontend and the
NIXL/RoCSHMEM/DeepEP stages make for a long build and a large disk footprint. Levers,
roughly by payoff:

- Narrow `PYTORCH_ROCM_ARCH` to the arch you test on (`gfx942`).
- `EXTRA_BUILD_ARGS="NIC_BACKEND=none"` skips the networking stages.
- `USE_SCCACHE=1` plus the Dockerfile's `SCCACHE_*` build args, against a shared S3 bucket.
- Run the `build` step on a larger queue and keep orchestration on the small one.
