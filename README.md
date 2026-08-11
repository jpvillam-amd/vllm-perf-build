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

All of these are set in `.buildkite/pipeline.yml` and can be overridden per build:

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
