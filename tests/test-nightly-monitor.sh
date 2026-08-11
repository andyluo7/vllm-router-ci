#!/usr/bin/env bash

set -Eeuo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
MONITOR="${ROOT_DIR}/scripts/check-nightly-build.sh"
BUILD_MESSAGE="Nightly ROCm MoRI XGMI/RDMA validation on 2×MI300X"
FIXTURE_DIR=$(mktemp -d)
OUTPUT_DIR=$(mktemp -d)
trap 'rm -rf "${FIXTURE_DIR}" "${OUTPUT_DIR}"' EXIT

write_build() {
  local number=$1
  local state=$2
  local source=$3
  local created_at=$4
  jq -n \
    --argjson number "${number}" \
    --arg state "${state}" \
    --arg source "${source}" \
    --arg message "${BUILD_MESSAGE}" \
    --arg created_at "${created_at}" \
    '{number: $number, state: $state, source: $source, message: $message, created_at: $created_at}' \
    >"${FIXTURE_DIR}/build-${number}.json"
}

write_steps() {
  local number=$1
  local xgmi_outcome=$2
  local rdma_outcome=$3
  local other_retries=$4
  jq -n \
    --arg xgmi_outcome "${xgmi_outcome}" \
    --arg rdma_outcome "${rdma_outcome}" \
    --argjson other_retries "${other_retries}" \
    '[
      {
        type: "command",
        label: "ROCm MoRI XGMI (read_mode={{matrix.read_mode}}, 2 GPUs)",
        state: "finished",
        outcome: $xgmi_outcome,
        statistics: {jobs_count: 2, jobs_finished_count: 2, retries_count: 0}
      },
      {
        type: "command",
        label: "ROCm MoRI RDMA P/D (read_mode={{matrix.read_mode}}, 2 nodes)",
        state: "finished",
        outcome: $rdma_outcome,
        statistics: {jobs_count: 2, jobs_finished_count: 2, retries_count: 0}
      },
      {
        type: "command",
        label: "Rust Integration Tests",
        state: "finished",
        outcome: "passed",
        statistics: {jobs_count: 1, jobs_finished_count: 1, retries_count: $other_retries}
      }
    ]' >"${FIXTURE_DIR}/steps-${number}.json"
}

write_steps_without_rdma() {
  local number=$1
  jq -n '[{
    type: "command",
    label: "ROCm MoRI XGMI (read_mode={{matrix.read_mode}}, 2 GPUs)",
    state: "finished",
    outcome: "passed",
    statistics: {jobs_count: 2, jobs_finished_count: 2, retries_count: 0}
  }]' >"${FIXTURE_DIR}/steps-${number}.json"
}

assert_contains() {
  local output_file=$1
  local expected=$2
  if ! grep -F "${expected}" "${output_file}" >/dev/null; then
    echo "FAIL: expected output to contain: ${expected}" >&2
    sed -n '1,240p' "${output_file}" >&2
    exit 1
  fi
}

run_success() {
  local name=$1
  shift
  local output_file="${OUTPUT_DIR}/${name}.out"
  if ! env BUILDKITE_FIXTURE_DIR="${FIXTURE_DIR}" "$@" "${MONITOR}" >"${output_file}" 2>&1; then
    echo "FAIL: ${name} unexpectedly failed" >&2
    sed -n '1,240p' "${output_file}" >&2
    exit 1
  fi
}

run_failure() {
  local name=$1
  shift
  local output_file="${OUTPUT_DIR}/${name}.out"
  if env BUILDKITE_FIXTURE_DIR="${FIXTURE_DIR}" "$@" "${MONITOR}" >"${output_file}" 2>&1; then
    echo "FAIL: ${name} unexpectedly passed" >&2
    sed -n '1,240p' "${output_file}" >&2
    exit 1
  fi
}

fixture_now=$(jq -nr '"2026-01-01T02:00:00Z" | fromdateiso8601')

write_build 101 passed ui 2026-01-01T01:00:00.000Z
write_steps 101 passed passed 1
run_success explicit_ui BUILD_NUMBER=101 EXPECTED_SOURCE=ui
assert_contains "${OUTPUT_DIR}/explicit_ui.out" "Explicit-build validation checks the ROCm lanes"

run_failure source_mismatch BUILD_NUMBER=101 EXPECTED_SOURCE=schedule
assert_contains "${OUTPUT_DIR}/source_mismatch.out" 'No matching `schedule` build was found'

write_build 200 passed schedule 2026-01-01T00:30:00.000Z
write_steps 200 passed passed 0
write_build 201 passed schedule 2026-01-01T01:00:00.000Z
write_steps 201 passed passed 0
run_success clean_streak \
  CANDIDATE_BUILD_NUMBERS="201 200" EXPECTED_SOURCE=schedule CURRENT_EPOCH="${fixture_now}"
assert_contains "${OUTPUT_DIR}/clean_streak.out" "Burn-in progress:** 2/7"

write_build 298 passed schedule 2026-01-01T00:15:00.000Z
write_steps 298 passed passed 0
write_build 299 failed schedule 2026-01-01T00:30:00.000Z
write_steps 299 passed passed 0
write_build 300 passed schedule 2026-01-01T01:30:00.000Z
write_steps 300 passed passed 0
run_success reset_streak \
  CANDIDATE_BUILD_NUMBERS="300 299 298" EXPECTED_SOURCE=schedule CURRENT_EPOCH="${fixture_now}"
assert_contains "${OUTPUT_DIR}/reset_streak.out" "Burn-in progress:** 1/7"

completion_candidates=
for number in 400 401 402 403 404 405 406; do
  write_build "${number}" passed schedule 2026-01-01T01:30:00.000Z
  write_steps "${number}" passed passed 0
  completion_candidates="${completion_candidates} ${number}"
done
run_success completed_streak \
  CANDIDATE_BUILD_NUMBERS="${completion_candidates}" EXPECTED_SOURCE=schedule CURRENT_EPOCH="${fixture_now}"
assert_contains "${OUTPUT_DIR}/completed_streak.out" "Burn-in complete:** 7/7"

write_build 202 passed schedule 2026-01-01T01:30:00.000Z
write_steps 202 passed passed 1
run_failure retried_build \
  CANDIDATE_BUILD_NUMBERS=202 EXPECTED_SOURCE=schedule CURRENT_EPOCH="${fixture_now}"
assert_contains "${OUTPUT_DIR}/retried_build.out" "did not meet the clean-run criteria"

write_build 203 passed schedule 2026-01-01T01:30:00.000Z
write_steps 203 failed passed 0
run_failure failed_matrix \
  CANDIDATE_BUILD_NUMBERS=203 EXPECTED_SOURCE=schedule CURRENT_EPOCH="${fixture_now}"
assert_contains "${OUTPUT_DIR}/failed_matrix.out" '`failed 2/2 retries=0`'

write_build 204 passed schedule 2025-12-30T00:00:00.000Z
write_steps 204 passed passed 0
run_failure stale_build \
  CANDIDATE_BUILD_NUMBERS=204 EXPECTED_SOURCE=schedule CURRENT_EPOCH="${fixture_now}"
assert_contains "${OUTPUT_DIR}/stale_build.out" "outside the 20-hour freshness window"

write_build 205 passed schedule 2026-01-01T01:30:00.000Z
write_steps_without_rdma 205
run_failure missing_matrix \
  CANDIDATE_BUILD_NUMBERS=205 EXPECTED_SOURCE=schedule CURRENT_EPOCH="${fixture_now}"
assert_contains "${OUTPUT_DIR}/missing_matrix.out" '`missing`'

echo "Nightly monitor success and alert-path tests passed"
