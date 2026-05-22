#!/usr/bin/env bash
# tofu-runner.sh
# Universal wrapper for Cloud Build OpenTofu steps.

set +e

COMMAND=$1
shift

# Default STATUS_TOKEN to GITHUB_TOKEN if not explicitly set
export STATUS_TOKEN="${STATUS_TOKEN:-$GITHUB_TOKEN}"

# Ensure required environment variables exist for status posting
if [ -z "${COMMIT_SHA:-}" ] || [ -z "${REPO_FULL_NAME:-}" ] || [ -z "${BUILD_URL:-}" ]; then
  echo "WARNING: COMMIT_SHA, REPO_FULL_NAME, or BUILD_URL is missing. Status reporting may fail."
fi

# Locate helper scripts (assuming they are in the same directory as tofu-runner)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source build-context.env if it exists (for backwards compatibility)
if [ -f "/workspace/build-context.env" ]; then
  source "/workspace/build-context.env"
fi

case "$COMMAND" in
  tflint)
    # Check if context is passed via args, e.g. --context=ci/tflint
    CONTEXT="ci/tflint"
    for arg in "$@"; do
      if [[ $arg == --context=* ]]; then CONTEXT="${arg#*=}"; fi
    done
    tflint --init 2>&1 | tee /workspace/tflint-output.txt
    EXIT_CODE=${PIPESTATUS[0]}
    echo $EXIT_CODE > /workspace/tflint.exit
    "${SCRIPT_DIR}/post-step-status.sh" tflint "$CONTEXT"
    exit $EXIT_CODE
    ;;

  fmt)
    CONTEXT="ci/fmt"
    for arg in "$@"; do
      if [[ $arg == --context=* ]]; then CONTEXT="${arg#*=}"; fi
    done
    tofu fmt -no-color -check 2>&1 | tee /workspace/fmt-output.txt
    EXIT_CODE=${PIPESTATUS[0]}
    echo $EXIT_CODE > /workspace/fmt.exit
    "${SCRIPT_DIR}/post-step-status.sh" fmt "$CONTEXT"
    exit $EXIT_CODE
    ;;

  init)
    CONTEXT="ci/init"
    PENDING_CONTEXTS=()
    for arg in "$@"; do
      if [[ $arg == --context=* ]]; then 
        CONTEXT="${arg#*=}"
      else
        PENDING_CONTEXTS+=("$arg")
      fi
    done
    tofu init -no-color 2>&1 | tee /workspace/init-output.txt
    EXIT_CODE=${PIPESTATUS[0]}
    echo $EXIT_CODE > /workspace/init.exit
    "${SCRIPT_DIR}/post-step-status.sh" init "$CONTEXT"

    if [[ "$EXIT_CODE" == "0" ]]; then
      # If no pending contexts were passed explicitly, default to ci/validate ci/plan
      if [ ${#PENDING_CONTEXTS[@]} -eq 0 ]; then
        PENDING_CONTEXTS=("ci/validate" "ci/plan")
      fi
      for ctx in "${PENDING_CONTEXTS[@]}"; do
        "${SCRIPT_DIR}/post-status.sh" \
          --state=pending \
          --context="${ctx}" \
          --description="waiting..." \
          --allow-failure
      done
    fi
    exit $EXIT_CODE
    ;;

  validate)
    CONTEXT="ci/validate"
    for arg in "$@"; do
      if [[ $arg == --context=* ]]; then CONTEXT="${arg#*=}"; fi
    done
    tofu validate -no-color 2>&1 | tee /workspace/validate-output.txt
    EXIT_CODE=${PIPESTATUS[0]}
    echo $EXIT_CODE > /workspace/validate.exit
    "${SCRIPT_DIR}/post-step-status.sh" validate "$CONTEXT"
    exit $EXIT_CODE
    ;;

  plan)
    CONTEXT="ci/plan"
    TOFU_ARGS=()
    for arg in "$@"; do
      if [[ $arg == --context=* ]]; then 
        CONTEXT="${arg#*=}"
      elif [[ $arg == --speculative ]]; then
        TOFU_ARGS+=("-lock=false")
      else
        TOFU_ARGS+=("$arg")
      fi
    done
    tofu plan -detailed-exitcode -no-color "${TOFU_ARGS[@]}" 2>&1 | tee /workspace/plan-output.txt
    EXIT_CODE=${PIPESTATUS[0]}
    echo $EXIT_CODE > /workspace/plan.exit
    "${SCRIPT_DIR}/post-step-status.sh" plan "$CONTEXT"
    [[ "$EXIT_CODE" == "0" || "$EXIT_CODE" == "2" ]] && exit 0 || exit "$EXIT_CODE"
    ;;

  apply)
    CONTEXT="cd/apply"
    TOFU_ARGS=()
    for arg in "$@"; do
      if [[ $arg == --context=* ]]; then 
        CONTEXT="${arg#*=}"
      else
        TOFU_ARGS+=("$arg")
      fi
    done

    if [[ -f "/workspace/plan.exit" ]] && [[ "$(cat /workspace/plan.exit)" == "0" ]]; then
      echo "Plan showed no changes — skipping apply."
      "${SCRIPT_DIR}/post-status.sh" \
        --state=success \
        --context="${CONTEXT}" \
        --description="no changes to apply" \
        --allow-failure
      exit 0
    fi

    tofu apply -no-color -auto-approve "${TOFU_ARGS[@]}" 2>&1 | tee /workspace/apply-output.txt
    EXIT_CODE=${PIPESTATUS[0]}
    echo $EXIT_CODE > /workspace/apply.exit
    "${SCRIPT_DIR}/post-step-status.sh" apply "$CONTEXT"
    exit $EXIT_CODE
    ;;

  pr-comment)
    "${SCRIPT_DIR}/tofu-pr-summary.sh"
    ;;

  gate)
    fail=0
    STEPS=("tflint" "fmt" "validate" "plan")
    if [ $# -gt 0 ]; then
      STEPS=("$@")
    fi

    for step in "${STEPS[@]}"; do
      f="/workspace/${step}.exit"
      if [ ! -f "$f" ]; then
        echo "WARNING: no exit file for step '${step}' — treating as failure."
        fail=1
        continue
      fi
      code=$(cat "$f")
      if [ "${step}" == "plan" ]; then
        if [[ "$code" != "0" && "$code" != "2" ]]; then
          echo "FAIL: ${step} exited ${code}"
          fail=1
        fi
      else
        if [ "$code" != "0" ]; then
          echo "FAIL: ${step} exited ${code}"
          fail=1
        fi
      fi
    done
    exit $fail
    ;;

  *)
    echo "Unknown command: $COMMAND"
    echo "Available commands: tflint, fmt, init, validate, plan, apply, pr-comment, gate"
    exit 1
    ;;
esac