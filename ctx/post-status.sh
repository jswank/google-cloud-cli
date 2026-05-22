#!/usr/bin/env bash
# post-status.sh
#
# Posts a single commit status to GitHub or Gitea via the Commit Status API.
#
# Usage:
#   post-status.sh [flags]
#
# Environment (values sourced from /workspace/build-context.env by the caller):
#   STATUS_TOKEN      API token with repo:status scope (GitHub) or
#                     write:repository scope (Gitea). Required; no default.
#   REPO_FULL_NAME    Default for --repo
#   COMMIT_SHA        Default for --sha
#   BUILD_URL         Default for --target-url
#   STATUS_PLATFORM   Default for --platform (fallback: github)
#   STATUS_HOST       Default for --host (Gitea only)
#
# Required flags (no environment default):
#   --state=STRING            One of: pending success failure error warning
#   --context=STRING          Status context name (e.g. ci/tflint)
#   --description=STRING      Short plain-text description; truncated to 140 chars
#
# Optional flags (override environment defaults):
#   --platform=github|gitea   VCS platform
#   --repo=OWNER/REPO         Repository full name
#   --sha=SHA                 Full commit SHA
#   --target-url=URL          Link attached to the status
#   --host=URL                Gitea base URL (required when platform=gitea)
#   --allow-failure           Always exit 0, even on API or transport error
#   --dry-run                 Print the resolved URL and payload without POSTing

set -euo pipefail

# allow_failure is a script-level global so finish(), defined at script scope,
# can read it regardless of where it is set during flag parsing inside main().
allow_failure=false

########################################
# Exits the script with the given code, or exits 0 if allow_failure is true.
# Globals:
#   allow_failure
# Arguments:
#   code: Integer exit code
# Outputs:
#   Warning message to stderr when an error is suppressed
# Returns:
#   Exits with the supplied code, or 0 when allow_failure is true
########################################
finish() {
  local code="$1"
  if [[ "${allow_failure}" == "true" && "${code}" != "0" ]]; then
    echo "WARNING: post-status.sh failed (would exit ${code})" \
      "but --allow-failure is set; suppressing." >&2
    exit 0
  fi
  exit "${code}"
}

########################################
# Prints an error message to stderr and exits with code 2.
# Globals:
#   allow_failure (via finish)
# Arguments:
#   message: Error description string
# Outputs:
#   Error message to stderr
# Returns:
#   Exits 2, or 0 when allow_failure is true
########################################
usage_error() {
  echo "ERROR: $*" >&2
  finish 2
}

########################################
# Parses flags, validates inputs, constructs the request, and posts the
# commit status to GitHub or Gitea.
# Globals:
#   allow_failure
#   STATUS_TOKEN
# Arguments:
#   $@: Script flags (see file header for full list)
# Outputs:
#   Progress messages to stdout; errors to stderr
# Returns:
#   0 on success; exits non-zero on failure (subject to allow_failure)
########################################
main() {
  # Defaults from environment; flags below may override.
  local platform="${STATUS_PLATFORM:-github}"
  local host="${STATUS_HOST:-}"
  local repo="${REPO_FULL_NAME:-}"
  local sha="${COMMIT_SHA:-}"
  local state=""
  local context=""
  local description=""
  local target_url="${BUILD_URL:-}"
  local dry_run=false

  for arg in "$@"; do
    case "${arg}" in
      --platform=*)    platform="${arg#*=}" ;;
      --host=*)        host="${arg#*=}" ;;
      --repo=*)        repo="${arg#*=}" ;;
      --sha=*)         sha="${arg#*=}" ;;
      --state=*)       state="${arg#*=}" ;;
      --context=*)     context="${arg#*=}" ;;
      --description=*) description="${arg#*=}" ;;
      --target-url=*)  target_url="${arg#*=}" ;;
      --allow-failure) allow_failure=true ;;
      --dry-run)       dry_run=true ;;
      *) echo "ERROR: Unknown flag: ${arg}" >&2; exit 2 ;;
    esac
  done

  [[ -z "${platform}" ]]    && usage_error "--platform is required (or set STATUS_PLATFORM)"
  [[ -z "${repo}" ]]        && usage_error "--repo is required (or set REPO_FULL_NAME)"
  [[ -z "${sha}" ]]         && usage_error "--sha is required (or set COMMIT_SHA)"
  [[ -z "${state}" ]]       && usage_error "--state is required"
  [[ -z "${context}" ]]     && usage_error "--context is required"
  [[ -z "${description}" ]] && usage_error "--description is required"
  [[ -z "${target_url}" ]]  && usage_error "--target-url is required (or set BUILD_URL)"

  case "${platform}" in
    github) ;;
    gitea)
      [[ -z "${host}" ]] && usage_error "--host is required for --platform=gitea"
      ;;
    *)
      usage_error "--platform must be 'github' or 'gitea'"
      ;;
  esac

  case "${state}" in
    pending|success|failure|error|warning) ;;
    *)
      usage_error "--state must be one of: pending success failure error warning"
      ;;
  esac

  if [[ -z "${STATUS_TOKEN:-}" ]]; then
    usage_error "STATUS_TOKEN environment variable is not set"
  fi

  local url
  case "${platform}" in
    github) url="https://api.github.com/repos/${repo}/statuses/${sha}" ;;
    gitea)  url="${host%/}/api/v1/repos/${repo}/statuses/${sha}" ;;
  esac
  readonly url

  if [[ "${#description}" -gt 140 ]]; then
    description="${description:0:137}..."
  fi

  local payload
  payload=$(jq -n \
    --arg state       "${state}" \
    --arg context     "${context}" \
    --arg description "${description}" \
    --arg target_url  "${target_url}" \
    '{state: $state, context: $context, description: $description, target_url: $target_url}')
  readonly payload

  if [[ "${dry_run}" == "true" ]]; then
    echo "[dry-run] POST ${url}"
    echo "[dry-run] Payload: ${payload}"
    exit 0
  fi

  echo "Posting '${state}' for context '${context}' on ${sha:0:8} ..."

  local http_code
  http_code=$(curl -s \
    -o /tmp/post_status_response.json \
    -w "%{http_code}" \
    -X POST \
    -H "Authorization: token ${STATUS_TOKEN}" \
    -H "Content-Type: application/json" \
    -H "Accept: application/vnd.github+json" \
    -d "${payload}" \
    "${url}")

  if [[ "${http_code}" =~ ^2 ]]; then
    echo "Status posted (HTTP ${http_code})."
    finish 0
  else
    echo "ERROR: API returned HTTP ${http_code}." >&2
    cat /tmp/post_status_response.json >&2
    echo >&2
    finish 1
  fi
}

main "$@"
