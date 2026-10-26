# Nightly monitoring and burn-in

The private GitHub Actions workflow `ROCm nightly burn-in monitor` checks the
public Buildkite pipeline every day at 12:30 UTC. That is 05:30 PDT or 04:30
PST, leaving 7.5 hours for the 05:00 UTC Buildkite schedule to finish.

The monitor accepts a nightly only when all of these conditions hold:

- upstream Router PRs `#204` and `#205` have merged, and the build started
  after the later merge;
- the Buildkite source is `schedule`, not a manual UI/API invocation;
- the configured nightly build message matches exactly;
- the overall build passed;
- the XGMI matrix passed 2/2 jobs without a retry;
- the two-node RDMA matrix passed 2/2 jobs without a retry;
- no command step in the scheduled build was retried; and
- the newest scheduled run is no more than 20 hours old.

Every check is posted to the private GitHub issue titled
`ROCm CI seven-night burn-in`. A missing, stale, failed, incomplete, or retried
nightly fails the workflow, which activates normal GitHub Actions failure
notifications. The issue is assigned to the repository owner to provide an
explicit notification subscription. The report shows the current consecutive
clean-run count. Seven clean scheduled runs are required before burn-in is
complete.

Before both prerequisite PRs merge, the workflow records a waiting result and
does not increment the streak. After they merge, builds created before the
later merge are excluded. A 30-hour grace period allows the first eligible
05:00 UTC nightly to occur; after that, absence of an eligible run is an alert.

## Manual monitor validation

Use workflow dispatch with an explicit build number and source to validate the
monitor without changing the scheduled burn-in count. Buildkite build `#642`
is the reference ROCm-lane fixture: set `build_number=642` and
`expected_source=ui`. Explicit-fixture mode ignores retries outside the two ROCm
matrices; scheduled acceptance does not.

For local validation:

```bash
BUILD_NUMBER=642 EXPECTED_SOURCE=ui ./scripts/check-nightly-build.sh
```

The monitor deliberately uses Buildkite's public build JSON and step-data
endpoints. It does not require or store a Buildkite API token.

`tests/test-nightly-monitor.sh` exercises the clean-streak calculation and the
source-mismatch, retry, failed-matrix, missing-matrix, and stale-build alert
paths with deterministic fixtures. The private repository runs these tests on
every pull request and every push to `main`.
