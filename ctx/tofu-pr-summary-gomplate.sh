#!/usr/bin/env bash
# tofu-pr-summary-gomplate.sh
#
# Posts a single consolidated PR comment summarizing the outcome of all
# evaluative CI steps using the pr-summary.md.tmpl gomplate template.
#
# Environment (source /workspace/build-context.env before invoking):
#   GITHUB_TOKEN     GitHub token with issues:write permission (required)
#   PR_NUMBER        Pull request number (required)
#   REPO_FULL_NAME   Repository full name, e.g. jswank/gcp-sandbox-stigian (required)
#   BUILD_ID         Cloud Build build ID shown in the comment footer (required)
#   BUILD_URL        Cloud Build console URL for this build (required)
#   WORKSPACE_DIR    Directory containing step exit codes and output files (default: /workspace)

set -euo pipefail

MARKER="<!-- cloud-build-tofu-ci -->"
export WORKSPACE_DIR="${WORKSPACE_DIR:-/workspace}"

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

# Locate templates directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEMPLATE_PATH="${SCRIPT_DIR}/templates/pr-summary.md.tmpl"

if [[ ! -f "${TEMPLATE_PATH}" ]]; then
  echo "ERROR: Template not found at ${TEMPLATE_PATH}"
  exit 1
fi

###############################################################################
# Assemble comment body using gomplate
###############################################################################
echo "Generating PR comment markdown using gomplate..."
BODY=$(WORKSPACE_DIR="${WORKSPACE_DIR}" gomplate -f "${TEMPLATE_PATH}")

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
