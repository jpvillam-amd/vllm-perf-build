# vllm-perf-build

Buildkite pipeline that builds a vLLM ROCm docker image from any vLLM PR, branch, or
commit and publishes it to [`rocm/vllm-dev`](https://hub.docker.com/r/rocm/vllm-dev).

## Flows

`FLOW` on the build picks what runs. `pipeline.yml` only picks the flow; each flow's
steps live in their own file:

| `FLOW` | Steps | Runs |
| --- | --- | --- |
| unset | `pipeline.source.yml` | Build vLLM from source for a PR, branch or commit. Takes hours; much longer with `BUILD_BASE=true`. |
| `aiter-nightly` | `pipeline.aiter-nightly.yml` | Install the newest matching AITER nightly wheel over the latest vLLM ROCm nightly. No compile. See [AITER nightly](#aiter-nightly). |

Any other value fails the first step, so a typo cannot start a source build.

## Triggering a build

Start a build on the Buildkite pipeline and set **one** of these environment variables:

| Variable | Example | Builds |
| --- | --- | --- |
| `VLLM_PR` | `12345` | `refs/pull/12345/head` on `vllm-project/vllm` — works for fork PRs too |
| `VLLM_BRANCH` | `my-feature` | that branch |
| `VLLM_COMMIT` | `a1b2c3d...` | that exact commit |

With none set, the pipeline builds `main`.

Via the API:

```bash
curl -X POST "https://api.buildkite.com/v2/organizations/<org>/pipelines/vllm-perf-build/builds" \
  -H "Authorization: Bearer $BUILDKITE_TOKEN" \
  -d '{"commit":"HEAD","branch":"main","env":{"VLLM_PR":"12345"}}'
```

## Resulting image

Tags are derived from the ref plus the resolved short sha, so every build is traceable
to an exact vLLM commit:

| Trigger | Tag |
| --- | --- |
| `VLLM_PR=12345` | `rocm/vllm-dev:pr-12345-<short-sha>` |
| `VLLM_BRANCH=my-feature` | `rocm/vllm-dev:my-feature-<short-sha>` |
| `VLLM_COMMIT=a1b2c3d…` | `rocm/vllm-dev:commit-<short-sha>` |

Set `IMAGE_TAG` to override the tag entirely, or `EXTRA_IMAGE_TAGS` (space-separated)
to publish additional tags alongside the primary one.

## Configuration

Defaults live in the scripts, not in a pipeline-level `env:` block — an `env:` block in
the uploaded pipeline overrides variables set on the build at trigger time, which makes
options impossible to turn on from the UI. Set any of these as build environment
variables:

| Variable | Default | Purpose |
| --- | --- | --- |
| `VLLM_REPO` | `https://github.com/vllm-project/vllm.git` | Source repo. Leave as upstream for PRs — even fork PRs are fetched from here. |
| `BASE_IMAGE` | see [How it works](#how-it-works) | Prebuilt ROCm/PyTorch base (the `stack`, on current vLLM), pulled rather than built. |
| `DOCKER_TARGET` | `vllm-openai` | Dockerfile stage (a bake target on current vLLM). `runtime` (`final` before vllm#61939) for the runtime without the serving entrypoint, `test` for the CI test image. |
| `PYTORCH_ROCM_ARCH` | `gfx942;gfx950` | GPU targets. Each arch is a full HIP kernel compile pass. |
| `MAX_JOBS` | `$(nproc)` | Build parallelism. Older vLLM only: current `Dockerfile.rocm` has no such arg and uses the builder's `nproc`. |
| `ROCM_CI_REPO` | `rocm/vllm-ci` | Where vLLM CI publishes its prebuilt stack and runtime images. |
| `ROCM_CI_PR_REPO` | `rocm/vllm-dev` | Where vLLM CI publishes them for PR builds, under `pr<N>-` tags. |
| `IMAGE_REPO` | `rocm/vllm-dev` | Destination repo. |
| `DOCKERHUB_USER` | `jpvillam` | Docker Hub account used to push. |
| `DOCKERHUB_TOKEN_SECRET` | `dockerhub_token` | Name of the Buildkite secret holding the access token. |
| `PUSH_IMAGE` | `true` | Set `false` to build only, as a "does this PR still build" gate. Ignored when `TRIGGER_PERF_EVAL=true`. |
| `EXTRA_BUILD_ARGS` | — | Space-separated extra `--build-arg`s, e.g. `NIC_BACKEND=none USE_SCCACHE=1`. |
| `CLONE_DEPTH` | `1` | Shallow clone depth for the vLLM checkout. |

## Swapping AITER (building the base image)

AITER is cloned and compiled inside **`Dockerfile.rocm_base`**, not `Dockerfile.rocm`.
It's baked into the base (vLLM CI's stack on current vLLM, `rocm/vllm-dev:base` on
older commits), which the main build normally just pulls. So
changing AITER means rebuilding the base image — passing `AITER_BRANCH` to the main
build would be silently ignored, since `Dockerfile.rocm` has no such ARG.

Set `BUILD_BASE=true` and the pipeline builds a base first, then builds vLLM on top of
it automatically:

```
VLLM_COMMIT=9cc347ae1d5b6f5e7d0a1a2c3d4e5f60718293a4
BUILD_BASE=true
AITER_BRANCH=v0.1.20
```

The base is tagged `rocm/vllm-dev:base-<vllm-short-sha>-aiter-<aiter-ref>` and pushed,
then handed to the main build via build meta-data. Because the tag encodes both inputs,
**a base that already exists is reused rather than rebuilt** — so a second build with
the same vLLM commit and AITER ref skips straight to the vLLM build.

| Variable | Default | Purpose |
| --- | --- | --- |
| `BUILD_BASE` | `false` | Master switch for the base build. |
| `AITER_BRANCH` | — | AITER tag or branch. Empty keeps the Dockerfile's own pin. |
| `AITER_REPO` | — | AITER repo, e.g. a fork. |
| `FA_BRANCH`, `TRITON_BRANCH`, `PYTORCH_BRANCH`, `MORI_BRANCH` | — | Same idea for the other pinned deps. |
| `BASE_IMAGE_TAG` | derived | Override the computed base tag entirely. |
| `BASE_FORCE_REBUILD` | `false` | Rebuild even if the tag already exists. |
| `EXTRA_BASE_BUILD_ARGS` | — | Space-separated extra `--build-arg`s for the base build. |

Two constraints inherited from `Dockerfile.rocm_base`:

- It runs `git clone --branch ${AITER_BRANCH}`, which accepts a **tag or branch only**.
  A bare commit sha will not clone — tag it in a fork if you need one.
- `AITER_ROCM_ARCH` is an `ENV` (`gfx942;gfx950`), not an `ARG`, so `--build-arg`
  cannot change AITER's arch list.

The base build compiles PyTorch, Triton, flash-attention, AITER and mori from source.
It is *much* longer than the vLLM build — the step allows 10 hours. If you already have
a suitable base image, skip all of this and just set `BASE_IMAGE` instead.

## Triggering perf-eval downstream

Off by default. Set `TRIGGER_PERF_EVAL=true` on a build and, once the image is pushed,
the pipeline triggers the `perf-eval` pipeline against it:

```
TRIGGER_PERF_EVAL=true
PERF_EVAL_WORKLOADS=llama3-8b-throughput,mixtral-latency
PERF_EVAL_RUN_TYPE=rc
```

perf-eval receives these environment variables:

| Variable | Value |
| --- | --- |
| `VLLM_IMAGE_ROCM` | the image just pushed, e.g. `rocm/vllm-dev:pr-12345-abc123de`. perf-eval runs it on ROCm workloads only. |
| `VLLM_COMMIT` | full vLLM sha the image was built from |
| `WORKLOADS` | the requested workloads, comma-separated |
| `PERF_EVAL_RUN_TYPE` | the run's label, when one was set |
| `UPSTREAM_BUILD_URL` | link back to the build that produced the image |

A trigger step passes only the variables it names, so anything perf-eval should
see has to be in that list. Setting a variable on *this* build does not reach
the downstream one.

| Variable | Default | Purpose |
| --- | --- | --- |
| `TRIGGER_PERF_EVAL` | `false` | Master switch. Also forces the image push, since perf-eval pulls it. |
| `PERF_EVAL_PIPELINE` | `perf-eval` | Downstream pipeline slug. |
| `PERF_EVAL_WORKLOADS` | — | Comma- or space-separated workload names. |
| `PERF_EVAL_FANOUT` | `false` | `true` triggers one perf-eval build per workload instead of one build receiving the whole list. |
| `PERF_EVAL_ASYNC` | `true` | `true` fires and forgets; `false` makes this build wait for perf-eval and inherit its pass/fail. |
| `PERF_EVAL_BRANCH` | `main` | Branch of the perf-eval repo to build. |
| `PERF_EVAL_RUN_TYPE` | — | Labels the run (`nightly`, `rc`, `aiter-nightly`, ...) so the dashboard can group like with like. Unset means perf-eval files it under `adhoc`. |

Because the image tag isn't known until the resolve step has run, and a `trigger` step's
`build.env` is static YAML, the trigger step is generated at runtime by
`.buildkite/scripts/trigger_perf_eval.sh` and uploaded. Workload names and the run type
are restricted to `[A-Za-z0-9._/-]` so they cannot break out of the generated YAML.
`.buildkite/scripts/test_trigger_perf_eval.sh` exercises that script against a stubbed
`buildkite-agent` and needs no Buildkite access; run it directly.

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
  `TRIGGER_PERF_EVAL=true`, `PERF_EVAL_RUN_TYPE=aiter-nightly`, and `PERF_EVAL_BRANCH`
  and `PERF_EVAL_WORKLOADS` matching perf-eval's own nightly baseline schedule, so the
  two runs differ only in AITER. Manual runs without `PERF_EVAL_RUN_TYPE` are filed
  under `adhoc`.

Without `PERF_EVAL_WORKLOADS`, perf-eval runs its default ROCm workloads. The step
removes the images it pulled and built when it finishes.

| Variable | Default | Purpose |
| --- | --- | --- |
| `VLLM_COMMIT` | newest nightly | Pin the nightly (full 40-character sha, 2026-10-12 or later, since the selector is fetched at it). |
| `PUSH_IMAGE` | `true` | `false` builds only. Ignored when `TRIGGER_PERF_EVAL=true`. |

The other perf-eval variables apply as above.

## Setup

1. Create the pipeline in Buildkite pointing at this repo, with **Pipeline Settings ->
   Steps** set to:

   ```yaml
   steps:
     - label: ":pipeline:"
       command: buildkite-agent pipeline upload .buildkite/pipeline.yml
       agents:
         queue: amd-cpu
   ```

   The `agents` block is required. This bootstrap step runs before Buildkite has read
   the repo, so it does *not* inherit the `agents:` block in `.buildkite/pipeline.yml`
   — without it the job goes to the default queue and will sit unstarted if nothing is
   listening there.

2. Create a Docker Hub access token with **Read & Write** scope on `rocm/vllm-dev`, and
   store it as a Buildkite secret named `dockerhub_token`:

   ```bash
   # Buildkite UI: Pipeline Settings -> Secrets -> New Secret
   # key: dockerhub_token   value: <the token>
   ```

   The build reads it with `buildkite-agent secret get dockerhub_token`. If your agents
   are self-hosted and don't have the Buildkite secrets backend available, export
   `DOCKERHUB_TOKEN` from an agent `environment` hook instead — the script prefers that
   variable when present, so no pipeline change is needed.

3. Confirm the agents in the `amd-cpu` queue have a working docker daemon and enough
   free disk (see below).

## How it works

`.buildkite/scripts/resolve_ref.sh` turns the requested PR/branch into an immutable
commit sha with `git ls-remote`, then records the repo, ref, commit, and image tag in
Buildkite meta-data. Pinning up front means a branch that moves mid-build cannot change
what actually ships under the tag.

`.buildkite/scripts/build_and_push.sh` fetches that exact commit and builds
`docker/Dockerfile.rocm` from it, then pushes. It looks for a root-level
`Dockerfile.rocm` for older vLLM commits, before the Dockerfiles moved under `docker/`.
How it builds depends on the Dockerfile at that commit:

- **Current vLLM** (from [vllm#61939](https://github.com/vllm-project/vllm/pull/61939),
  2026-10-29): `Dockerfile.rocm` starts `FROM stack`, a named context that only vLLM's
  `docker/docker-bake-rocm.hcl` provides, so the build runs `docker buildx bake` with
  that file, the way vLLM CI does. The `stack` (the final stage of
  `Dockerfile.rocm_base`) and the `runtime` (stack plus every pip dependency) come from
  vLLM CI's content-keyed images for that commit, `rocm/vllm-ci:stack-rocm-<Ks>` and
  `runtime-rocm-<Kr>`, or the `rocm/vllm-dev:pr<N>-` copies for a PR that changed them.
  They are pinned by digest. The keys are computed as vLLM's
  `.buildkite/scripts/rocm/build.sh` computes them. If a stack has not been published,
  the build compiles it from `Dockerfile.rocm_base` (hours). If a runtime is missing,
  the build compiles it on top of the stack (minutes). `BASE_IMAGE`, or a base from
  `BUILD_BASE=true`, replaces the stack, and then the runtime is always built on it.
  So is the runtime whenever `EXTRA_BUILD_ARGS` is set, since args like `NIC_BACKEND`
  configure it. The build context is an export of the commit plus the
  `.git_archival.txt` that vLLM's version stage needs in place of `.git`.
- **Older vLLM**: a plain `docker build` on top of `BASE_IMAGE` (default
  `rocm/vllm-dev:base`), with `REMOTE_VLLM=0`, so the image is built from the
  checked-out source rather than a clone performed inside the Dockerfile.

`.buildkite/scripts/test_build_and_push.sh` runs both scripts against a fake vLLM repo
with `buildkite-agent` and `docker` stubbed. Run it directly.

## Note on build cost

Even with `BASE_IMAGE` pulled rather than built, the remaining work — HIP kernel
compilation of vLLM's `csrc`, plus the Rust frontend and any NIXL/RoCSHMEM/DeepEP
stages — is heavy. Expect a long build and a large disk footprint.

If builds turn out to be too slow or hit disk limits, the levers, roughly in order of
payoff:

- Narrow `PYTORCH_ROCM_ARCH` to just the arch you actually test on (`gfx942`).
- Set `EXTRA_BUILD_ARGS="NIC_BACKEND=none"` to skip the networking stages.
- Enable sccache against a shared S3 bucket via `USE_SCCACHE=1` plus the
  `SCCACHE_*` build args the Dockerfile accepts.
- Move the `build` step to a larger queue and leave orchestration on the small one.
