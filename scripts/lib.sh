#!/usr/bin/env bash
# Shared helpers for the deploy and cleanup scripts.
set -euo pipefail
shopt -s inherit_errexit

DRY_RUN=${DRY_RUN:-false}
DB_PREFIX=${DB_PREFIX:-preview_}
SUBDOMAIN_STRATEGY=${SUBDOMAIN_STRATEGY:-branch}
SOURCE_SITE=${SOURCE_SITE:-}
SOURCE_DATABASE=
COMMENT_MARKER='<!-- ploi-preview -->'

die() {
  echo "::error::$*" >&2
  exit 1
}

notice() {
  echo "::notice::$*"
}

# event JQ_FILTER – a value from the GitHub event payload, empty when missing
event() {
  jq -r "$1 // empty" "$GITHUB_EVENT_PATH"
}

# require VARIABLE... – abort when the matching input is empty
require() {
  local name
  for name in "$@"; do
    if [[ -z ${!name:-} ]]; then
      die "Input '$(tr 'A-Z_' 'a-z-' <<<"$name")' is required."
    fi
  done
}

# Pull requests from forks get no secrets, so there is nothing to deploy or clean up.
skip_forks() {
  local head_repository
  head_repository=$(event .pull_request.head.repo.full_name)
  if [[ -n $head_repository && $head_repository != "$GITHUB_REPOSITORY" ]]; then
    notice "Pull requests from forks get no preview."
    exit 0
  fi
}

hash8() {
  printf %s "$1" | shasum | cut -c1-8
}

# slug BRANCH – DNS label for the branch. Kept short enough that <slug>.<domain>
# fits the 64 characters Let's Encrypt allows for a common name.
slug() {
  local branch=$1 max=$((63 - ${#DOMAIN})) slug
  if ((max < 20)); then max=20; fi
  slug=$(tr 'A-Z' 'a-z' <<<"$branch" | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//')
  if [[ $SUBDOMAIN_STRATEGY == hash || -z $slug ]]; then
    hash8 "$branch"
    return
  fi
  if ((${#slug} > max)); then
    slug=${slug:0:max-9}
    slug="${slug%-}-$(hash8 "$branch")"
  fi
  echo "$slug"
}

# db_name SLUG – doubles as the database user, hence MySQL's 32 character user limit
db_name() {
  local name="$DB_PREFIX${1//-/_}"
  if ((${#name} > 32)); then
    name="${name:0:23}_$(hash8 "$1")"
  fi
  echo "$name"
}

# preview_names SLUG – sets SLUG, PREVIEW_DOMAIN and DB_NAME, refusing anything that
# could address something other than a preview
preview_names() {
  SLUG=$1
  PREVIEW_DOMAIN="$SLUG.$DOMAIN"
  DB_NAME=$(db_name "$SLUG")
  if ((${#DB_PREFIX} < 3 || ${#DB_PREFIX} > 20)); then
    die "db-prefix must be 3 to 20 characters long."
  fi
  if [[ ! $SLUG =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ ]]; then
    die "Refusing unsafe preview name '$SLUG'."
  fi
  if [[ $PREVIEW_DOMAIN == "$SOURCE_SITE" ]]; then
    die "The preview domain $PREVIEW_DOMAIN is the source site."
  fi
  if [[ $DB_NAME != "$DB_PREFIX"* || $DB_NAME == "$SOURCE_DATABASE" ]]; then
    die "Refusing database name '$DB_NAME': it must carry the prefix and differ from the source site's database."
  fi
}

# set_env FILE KEY VALUE – replace or append one line of a .env file
set_env() {
  { grep -v "^$2=" "$1" || true; } >"$1.tmp"
  printf '%s=%s\n' "$2" "$3" >>"$1.tmp"
  mv "$1.tmp" "$1"
}

# ploi METHOD PATH [JSON] – prints the response body, fails on a non-2xx status
ploi() {
  local method=$1 path=$2 body=${3:-} response status attempt
  if [[ $DRY_RUN == true && $method != GET ]]; then
    echo "[dry-run] $method $path" >&2
    echo '{"data": {"id": 0}}'
    return
  fi
  for attempt in 1 2 3 4; do
    # shellcheck disable=SC2086
    response=$(curl -sS --max-time 120 -X "$method" "https://ploi.io/api$path" \
      -H "Authorization: Bearer $API_TOKEN" -H 'Accept: application/json' -H 'Content-Type: application/json' \
      ${body:+--data-binary @-} -w $'\n%{http_code}' <<<"$body")
    status=${response##*$'\n'}
    response=${response%$'\n'*}
    if [[ $status != 429 ]]; then break; fi
    sleep 30
  done
  if [[ $status != 2* ]]; then
    echo "::error::Ploi API $method $path failed ($status): $response" >&2
    return 1
  fi
  echo "$response"
}

# ploi_all PATH – every page of a list endpoint as one JSON array
ploi_all() {
  local page=1 response
  while :; do
    response=$(ploi GET "$1?per_page=50&page=$page")
    jq -c '.data[]' <<<"$response"
    if [[ $(jq -r '(.meta.last_page // 1) > (.meta.current_page // 1)' <<<"$response") != true ]]; then break; fi
    page=$((page + 1))
  done | jq -s .
}

# Turns a server name into its id.
resolve_server() {
  local id
  if [[ $SERVER =~ ^[0-9]+$ ]]; then return; fi
  id=$(ploi_all /servers | jq -r --arg name "$SERVER" 'map(select(.name == $name))[0].id // empty')
  if [[ -z $id ]]; then die "Ploi server '$SERVER' not found."; fi
  SERVER=$id
}

# find_site DOMAIN – the site as JSON, empty when it does not exist
find_site() {
  ploi_all "/servers/$SERVER/sites" | jq -c --arg domain "$1" 'map(select(.domain == $domain))[0] // empty'
}

find_database() {
  ploi_all "/servers/$SERVER/databases" | jq -c --arg name "$1" 'map(select(.name == $name))[0] // empty'
}

# Sets SOURCE_JSON, SOURCE_ID and SOURCE_DATABASE when a source site is configured.
load_source_site() {
  if [[ -z $SOURCE_SITE ]]; then return; fi
  SOURCE_JSON=$(find_site "$SOURCE_SITE")
  if [[ -z $SOURCE_JSON ]]; then die "Source site '$SOURCE_SITE' not found on the server."; fi
  SOURCE_ID=$(jq -r .id <<<"$SOURCE_JSON")
  SOURCE_DATABASE=$(ploi GET "/servers/$SERVER/sites/$SOURCE_ID/env" | jq -r .content | sed -n 's/^DB_DATABASE=//p' | tr -d "\"'" | tail -n1)
}

# is_preview SITE_ID – a site only counts as a preview while the prefixed database is linked to it
is_preview() {
  ploi_all "/servers/$SERVER/databases" \
    | jq -e --arg name "$DB_NAME" --argjson site "$1" 'any(.[]; .name == $name and .site.id == $site)' >/dev/null
}

# site_belongs_to_repository SITE_ID – true when the site was installed from this GitHub repository
site_belongs_to_repository() {
  ploi GET "/servers/$SERVER/sites/$1/repository" \
    | jq -r '.data.repository | "\(.user)/\(.name)", .name' | tr 'A-Z' 'a-z' \
    | grep -qxF "$(tr 'A-Z' 'a-z' <<<"$GITHUB_REPOSITORY")"
}

# wait_until SECONDS DESCRIPTION COMMAND... – poll every 5 seconds until COMMAND succeeds
wait_until() {
  local deadline=$((SECONDS + $1)) description=$2
  shift 2
  if [[ $DRY_RUN == true ]]; then return; fi
  until "$@"; do
    if ((SECONDS >= deadline)); then die "Timed out waiting for $description."; fi
    sleep 5
  done
}

# upsert_comment PULL_REQUEST BODY – one comment per pull request, updated in place
upsert_comment() {
  local body="$COMMENT_MARKER"$'\n'"$2" id
  if [[ $DRY_RUN == true ]]; then
    echo "[dry-run] comment on #$1"
    return
  fi
  id=$(gh api "repos/$GITHUB_REPOSITORY/issues/$1/comments" --paginate \
    --jq ".[] | select(.body | startswith(\"$COMMENT_MARKER\")) | .id" | head -n1)
  if [[ -n $id ]]; then
    gh api -X PATCH "repos/$GITHUB_REPOSITORY/issues/comments/$id" -f body="$body" >/dev/null
  else
    gh api "repos/$GITHUB_REPOSITORY/issues/$1/comments" -f body="$body" >/dev/null
  fi
}

# create_deployment SHA URL – shows the preview in the pull request's deployment box
create_deployment() {
  local id
  if [[ $DRY_RUN == true ]]; then return; fi
  id=$(jq -n --arg ref "$1" --arg environment "preview-$SLUG" \
    '{ref: $ref, environment: $environment, auto_merge: false, required_contexts: [], transient_environment: true}' \
    | gh api "repos/$GITHUB_REPOSITORY/deployments" --input - --jq .id)
  gh api "repos/$GITHUB_REPOSITORY/deployments/$id/statuses" -f state=success -f environment_url="$2" >/dev/null
}

deactivate_deployments() {
  local id
  if [[ $DRY_RUN == true ]]; then return; fi
  for id in $(gh api "repos/$GITHUB_REPOSITORY/deployments?environment=preview-$SLUG" --jq '.[].id'); do
    gh api "repos/$GITHUB_REPOSITORY/deployments/$id/statuses" -f state=inactive >/dev/null
  done
}
