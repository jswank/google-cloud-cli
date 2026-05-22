# Cloud Build Environment Variables

The following environment variables are available in every Cloud Build step
container. Both pipelines set `options.automapSubstitutions: true`, which
automatically maps all substitution variables to environment variables. No
explicit `env:` declaration is required in the build config yaml.

## Built-in Substitutions

Always present.

- `PROJECT_ID` — GCP project ID (e.g. `sandbox-jason-7023`)
- `PROJECT_NUMBER` — GCP project number
- `BUILD_ID` — unique ID for this build run
- `LOCATION` — build region (e.g. `us-east5`)
- `TRIGGER_NAME` — name of the Cloud Build trigger

## Source-Dependent Substitutions

Present for repository-triggered builds.

- `COMMIT_SHA` — full commit SHA
- `SHORT_SHA` — first 7 characters of `COMMIT_SHA`
- `REVISION_ID` — same as `COMMIT_SHA`
- `REPO_NAME` — repository name (e.g. `gcp-sandbox-jason`)
- `REPO_FULL_NAME` — full repository name (e.g. `jswank/gcp-sandbox-jason`)
- `BRANCH_NAME` — branch name (push triggers)
- `TAG_NAME` — tag name (tag triggers)

Reference: [Cloud Build default substitutions](https://cloud.google.com/build/docs/configuring-builds/substitute-variable-values#using_default_substitutions)

## User-Defined Substitutions

Set in trigger configuration.

- `_PR_NUMBER` — pull request number (`pr.yaml` trigger only)

## Derived Variables

Not Cloud Build built-ins. `tofu-runner.sh` computes these from the above
before invoking any sub-command or helper script.

- `BUILD_URL` — full Cloud Build console URL for this build, constructed as:
  `https://console.cloud.google.com/cloud-build/builds;region=${LOCATION}/${BUILD_ID}?project=${PROJECT_ID}`
- `PR_NUMBER` — pull request number, remapped from `$_PR_NUMBER`. Empty string
  when not running in a PR context (`apply.yaml`).

## Secrets

Injected via `secretEnv` in the build config, not substitutions.

- `GITHUB_TOKEN` — GitHub token sourced from Secret Manager per build step.
  Aliased to `STATUS_TOKEN` by `tofu-runner.sh` for status posting.
