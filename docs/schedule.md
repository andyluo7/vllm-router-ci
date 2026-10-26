# Buildkite schedule

The live schedule is configured at:

<https://buildkite.com/vllm/router/settings/schedules>

| Field | Value |
| --- | --- |
| Description | `ROCm MoRI RDMA Nightly — 2×MI300X` |
| Cron | `0 5 * * * UTC` |
| Build message | `Nightly ROCm MoRI XGMI/RDMA validation on 2×MI300X` |
| Commit | `HEAD` |
| Branch | `main` |
| Enabled | yes |

When editing the live schedule, change only the cron interval. Keep the build
message exact because the nightly monitor uses it to identify eligible builds.

## Timing window

The schedule is fixed in UTC so daylight-saving changes cannot move it into a
later accelerator window:

- configured start: 05:00 UTC daily;
- expected clean finish: about 05:50 UTC, based on exact-head Buildkite build
  [#1020](https://buildkite.com/vllm/router/builds/1020), which completed in
  approximately 49 minutes;
- reserved operating window: 05:00-06:30 UTC;
- Pacific conversion: 22:00-23:30 PDT or 21:00-22:30 PST, on the preceding
  local calendar day.

Clock separation reduces predictable contention with later scheduled
accelerator work, but it is not an ownership mechanism. Delayed, manual, and
pull-request jobs can run at any time, so the host-level lease described in
[Operations](operations.md) remains required.

Environment:

```text
NIGHTLY=1
ROCM_ONLY=1
RUN_ROCM_RDMA=1
```

`ROCM_ONLY=1` skips the generic NVIDIA P/D lane. A real scheduled invocation
selects RDMA through `NIGHTLY=1`. `RUN_ROCM_RDMA=1` is also retained because
Buildkite's schedule **Run now** action creates a UI-source build; UI/API builds
need the explicit RDMA flag.

XGMI runs automatically on `main`. For a manual UI/API build on another branch,
set both:

```text
RUN_ROCM_XGMI=1
RUN_ROCM_RDMA=1
```

A clean checkout is not normally required. Select it only when diagnosing a
suspected stale checkout or cache problem.

The private `ROCm nightly burn-in monitor` GitHub Actions workflow checks the
result daily and records it in a private tracking issue. See
[Nightly monitoring and burn-in](burn-in.md).
