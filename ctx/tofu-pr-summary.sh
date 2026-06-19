#!/usr/bin/env bash
# tofu-pr-summary.sh
#
# Posts a single consolidated PR comment summarising the outcome of all
# evaluative CI steps (tflint, fmt, validate, plan). Replaces any previous
# comment from this script using an HTML marker tag.
#
# Supports GitHub and Gitea.
#
# Environment (source /workspace/build-context.env before invoking):
#   PR_NUMBER        Pull request number (required)
#   REPO_FULL_NAME   Repository full name, e.g. jswank/gcp-sandbox-stigian (required)
#   BUILD_ID         Cloud Build build ID shown in the comment footer (required)
#   BUILD_URL        Cloud Build console URL for this build (required)
#
#   Token (one of the following is required):
#     PR_TOKEN       Explicit token for PR comment operations (highest priority)
#     STATUS_TOKEN   Generic API token used by post-status.sh; aliased from
#                    GITHUB_TOKEN by tofu-runner.sh when not set
#     GITHUB_TOKEN   GitHub token with issues:write permission
#
#   Platform selection (optional):
#     PR_PLATFORM    VCS platform: github | gitea (default: github)
#     STATUS_PLATFORM Same as PR_PLATFORM; used if PR_PLATFORM is unset
#     PR_HOST        Gitea base URL, e.g. https://git.example.com
#                    Required when platform is gitea.
#     STATUS_HOST    Same as PR_HOST; used if PR_HOST is unset
#
# Per-step workspace files (written by pr.yaml):
#   /workspace/{tflint,fmt,validate,plan}.exit       — exit code or "skipped"
#   /workspace/{tflint,fmt,validate,plan}-output.txt — captured stdout/stderr

set -euo pipefail

MARKER="<!-- cloud-build-tofu-ci -->"

###############################################################################
# Validate inputs / resolve platform
###############################################################################
if [[ -z "${PR_NUMBER:-}" ]]; then
  echo "PR_NUMBER not set — skipping comment."
  exit 0
fi

PR_PLATFORM="${PR_PLATFORM:-${STATUS_PLATFORM:-github}}"
PR_HOST="${PR_HOST:-${STATUS_HOST:-}}"
TOKEN="${PR_TOKEN:-${STATUS_TOKEN:-${GITHUB_TOKEN:-}}}"

if [[ -z "${TOKEN:-}" ]]; then
  echo "ERROR: No API token found. Set GITHUB_TOKEN, STATUS_TOKEN, or PR_TOKEN."
  exit 1
fi

if [[ -z "${REPO_FULL_NAME:-}" ]]; then
  echo "ERROR: REPO_FULL_NAME is not set."
  exit 1
fi

case "${PR_PLATFORM}" in
  github)
    API_BASE="https://api.github.com/repos/${REPO_FULL_NAME}"
    ;;
  gitea)
    if [[ -z "${PR_HOST}" ]]; then
      echo "ERROR: PR_HOST (or STATUS_HOST) is required for --platform=gitea."
      exit 1
    fi
    API_BASE="${PR_HOST%/}/api/v1/repos/${REPO_FULL_NAME}"
    ;;
  *)
    echo "ERROR: PR_PLATFORM must be 'github' or 'gitea'."
    exit 1
    ;;
esac

###############################################################################
# Helpers
###############################################################################

# Read exit code for a step; return "skipped" if the file is missing.
read_exit() {
  local file="/workspace/${1}.exit"
  if [[ ! -f "$file" ]]; then
    echo "skipped"
  else
    cat "$file"
  fi
}

# Return a status badge string for a step's exit code.
status_badge() {
  case "$1" in
    0)        echo "✅ \`success\`" ;;
    skipped)  echo "⏭ \`skipped\`" ;;
    *)        echo "❌ \`failure\`" ;;
  esac
}

# Return a collapsible <details> block for a step's output, or empty string.
# Only emitted on failure to keep the comment compact on green runs.
failure_details() {
  local label="$1"
  local step="$2"
  local code="$3"
  local outfile="/workspace/${step}-output.txt"

  [[ "$code" == "0" || "$code" == "skipped" ]] && return 0
  [[ ! -f "$outfile" ]] && return 0

  local output
  output=$(sed 's/\x1b\[[0-9;]*m//g' "$outfile")

  printf '<details><summary>%s output</summary>\n\n```\n%s\n```\n</details>\n' \
    "$label" "$output"
}

# Return a formatted plan block (success or failure).
# Mirrors the output formatting in the original tofu-pr.sh.
plan_block() {
  local code="$1"
  local outfile="/workspace/plan-output.txt"

  [[ "$code" == "skipped" ]] && return 0
  [[ ! -f "$outfile" ]] && return 0

  local input
  input=$(sed 's/\x1b\[[0-9;]*m//g' "$outfile")

  if [[ "$code" == "0" || "$code" == "2" ]]; then
    local clean
    # Strip the refresh section; keep from the execution plan header onward.
    clean=$(echo "$input" | sed -r '/^(An execution plan has been generated and is shown below\.|Terraform used the selected providers to generate the following execution|OpenTofu used the selected providers to generate the following execution|No changes\. Infrastructure is up-to-date\.|No changes\. Your infrastructure matches the configuration\.|Note: Objects have changed outside of Terraform)$/,$!d')
    # Truncate at the plan summary line.
    clean=$(echo "$clean" | sed -r '/^Plan: /q')
    # GitHub/Gitea comment limit — leave headroom for wrapper.
    clean="${clean::65000}"
    # Move diff characters to the start of the line for diff colouring.
    clean=$(echo "$clean" | sed -r 's/^([[:blank:]]*)([-+~])/\2\1/g')
    clean=$(echo "$clean" | sed -r 's/^~/!/g')

    printf '<details open><summary>Show Plan</summary>\n\n```diff\n%s\n```\n</details>\n' "$clean"
  else
    printf '<details><summary>Plan output</summary>\n\n```\n%s\n```\n</details>\n' "$input"
  fi
}

# Make an authenticated API request and return the HTTP response code.
# Response body is written to $RESP_FILE.
api_call() {
  local method="$1"
  local url="$2"
  local resp_file="$3"
  local payload_file="${4:-}"

  local headers=(-H "Authorization: token ${TOKEN}")
  if [[ "${PR_PLATFORM}" == "github" ]]; then
    headers+=(-H "Accept: application/vnd.github+json")
  fi

  local curl_opts=(
    -s
    -o "${resp_file}"
    -w "%{http_code}"
    -X "${method}"
    "${headers[@]}"
  )

  if [[ -n "${payload_file}" ]]; then
    curl_opts+=(-H "Content-Type: application/json" --data-binary "@${payload_file}")
  fi

  curl "${curl_opts[@]}" "${url}"
}

###############################################################################
# Collect step results
###############################################################################
TFLINT_CODE=$(read_exit tflint)
FMT_CODE=$(read_exit fmt)
VALIDATE_CODE=$(read_exit validate)
PLAN_CODE=$(read_exit plan)

TFLINT_BADGE=$(status_badge "$TFLINT_CODE")
FMT_BADGE=$(status_badge "$FMT_CODE")
VALIDATE_BADGE=$(status_badge "$VALIDATE_CODE")
PLAN_BADGE=$(status_badge "$PLAN_CODE")

TFLINT_DETAILS=$(failure_details "TFLint"   tflint   "$TFLINT_CODE")
FMT_DETAILS=$(failure_details    "Format"   fmt      "$FMT_CODE")
VALIDATE_DETAILS=$(failure_details "Validate" validate "$VALIDATE_CODE")
PLAN_DETAILS=$(plan_block "$PLAN_CODE")

BUILD_LABEL="${BUILD_ID}"

###############################################################################
# Assemble comment body
###############################################################################
BODY="${MARKER}

#### TFLint ${TFLINT_BADGE}
${TFLINT_DETAILS}

#### TF Format ${FMT_BADGE}
${FMT_DETAILS}

#### TF Validate ${VALIDATE_BADGE}
${VALIDATE_DETAILS}

#### TF Plan ${PLAN_BADGE}
${PLAN_DETAILS}

*Build: [${BUILD_LABEL}](${BUILD_URL})*"

###############################################################################
# Replace previous CI comment via the platform API
###############################################################################
echo "Repo: ${REPO_FULL_NAME}  PR: ${PR_NUMBER}  Platform: ${PR_PLATFORM}"

LIST_URL="${API_BASE}/issues/${PR_NUMBER}/comments?per_page=100&limit=100"
COMMENTS_FILE="/tmp/pr_summary_comments.json"

HTTP_CODE=$(api_call GET "${LIST_URL}" "${COMMENTS_FILE}")
if [[ ! "${HTTP_CODE}" =~ ^2 ]]; then
  echo "ERROR: Failed to list comments (HTTP ${HTTP_CODE})." >&2
  cat "${COMMENTS_FILE}" >&2
  exit 1
fi

OLD_ID=$(jq -r --arg marker "$MARKER" 'map(select(.body | contains($marker))) | first | .id // empty' "${COMMENTS_FILE}")

PAYLOAD_FILE="/tmp/pr_summary_payload.json"
jq -n --arg body "$BODY" '{body: $body}' > "${PAYLOAD_FILE}"

RESPONSE_FILE="/tmp/pr_summary_response.json"

if [[ -n "${OLD_ID}" ]]; then
  echo "Updating existing comment ${OLD_ID}."
  UPDATE_URL="${API_BASE}/issues/comments/${OLD_ID}"
  HTTP_CODE=$(api_call PATCH "${UPDATE_URL}" "${RESPONSE_FILE}" "${PAYLOAD_FILE}")
else
  echo "Posting new PR comment..."
  CREATE_URL="${API_BASE}/issues/${PR_NUMBER}/comments"
  HTTP_CODE=$(api_call POST "${CREATE_URL}" "${RESPONSE_FILE}" "${PAYLOAD_FILE}")
fi

if [[ "${HTTP_CODE}" =~ ^2 ]]; then
  echo "Comment posted (HTTP ${HTTP_CODE})."
else
  echo "ERROR: Failed to post comment (HTTP ${HTTP_CODE})." >&2
  cat "${RESPONSE_FILE}" >&2
  exit 1
fi
