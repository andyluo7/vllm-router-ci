# Buildkite schedule

The live schedule is configured at:

<https://buildkite.com/vllm/router/settings/schedules>

| Field | Value |
| --- | --- |
| Description | `ROCm MoRI RDMA Nightly — 2×MI300X` |
| Cron | `0 2 * * * America/Los_Angeles` |
| Build message | `Nightly ROCm MoRI XGMI/RDMA validation on 2×MI300X` |
| Commit | `HEAD` |
| Branch | `main` |
| Enabled | yes |

Environment:

```text
NIGHTLY=1
ROCM_ONLY=1
RUN_ROCM_RDMA=1
```

The hosts also serve SMG's AMD GitHub Actions lanes. In particular, SMG's
daily PD topology workflow starts at `09:45 UTC`, 45 minutes after this Router
schedule starts during daylight time, and weekly BFCL AMD legs can run for
hours. Clock separation is therefore not a sufficient ownership mechanism;
the host-level lease described in [Operations](operations.md) is required.

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
