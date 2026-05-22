#!/usr/bin/env bash
# post-step-status.sh
#
# Posts a commit status to GitHub for a single evaluative build step.
# Reads build context from environment variables (exported by sourcing
# /workspace/build-context.env in the calling step or script).
#
# Usage:
#   . /workspace/build-context.env
#   STATUS_TOKEN="..." ./scripts/post-step-status.sh <step> <context>
#
# Arguments:
#   step:    Build step name: tflint | fmt | validate | plan
#   context: GitHub status context string, e.g. ci/tflint
#
# Environment:
#   COMMIT_SHA        Full commit SHA
#   REPO_FULL_NAME    Repository full name, e.g. jswank/gcp-sandbox-stigian
#   BUILD_URL         Cloud Build console URL for this build
#   STATUS_TOKEN      GitHub API token with repo:status scope

set -euo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly POST_STATUS="${SCRIPT_DIR}/post-status.sh"

#######################################
# Reads the exit code for a given build step.
# Globals:
#   None
# Arguments:
#   step: Name of the build step (e.g. tflint, plan)
# Outputs:
#   Writes the numeric exit code or "skipped" to stdout.
# Returns:
#   0 always.
#######################################
read_exit() {
  local file="/workspace/${1}.exit"
  [[ -f "${file}" ]] && cat "${file}" || echo "skipped"
}

#######################################
# Maps a step name and exit code to a Commit Status API state string.
# Handles tofu plan exit code 2 (success with changes) as success.
# Globals:
#   None
# Arguments:
#   step: Name of the build step.
#   code: Numeric exit code or "skipped".
# Outputs:
#   Writes the state string to stdout.
# Returns:
#   0 always.
#######################################
to_state() {
  local step="${1}" code="${2}"
  [[ "${code}" == "skipped" ]] && echo "error" && return
  [[ "${code}" == "0" || ("${step}" == "plan" && "${code}" == "2") ]] && echo "success" && return
  echo "failure"
}

#######################################
# Removes ANSI colour escape sequences from stdin.
# Globals:
#   None
# Arguments:
#   None
# Outputs:
#   Writes stripped text to stdout.
# Returns:
#   0 always.
#######################################
strip_ansi() {
  sed 's/\x1b\[[0-9;]*m//g'
}

#######################################
# Counts the number of lines matching a regex in a file.
# Globals:
#   None
# Arguments:
#   file: Path to the file to check.
#   regex: Extended regular expression to match.
# Outputs:
#   Writes the match count to stdout.
# Returns:
#   0 always.
#######################################
count_matches() {
  local file="$1" regex="$2"
  [[ -f "${file}" ]] && (grep -cE "${regex}" "${file}" || true) || echo 0
}

#######################################
# Extracts the first line matching a regex from a file, minus ANSI codes.
# Returns a fallback string if the file doesn't exist or doesn't match.
# Globals:
#   None
# Arguments:
#   file: Path to the file to check.
#   regex: Extended regular expression to match.
#   fallback: String to return if no match is found.
# Outputs:
#   Writes the matched line or fallback to stdout.
# Returns:
#   0 always.
#######################################
extract_summary() {
  local file="$1" regex="$2" fallback="$3"
  if [[ -f "${file}" ]]; then
    local match
    match=$(strip_ansi < "${file}" | grep -m1 -E "${regex}" || true)
    echo "${match:-${fallback}}"
  else
    echo "${fallback}"
  fi
}

#######################################
# Produces a short status description based on the step and exit code.
# Globals:
#   None
# Arguments:
#   step: Name of the build step (tflint|fmt|init|validate|plan|apply).
#   code: Numeric exit code or "skipped".
# Outputs:
#   Writes description string to stdout.
# Returns:
#   0 always.
#######################################
describe() {
  local step="${1}" code="${2}" count=0
  
  if [[ "${code}" == "skipped" ]]; then
    echo "step did not run"
    return
  fi

  local success=false
  [[ "${code}" == "0" || ("${step}" == "plan" && "${code}" == "2") ]] && success=true

  case "${step}" in
    tflint)
      ${success} && echo "passed" && return
      count=$(count_matches "/workspace/tflint-output.txt" '\.(tf|tfvars):[0-9]+')
      [[ "${count}" -gt 0 ]] && echo "${count} issue(s) found" || echo "issues found"
      ;;
    fmt)
      ${success} && echo "all files formatted" && return
      count=$(count_matches "/workspace/fmt-output.txt" '[^[:space:]]')
      [[ "${count}" -gt 0 ]] && echo "${count} file(s) need formatting" || echo "formatting issues found"
      ;;
    init)
      ${success} && echo "initialized successfully" || echo "initialization failed"
      ;;
    validate)
      ${success} && echo "configuration is valid" || echo "configuration is invalid"
      ;;
    plan)
      ${success} && extract_summary "/workspace/plan-output.txt" '^(Plan:|No changes\.)' "plan succeeded" && return
      echo "plan failed"
      ;;
    apply)
      ${success} && extract_summary "/workspace/apply-output.txt" '^Apply complete!' "applied successfully" && return
      echo "apply failed"
      ;;
  esac
}

#######################################
# Validates environment, resolves step outcome, and posts the commit status.
# Globals:
#   BUILD_URL
#   COMMIT_SHA
#   POST_STATUS
#   REPO_FULL_NAME
#   STATUS_TOKEN
# Arguments:
#   step: Build step name (tflint|fmt|validate|plan|apply)
#   context: GitHub status context string (e.g. ci/tflint)
# Outputs:
#   Progress messages to stdout.
# Returns:
#   0 always (errors suppressed via --allow-failure in post-status.sh)
#######################################
main() {
  local step="${1:?step argument is required}"
  local context="${2:?context argument is required}"

  : "${COMMIT_SHA:?is not set — source /workspace/build-context.env}"
  : "${REPO_FULL_NAME:?is not set — source /workspace/build-context.env}"
  : "${BUILD_URL:?is not set — source /workspace/build-context.env}"
  : "${STATUS_TOKEN:?is not set}"

  local code state description
  code=$(read_exit "${step}")
  state=$(to_state "${step}" "${code}")
  description=$(describe "${step}" "${code}")

  echo "--- ${context}: exit=${code} state=${state} description='${description}'"

  "${POST_STATUS}" \
    --state="${state}" \
    --context="${context}" \
    --description="${description}" \
    --allow-failure
}

main "$@"