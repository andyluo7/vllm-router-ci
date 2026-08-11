#!/usr/bin/env bash

set -Eeuo pipefail

BUILDKITE_PIPELINE_URL=${BUILDKITE_PIPELINE_URL:-https://buildkite.com/vllm/router}
BUILD_MESSAGE=${BUILD_MESSAGE:-Nightly ROCm MoRI XGMI/RDMA validation on 2×MI300X}
EXPECTED_SOURCE=${EXPECTED_SOURCE:-schedule}
MAX_SEARCH_PAGES=${MAX_SEARCH_PAGES:-10}
LATEST_MAX_AGE_HOURS=${LATEST_MAX_AGE_HOURS:-20}
BURN_IN_TARGET=${BURN_IN_TARGET:-7}
BUILD_NUMBER=${BUILD_NUMBER:-}
CANDIDATE_BUILD_NUMBERS=${CANDIDATE_BUILD_NUMBERS:-}
BUILDKITE_FIXTURE_DIR=${BUILDKITE_FIXTURE_DIR:-}
CURRENT_EPOCH=${CURRENT_EPOCH:-}
REQUIRED_UPSTREAM_PRS=${REQUIRED_UPSTREAM_PRS:-}
UPSTREAM_PULLS_API_URL=${UPSTREAM_PULLS_API_URL:-https://api.github.com/repos/vllm-project/router/pulls}
PREREQUISITE_GRACE_HOURS=${PREREQUISITE_GRACE_HOURS:-30}

require_command() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "ERROR: required command is not installed: $1" >&2
    exit 2
  fi
}

require_command curl
require_command jq

for numeric_setting in \
  MAX_SEARCH_PAGES \
  LATEST_MAX_AGE_HOURS \
  BURN_IN_TARGET \
  PREREQUISITE_GRACE_HOURS; do
  numeric_value=${!numeric_setting}
  if [[ ! "${numeric_value}" =~ ^[1-9][0-9]*$ ]]; then
    echo "ERROR: ${numeric_setting} must be a positive integer" >&2
    exit 2
  fi
done

if [[ -n "${CURRENT_EPOCH}" ]] && [[ ! "${CURRENT_EPOCH}" =~ ^[0-9]+$ ]]; then
  echo "ERROR: CURRENT_EPOCH must be an integer Unix timestamp" >&2
  exit 2
fi

if [[ -n "${BUILD_NUMBER}" ]] && [[ -n "${CANDIDATE_BUILD_NUMBERS}" ]]; then
  echo "ERROR: BUILD_NUMBER and CANDIDATE_BUILD_NUMBERS are mutually exclusive" >&2
  exit 2
fi

if [[ -n "${BUILDKITE_FIXTURE_DIR}" ]] && [[ ! -d "${BUILDKITE_FIXTURE_DIR}" ]]; then
  echo "ERROR: BUILDKITE_FIXTURE_DIR is not a directory" >&2
  exit 2
fi

tmp_dir=$(mktemp -d)
trap 'rm -rf "${tmp_dir}"' EXIT

declare -a candidate_builds=()
declare -a matching_builds=()
explicit_build=false

fetch_build_json() {
  local build_number=$1
  local destination=$2
  if [[ -n "${BUILDKITE_FIXTURE_DIR}" ]]; then
    cp "${BUILDKITE_FIXTURE_DIR}/build-${build_number}.json" "${destination}"
  else
    curl --fail --silent --show-error --location \
      "${BUILDKITE_PIPELINE_URL}/builds/${build_number}.json" >"${destination}"
  fi
}

fetch_steps_json() {
  local build_number=$1
  local destination=$2
  if [[ -n "${BUILDKITE_FIXTURE_DIR}" ]]; then
    cp "${BUILDKITE_FIXTURE_DIR}/steps-${build_number}.json" "${destination}"
  else
    curl --fail --silent --show-error --location \
      "${BUILDKITE_PIPELINE_URL}/builds/${build_number}/data/steps" >"${destination}"
  fi
}

fetch_pr_json() {
  local pr_number=$1
  local destination=$2
  if [[ -n "${BUILDKITE_FIXTURE_DIR}" ]]; then
    cp "${BUILDKITE_FIXTURE_DIR}/pr-${pr_number}.json" "${destination}"
  else
    curl --fail --silent --show-error --location \
      --header "Accept: application/vnd.github+json" \
      "${UPSTREAM_PULLS_API_URL}/${pr_number}" >"${destination}"
  fi
}

checked_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)

echo "## ROCm nightly burn-in"
echo
echo "- Checked: \`${checked_at}\`"
echo "- Pipeline: ${BUILDKITE_PIPELINE_URL}"
echo "- Required source: \`${EXPECTED_SOURCE}\`"
echo "- Required lanes: XGMI 2/2 and RDMA 2/2, passed with zero retries"
if [[ -z "${BUILD_NUMBER}" ]]; then
  echo "- Scheduled burn-in also requires zero retries across every command step"
fi
if [[ -n "${REQUIRED_UPSTREAM_PRS}" ]]; then
  echo "- Required upstream PRs: \`${REQUIRED_UPSTREAM_PRS}\`"
fi
echo

if [[ -n "${BUILD_NUMBER}" ]]; then
  if [[ ! "${BUILD_NUMBER}" =~ ^[0-9]+$ ]]; then
    echo "ERROR: BUILD_NUMBER must be numeric" >&2
    exit 2
  fi
  candidate_builds=("${BUILD_NUMBER}")
  explicit_build=true
elif [[ -n "${CANDIDATE_BUILD_NUMBERS}" ]]; then
  read -r -a candidate_builds <<<"${CANDIDATE_BUILD_NUMBERS}"
fi

prerequisite_cutoff_epoch=0
prerequisite_cutoff_at=
if [[ "${explicit_build}" == false ]] && [[ -n "${REQUIRED_UPSTREAM_PRS}" ]]; then
  read -r -a required_prs <<<"${REQUIRED_UPSTREAM_PRS}"
  waiting_prs=()
  for pr_number in "${required_prs[@]}"; do
    if [[ ! "${pr_number}" =~ ^[0-9]+$ ]]; then
      echo "ERROR: required upstream PR numbers must be numeric" >&2
      exit 2
    fi

    pr_file="${tmp_dir}/pr-${pr_number}.json"
    fetch_pr_json "${pr_number}" "${pr_file}"
    merged_at=$(jq -r '.merged_at // empty' "${pr_file}")
    if [[ -z "${merged_at}" ]]; then
      waiting_prs+=("#${pr_number}")
      continue
    fi

    merged_epoch=$(jq -nr --arg value "${merged_at}" '$value | sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601')
    if ((merged_epoch > prerequisite_cutoff_epoch)); then
      prerequisite_cutoff_epoch=${merged_epoch}
      prerequisite_cutoff_at=${merged_at}
    fi
  done

  if ((${#waiting_prs[@]} > 0)); then
    waiting_list=
    for waiting_pr in "${waiting_prs[@]}"; do
      if [[ -n "${waiting_list}" ]]; then
        waiting_list="${waiting_list}, "
      fi
      waiting_list="${waiting_list}${waiting_pr}"
    done
    prerequisite_label=prerequisite
    if ((${#waiting_prs[@]} > 1)); then
      prerequisite_label=prerequisites
    fi
    echo "**Waiting:** ${prerequisite_label} ${waiting_list} must merge before the seven-night burn-in starts."
    exit 0
  fi

  echo "- Burn-in eligibility begins after: \`${prerequisite_cutoff_at}\`"
  echo
fi

if [[ "${explicit_build}" == false ]] && ((${#candidate_builds[@]} == 0)); then
  for ((page = 1; page <= MAX_SEARCH_PAGES; page++)); do
    page_file="${tmp_dir}/builds-page-${page}.html"
    curl --fail --silent --show-error --location --get \
      --data-urlencode "query=${BUILD_MESSAGE}" \
      --data-urlencode "page=${page}" \
      "${BUILDKITE_PIPELINE_URL}/builds" >"${page_file}"

    page_builds=()
    while IFS= read -r page_build; do
      page_builds+=("${page_build}")
    done < <(
      sed -nE 's#.*href="/vllm/router/builds/([0-9]+)".*#\1#p' "${page_file}" | awk '!seen[$0]++'
    )
    if ((${#page_builds[@]} == 0)); then
      break
    fi
    candidate_builds+=("${page_builds[@]}")
  done
fi

for candidate_build in "${candidate_builds[@]}"; do
  if [[ ! "${candidate_build}" =~ ^[0-9]+$ ]]; then
    echo "ERROR: candidate build numbers must be numeric" >&2
    exit 2
  fi
done

if [[ "${explicit_build}" == false ]] && ((${#candidate_builds[@]} > 0)); then
  unique_candidates=()
  while IFS= read -r candidate_build; do
    unique_candidates+=("${candidate_build}")
  done < <(printf '%s\n' "${candidate_builds[@]}" | sort -rnu)
  candidate_builds=("${unique_candidates[@]}")
fi

for build_number in "${candidate_builds[@]}"; do
  build_file="${tmp_dir}/build-${build_number}.json"
  fetch_build_json "${build_number}" "${build_file}"

  build_created_at=$(jq -r '.created_at' "${build_file}")
  build_created_epoch=$(jq -nr --arg value "${build_created_at}" '$value | sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601')
  if [[ $(jq -r '.source' "${build_file}") == "${EXPECTED_SOURCE}" ]] && \
    [[ $(jq -r '.message' "${build_file}") == "${BUILD_MESSAGE}" ]] && \
    ((build_created_epoch > prerequisite_cutoff_epoch)); then
    matching_builds+=("${build_number}")
    if [[ "${explicit_build}" == false ]] && ((${#matching_builds[@]} >= BURN_IN_TARGET)); then
      break
    fi
  fi
done

if ((${#matching_builds[@]} == 0)); then
  if ((prerequisite_cutoff_epoch > 0)); then
    now_epoch=${CURRENT_EPOCH:-$(date -u +%s)}
    prerequisite_age_seconds=$((now_epoch - prerequisite_cutoff_epoch))
    prerequisite_grace_seconds=$((PREREQUISITE_GRACE_HOURS * 60 * 60))
    if ((prerequisite_age_seconds >= 0 && prerequisite_age_seconds <= prerequisite_grace_seconds)); then
      echo "**Waiting:** no scheduled build has started after the prerequisite merge cutoff; the first eligible nightly has not completed yet."
      exit 0
    fi
  fi
  echo "**ALERT:** No matching \`${EXPECTED_SOURCE}\` build was found for the configured nightly message."
  exit 1
fi

echo "| Build | Created (UTC) | Overall | XGMI | RDMA | All retries | Clean |"
echo "| --- | --- | --- | --- | --- | ---: | --- |"

consecutive_clean=0
streak_open=true
latest_clean=false
latest_created_at=

for build_number in "${matching_builds[@]}"; do
  build_file="${tmp_dir}/build-${build_number}.json"
  steps_file="${tmp_dir}/steps-${build_number}.json"
  fetch_steps_json "${build_number}" "${steps_file}"

  overall=$(jq -r '.state' "${build_file}")
  created_at=$(jq -r '.created_at' "${build_file}")
  xgmi=$(jq -r '
    [ .[]
      | select(.type == "command")
      | select((.label // "") | contains("ROCm MoRI XGMI"))
    ][0]
    | if . == null then "missing"
      else "\(.outcome // .state) \(.statistics.jobs_finished_count // 0)/\(.statistics.jobs_count // 0) retries=\(.statistics.retries_count // 0)"
      end
  ' "${steps_file}")
  rdma=$(jq -r '
    [ .[]
      | select(.type == "command")
      | select((.label // "") | contains("ROCm MoRI RDMA"))
    ][0]
    | if . == null then "missing"
      else "\(.outcome // .state) \(.statistics.jobs_finished_count // 0)/\(.statistics.jobs_count // 0) retries=\(.statistics.retries_count // 0)"
      end
  ' "${steps_file}")
  all_retries=$(jq '[.[] | select(.type == "command") | (.statistics.retries_count // 0)] | add // 0' "${steps_file}")

  clean=false
  if [[ "${overall}" == passed ]] && \
    [[ "${xgmi}" == "passed 2/2 retries=0" ]] && \
    [[ "${rdma}" == "passed 2/2 retries=0" ]] && \
    { [[ "${explicit_build}" == true ]] || [[ "${all_retries}" == 0 ]]; }; then
    clean=true
  fi

  if [[ -z "${latest_created_at}" ]]; then
    latest_created_at=${created_at}
    latest_clean=${clean}
  fi

  if [[ "${streak_open}" == true ]] && [[ "${clean}" == true ]]; then
    consecutive_clean=$((consecutive_clean + 1))
  elif [[ "${clean}" == false ]]; then
    # Builds are newest first. Once a failure breaks the current streak,
    # older passes must not extend it.
    streak_open=false
  fi

  if [[ "${clean}" == true ]]; then
    clean_cell="yes"
  else
    clean_cell="**no**"
  fi
  echo "| [#${build_number}](${BUILDKITE_PIPELINE_URL}/builds/${build_number}) | \`${created_at}\` | \`${overall}\` | \`${xgmi}\` | \`${rdma}\` | ${all_retries} | ${clean_cell} |"
done

if ((consecutive_clean > BURN_IN_TARGET)); then
  consecutive_clean=${BURN_IN_TARGET}
fi

echo
if [[ "${explicit_build}" == true ]]; then
  echo "Explicit-build validation checks the ROCm lanes, ignores retries in unrelated steps, and does not change the scheduled burn-in count."
elif ((consecutive_clean >= BURN_IN_TARGET)); then
  echo "**Burn-in complete:** ${BURN_IN_TARGET}/${BURN_IN_TARGET} consecutive scheduled runs are clean."
else
  echo "**Burn-in progress:** ${consecutive_clean}/${BURN_IN_TARGET} consecutive scheduled runs are clean."
fi

if [[ "${explicit_build}" == false ]]; then
  created_epoch=$(jq -nr --arg value "${latest_created_at}" '$value | sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601')
  now_epoch=${CURRENT_EPOCH:-$(date -u +%s)}
  age_seconds=$((now_epoch - created_epoch))
  max_age_seconds=$((LATEST_MAX_AGE_HOURS * 60 * 60))
  if ((age_seconds < 0 || age_seconds > max_age_seconds)); then
    echo
    echo "**ALERT:** Latest scheduled build is outside the ${LATEST_MAX_AGE_HOURS}-hour freshness window."
    exit 1
  fi
fi

if [[ "${latest_clean}" != true ]]; then
  echo
  echo "**ALERT:** Latest matching build did not meet the clean-run criteria."
  exit 1
fi

echo
echo "**Status:** latest matching build is healthy."
