#!/usr/bin/env bash
# tofu-pr-summary.sh
#
# Posts a single consolidated PR comment summarising the outcome of all
# evaluative CI steps (tflint, fmt, validate, plan). Replaces any previous
# comment from this script using an HTML marker tag.
#
# Environment (source /workspace/build-context.env before invoking):
#   GITHUB_TOKEN     GitHub token with issues:write permission (required)
#   PR_NUMBER        Pull request number (required)
#   REPO_FULL_NAME   Repository full name, e.g. jswank/gcp-sandbox-stigian (required)
#   BUILD_ID         Cloud Build build ID shown in the comment footer (required)
#   BUILD_URL        Cloud Build console URL for this build (required)
#
# Per-step workspace files (written by pr.yaml):
#   /workspace/{tflint,fmt,validate,plan}.exit       — exit code or "skipped"
#   /workspace/{tflint,fmt,validate,plan}-output.txt — captured stdout/stderr

set -euo pipefail

MARKER="<!-- cloud-build-tofu-ci -->"

###############################################################################
# Validate inputs
###############################################################################
if [[ -z "${PR_NUMBER:-}" ]]; then
  echo "PR_NUMBER not set — skipping comment."
  exit 0
fi

if [[ -z "${GITHUB_TOKEN:-}" ]]; then
  echo "GITHUB_TOKEN not set — cannot post comment."
  exit 1
fi

REPO="${REPO_FULL_NAME}"
export GH_TOKEN="${GITHUB_TOKEN}"

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
    # GitHub comment limit — leave headroom for wrapper.
    clean="${clean::65000}"
    # Move diff characters to the start of the line for GitHub diff colouring.
    clean=$(echo "$clean" | sed -r 's/^([[:blank:]]*)([-+~])/\2\1/g')
    clean=$(echo "$clean" | sed -r 's/^~/!/g')

    printf '<details open><summary>Show Plan</summary>\n\n```diff\n%s\n```\n</details>\n' "$clean"
  else
    printf '<details><summary>Plan output</summary>\n\n```\n%s\n```\n</details>\n' "$input"
  fi
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
# Replace previous CI comment via gh CLI
###############################################################################
echo "Repo: ${REPO}  PR: ${PR_NUMBER}"

echo "Looking for an existing CI comment..."
OLD_ID=$(gh api "repos/${REPO}/issues/${PR_NUMBER}/comments" \
  | jq -r --arg marker "$MARKER" 'map(select(.body | contains($marker))) | first | .id // empty')

if [[ -n "$OLD_ID" ]]; then
  echo "Updating existing comment ${OLD_ID}."
  gh api -X PATCH "repos/${REPO}/issues/comments/${OLD_ID}" \
    -f body="$BODY" > /dev/null
else
  echo "Posting new PR comment..."
  gh api "repos/${REPO}/issues/${PR_NUMBER}/comments" \
    -f body="$BODY" > /dev/null
fi

echo "Done."
