# vllm-perf-build

Buildkite pipeline that builds a vLLM ROCm docker image from any vLLM PR, branch, or
commit and publishes it to [`rocm/vllm-dev`](https://hub.docker.com/r/rocm/vllm-dev).

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
| `BASE_IMAGE` | `rocm/vllm-dev:base` | Prebuilt ROCm/PyTorch base, pulled rather than built. |
| `DOCKER_TARGET` | `vllm-openai` | Dockerfile stage. `final` for the runtime without the serving entrypoint, `test` for the CI test image. |
| `PYTORCH_ROCM_ARCH` | `gfx942;gfx950` | GPU targets. Each arch is a full HIP kernel compile pass. |
| `MAX_JOBS` | `$(nproc)` | Build parallelism. |
| `IMAGE_REPO` | `rocm/vllm-dev` | Destination repo. |
| `DOCKERHUB_USER` | `jpvillam` | Docker Hub account used to push. |
| `DOCKERHUB_TOKEN_SECRET` | `dockerhub_token` | Name of the Buildkite secret holding the access token. |
| `PUSH_IMAGE` | `true` | Set `false` to build only, as a "does this PR still build" gate. |
| `EXTRA_BUILD_ARGS` | — | Space-separated extra `--build-arg`s, e.g. `NIC_BACKEND=none USE_SCCACHE=1`. |
| `CLONE_DEPTH` | `1` | Shallow clone depth for the vLLM checkout. |

## Swapping AITER (building the base image)

AITER is cloned and compiled inside **`Dockerfile.rocm_base`**, not `Dockerfile.rocm`.
It's baked into `rocm/vllm-dev:base`, which the main build normally just pulls. So
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
```

perf-eval receives these environment variables:

| Variable | Value |
| --- | --- |
| `VLLM_IMAGE` | the image just pushed, e.g. `rocm/vllm-dev:pr-12345-abc123de` |
| `VLLM_COMMIT` | full vLLM sha the image was built from |
| `WORKLOADS` | the requested workloads |
| `UPSTREAM_BUILD_URL` | link back to the build that produced the image |

| Variable | Default | Purpose |
| --- | --- | --- |
| `TRIGGER_PERF_EVAL` | `false` | Master switch. |
| `PERF_EVAL_PIPELINE` | `perf-eval` | Downstream pipeline slug. |
| `PERF_EVAL_WORKLOADS` | — | Comma- or space-separated workload names. |
| `PERF_EVAL_FANOUT` | `false` | `true` triggers one perf-eval build per workload instead of one build receiving the whole list. |
| `PERF_EVAL_ASYNC` | `true` | `true` fires and forgets; `false` makes this build wait for perf-eval and inherit its pass/fail. |
| `PERF_EVAL_BRANCH` | `main` | Branch of the perf-eval repo to build. |
| `PERF_EVAL_IMAGE_VAR` | `VLLM_IMAGE` | Rename if perf-eval reads a different variable for the image. |
| `PERF_EVAL_WORKLOAD_VAR` | `WORKLOADS` | Rename if perf-eval reads a different variable for the workloads. |

Because the image tag isn't known until the resolve step has run, and a `trigger` step's
`build.env` is static YAML, the trigger step is generated at runtime by
`.buildkite/scripts/trigger_perf_eval.sh` and uploaded. Workload names are restricted to
`[A-Za-z0-9._/-]` so they cannot break out of the generated YAML.

## AITER nightly (overlay onto the published nightly)

`.buildkite/pipeline.aiter-nightly.yml` is a separate, lightweight flow for the
common "how does AITER main look tonight?" question. Rather than rebuilding the
ROCm base to swap AITER (the `BUILD_BASE` path above, ~10h), it:

1. resolves the newest published `vllm/vllm-openai-rocm:nightly-<sha>` (or a
   pinned `VLLM_COMMIT`) and the AITER commit (`main` by default),
2. pulls that nightly and builds `docker/Dockerfile.aiter-overlay` on top of it,
   which uninstalls the bundled `amd-aiter` and reinstalls AITER from the
   resolved commit with `PREBUILD_KERNELS=1` (~1-2h, just the AITER compile),
3. pushes to `rocm/vllm-dev:nightly-aiter-<aiter-sha>-vllm-<vllm-sha>`, and
4. triggers perf-eval via the same `trigger_perf_eval.sh` as the main pipeline.

It is designed to run as a **Buildkite scheduled build**: with no environment
variables set it resolves everything itself, so a schedule of `0 7 * * *` is
enough. Point a second pipeline at this repo whose bootstrap upload is
`.buildkite/pipeline.aiter-nightly.yml` (see Setup), then add the schedule with
just `TRIGGER_PERF_EVAL=true` in its env.

perf-eval reads the image from `VLLM_IMAGE` (the default here) and applies its
own default workload set, so no `PERF_EVAL_WORKLOADS` is needed. This flow also
pins `PERF_EVAL_BRANCH` to `micah/migrate-vllm-dashboard-nightly` (where the
nightly-dashboard migration lives) instead of `main`; override it on the build
if that changes.

| Variable | Default | Purpose |
| --- | --- | --- |
| `VLLM_COMMIT` | newest nightly | Pin the vLLM nightly commit; otherwise the newest `nightly-<sha>` tag on `NIGHTLY_REPO` is resolved from Docker Hub. |
| `NIGHTLY_REPO` | `vllm/vllm-openai-rocm` | Published nightly repo to overlay onto. |
| `OVERLAY_BASE_IMAGE` | derived | Override the base image entirely (skips the lookup). |
| `AITER_BRANCH` | `main` | AITER branch to build. |
| `AITER_COMMIT` | resolved from `AITER_BRANCH` | Pin AITER to an exact sha instead. Unlike the base build, the overlay full-clones then checks out, so a bare sha works. |
| `AITER_REPO` | `https://github.com/ROCm/aiter.git` | AITER repo (e.g. a fork). |
| `IMAGE_TAG` | `nightly-aiter-<aiter-sha>-vllm-<vllm-sha>` | Override the computed tag. |
| `PUSH_IMAGE` | `true` | `false` builds only. |
| `PULL_BASE` | `true` | Pull the nightly before building (fails fast on a bad ref). |
| `PERF_EVAL_BRANCH` | `micah/migrate-vllm-dashboard-nightly` | perf-eval repo branch to build (defaulted for this flow, not `main`). |

Perf-eval is otherwise wired exactly as in the section above —
`TRIGGER_PERF_EVAL`, `PERF_EVAL_WORKLOADS`, `PERF_EVAL_FANOUT`, etc. all apply.

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

`.buildkite/scripts/build_and_push.sh` fetches that exact commit, builds
`docker/Dockerfile.rocm` from it with `REMOTE_VLLM=0` (so the image is built from the
checked-out source rather than a clone performed inside the Dockerfile), then pushes.
It falls back to a root-level `Dockerfile.rocm` for older vLLM commits, before the
Dockerfiles moved under `docker/`.

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
