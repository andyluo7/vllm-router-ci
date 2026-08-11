# Upstream status

Verified on 2026-08-10:

- [Issue #142: ROCm CI parity](https://github.com/vllm-project/router/issues/142)
  remains open.
- [PR #164: original MoRI e2e proposal](https://github.com/vllm-project/router/pull/164)
  remains open and was used as historical/reference material.
- [PR #202: Add MoRI XGMI and RDMA coverage](https://github.com/vllm-project/router/pull/202)
  merged as `e1ef3accd25d0def0e1c65c8c7ab243bedfc4753`.
- [PR #203: Skip NVIDIA P/D in ROCm-only builds](https://github.com/vllm-project/router/pull/203)
  merged as `5002469c5a208837d351e9d56a8f0a2c63693692`.

The live lanes address same-host MoRI XGMI and two-node MoRI RDMA for both read
modes. They should not be described as complete RIXL/NIXL parity unless the
maintainers explicitly accept that mapping or add separate coverage.
