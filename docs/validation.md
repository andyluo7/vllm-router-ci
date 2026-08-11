# Validation record

## Build #642

[Buildkite build #642](https://buildkite.com/vllm/router/builds/642/table) ran
commit `5002469c5a208837d351e9d56a8f0a2c63693692` on 2026-08-10.

| Lane | Result |
| --- | --- |
| ROCm MoRI XGMI, `read_mode=true`, 2 GPUs | passed |
| ROCm MoRI XGMI, `read_mode=false`, 2 GPUs | passed |
| ROCm MoRI RDMA, `read_mode=true`, 2 nodes | passed |
| ROCm MoRI RDMA, `read_mode=false`, 2 nodes | passed |
| Generic NVIDIA P/D | ignored as intended by `ROCM_ONLY=1` |

Both RDMA jobs passed coordinator/worker preflight, engine startup, a simple
cross-node connectivity prompt, and 500-request GSM8K evaluation. Both measured
`0.4780` accuracy; the required threshold was `0.4100`.

## Rust integration-test flake

The initial Rust Integration Tests attempt failed in
`dp_e2e_tests::test_regular_router_dp1_no_dp_header` because port `37305` was
already in use. The resulting request returned HTTP 500 instead of 200. The
retry passed.

This was a CPU test port-allocation/concurrency race, not a ROCm, GPU, kernel,
or RDMA failure. It should be fixed upstream by reserving a listener atomically
or otherwise ensuring unique test ports; retries should not be the permanent
solution.

## Acceptance criteria

Do not call the cluster healthy solely from host-memory verbs or interface
enumeration. A live validation must include:

- all eight MI300X GPUs and all eight HCAs visible on both hosts
- MTU-9000 reachability on every rail
- ROCm Docker device and shared-memory contract
- same-host XGMI GPU execution
- cross-node MoRI RDMA engine startup, connectivity, and accuracy traffic
- both `read_mode=true` and `read_mode=false`
