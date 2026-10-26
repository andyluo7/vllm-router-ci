#!/usr/bin/env bash
# ACTIONS_RUNNER_HOOK_JOB_COMPLETED: the host-lease holder follows the
# Runner.Worker process and releases automatically after this hook returns.

set -u

if sudo -n /opt/actions-runner/hooks/clean-temp.sh; then
  echo "emptied the runner's _temp"
else
  echo "::warning::could not empty the runner's _temp"
fi
