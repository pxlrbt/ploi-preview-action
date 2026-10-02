# shellcheck shell=bash
# Everything that is written back to GitHub, through the gh CLI that every runner ships with.

# Hidden first line of the pull request comment, so later runs find and update it.
COMMENT_MARKER='<!-- ploi-preview -->'

# upsert_comment PULL_REQUEST TEXT – creates the preview comment, or updates the existing one
upsert_comment() {
  local pull_request=$1
  local body="$COMMENT_MARKER"$'\n'"$2"
  local comment_id

  if [[ $DRY_RUN == true ]]; then
    echo "[dry-run] comment on #$pull_request"
    return
  fi

  comment_id=$(gh api "repos/$GITHUB_REPOSITORY/issues/$pull_request/comments" --paginate \
    --jq ".[] | select(.body | startswith(\"$COMMENT_MARKER\")) | .id" | head -n1)

  if [[ -n $comment_id ]]; then
    gh api -X PATCH "repos/$GITHUB_REPOSITORY/issues/comments/$comment_id" -f body="$body" >/dev/null
  else
    gh api "repos/$GITHUB_REPOSITORY/issues/$pull_request/comments" -f body="$body" >/dev/null
  fi
}

# create_deployment COMMIT_SHA URL – shows the preview link in the pull request's deployment box
create_deployment() {
  local deployment_id

  if [[ $DRY_RUN == true ]]; then
    return
  fi

  deployment_id=$(jq -n \
    --arg ref "$1" \
    --arg environment "preview-$SLUG" \
    '{ref: $ref, environment: $environment, auto_merge: false, required_contexts: [], transient_environment: true}' \
    | gh api "repos/$GITHUB_REPOSITORY/deployments" --input - --jq .id)

  gh api "repos/$GITHUB_REPOSITORY/deployments/$deployment_id/statuses" \
    -f state=success -f environment_url="$2" >/dev/null
}

# Marks the deployments of the preview SLUG as no longer active.
deactivate_deployments() {
  local deployment_id

  if [[ $DRY_RUN == true ]]; then
    return
  fi

  for deployment_id in $(gh api "repos/$GITHUB_REPOSITORY/deployments?environment=preview-$SLUG" --jq '.[].id'); do
    gh api "repos/$GITHUB_REPOSITORY/deployments/$deployment_id/statuses" -f state=inactive >/dev/null
  done
}

# list_open_pull_requests – one line per open pull request: its number, a tab, its branch
list_open_pull_requests() {
  gh pr list --repo "$GITHUB_REPOSITORY" --state open --limit 1000 \
    --json number,headRefName \
    --jq '.[] | [.number, .headRefName] | @tsv'
}
