#!/usr/bin/env bash
# Creates or updates the preview site of the current pull request.
source "$(dirname "$0")/lib.sh"

skip_forks
require API_TOKEN SERVER DOMAIN

BRANCH=$(event .pull_request.head.ref)
PULL_REQUEST=$(event .pull_request.number)
SHA=$(event .pull_request.head.sha)
if [[ -z $PULL_REQUEST ]]; then die "The deploy action only runs on pull_request events."; fi
if [[ -n $LABEL ]] && ! jq -e --arg label "$LABEL" 'any(.pull_request.labels[]?; .name == $label)' "$GITHUB_EVENT_PATH" >/dev/null; then
  notice "Skipped: the pull request does not carry the '$LABEL' label."
  exit 0
fi
if [[ $SSL != letsencrypt && $SSL != none ]]; then
  die "ssl must be 'letsencrypt' or 'none'. Ploi's API cannot assign an existing wildcard certificate to a new site."
fi
if [[ -n $BASIC_AUTH_USER$BASIC_AUTH_PASSWORD ]]; then require BASIC_AUTH_USER BASIC_AUTH_PASSWORD; fi
if [[ ! -f $ENV_FILE ]]; then die "env-file '$ENV_FILE' not found in the repository."; fi

resolve_server
load_source_site
preview_names "$(slug "$BRANCH")"

PHP_VERSION=
SYSTEM_USER=ploi
if [[ -n $SOURCE_SITE ]]; then
  PHP_VERSION=$(jq -r .php_version <<<"$SOURCE_JSON")
  SYSTEM_USER=$(jq -r '.system_user // "ploi"' <<<"$SOURCE_JSON")
fi
URL="https://$PREVIEW_DOMAIN"
if [[ $SSL == none ]]; then URL="http://$PREVIEW_DOMAIN"; fi

site_is() {
  ploi GET "$SITE" | jq -e "$1" >/dev/null
}

database_is_active() {
  [[ $(find_database "$DB_NAME" | jq -r .status) == active ]]
}

certificate_is_active() {
  [[ $(ploi GET "$SITE/certificates/$1" | jq -r .data.status) == active ]]
}

# A deploy has no id: it is over once the site left "deploying" and something actually ran.
deploy_finished() {
  local site status
  site=$(ploi GET "$SITE") || return 1
  status=$(jq -r .data.status <<<"$site")
  if [[ $status == deploying ]]; then
    SEEN_DEPLOYING=true
    return 1
  fi
  if [[ $SEEN_DEPLOYING == true || $(jq -r .data.last_deploy_at <<<"$site") != "$LAST_DEPLOY_AT" ]]; then
    DEPLOY_STATUS=$status
    return 0
  fi
  # A site that already was in "deploy-failed" and fails again quickly never shows another signal.
  if [[ $status == deploy-failed ]] && ((SECONDS >= DEPLOY_STARTED + 60)); then
    DEPLOY_STATUS=$status
    return 0
  fi
  return 1
}

# --- Site and database -------------------------------------------------------

site=$(find_site "$PREVIEW_DOMAIN")
if [[ -n $site ]]; then
  SITE_ID=$(jq -r .id <<<"$site")
  if ! is_preview "$SITE_ID"; then
    die "$PREVIEW_DOMAIN already exists and is not a preview created by this action."
  fi
else
  if [[ -n $(find_database "$DB_NAME") ]]; then
    die "Database $DB_NAME exists without its site. Run the cleanup action for this branch first."
  fi
  echo "Creating site $PREVIEW_DOMAIN"
  SITE_ID=$(ploi POST "/servers/$SERVER/sites" "$(jq -n --arg domain "$PREVIEW_DOMAIN" --arg user "$SYSTEM_USER" \
    '{root_domain: $domain, web_directory: "/public", project_type: "laravel", system_user: $user}')" | jq -r .data.id)
  if [[ $DRY_RUN == true ]]; then
    notice "Dry run: would create $PREVIEW_DOMAIN with database $DB_NAME."
    exit 0
  fi
  ploi POST "/servers/$SERVER/databases" "$(jq -n --arg name "$DB_NAME" --argjson site "$SITE_ID" '{name: $name, site_id: $site}')" >/dev/null
fi
SITE="/servers/$SERVER/sites/$SITE_ID"
wait_until 300 "the site to be ready" site_is '.data.status == "active" or .data.status == "deploy-failed"'

if [[ -z $PHP_VERSION ]]; then
  PHP_VERSION=$(ploi GET "$SITE" | jq -r .data.php_version)
elif ! site_is ".data.php_version | tostring == \"$PHP_VERSION\""; then
  echo "Switching to PHP $PHP_VERSION"
  ploi POST "$SITE/php-version" "$(jq -n --arg version "$PHP_VERSION" '{php_version: $version}')" >/dev/null
  wait_until 120 "the PHP version" site_is ".data.php_version | tostring == \"$PHP_VERSION\""
fi

if ! site_is '.data.has_repository == true'; then
  echo "Installing $GITHUB_REPOSITORY@$BRANCH"
  ploi POST "$SITE/repository" "$(jq -n --arg name "$GITHUB_REPOSITORY" --arg branch "$BRANCH" \
    '{provider: "github", name: $name, branch: $branch}')" >/dev/null
  wait_until 300 "the repository installation" site_is '.data.status == "active" and .data.has_repository == true'
fi

# --- .env --------------------------------------------------------------------

current_env=$(ploi GET "$SITE/env" 2>/dev/null | jq -r '.content // empty') || current_env=
current_env_value() {
  sed -n "s/^$1=//p" <<<"$current_env" | tail -n1
}

if [[ $(current_env_value DB_DATABASE) == "$DB_NAME" ]]; then
  DB_PASSWORD=$(current_env_value DB_PASSWORD)
  APP_KEY=$(current_env_value APP_KEY)
  echo "::add-mask::$DB_PASSWORD"
  echo "::add-mask::$APP_KEY"
else
  DB_PASSWORD=$(openssl rand -hex 24)
  APP_KEY="base64:$(openssl rand -base64 32)"
  echo "::add-mask::$DB_PASSWORD"
  echo "::add-mask::$APP_KEY"
  echo "Creating database user $DB_NAME"
  wait_until 120 "the database" database_is_active
  database_users="/servers/$SERVER/databases/$(find_database "$DB_NAME" | jq -r .id)/users"
  for id in $(ploi GET "$database_users" | jq -r '.data[].id'); do
    ploi DELETE "$database_users/$id" >/dev/null
  done
  ploi POST "$database_users" "$(jq -n --arg user "$DB_NAME" --arg password "$DB_PASSWORD" '{user: $user, password: $password}')" >/dev/null
fi

env_file=$(mktemp)
cp "$ENV_FILE" "$env_file"
set_env "$env_file" APP_URL "$URL"
set_env "$env_file" APP_ENV preview
set_env "$env_file" APP_KEY "$APP_KEY"
set_env "$env_file" DB_CONNECTION mysql
set_env "$env_file" DB_HOST 127.0.0.1
set_env "$env_file" DB_PORT 3306
set_env "$env_file" DB_DATABASE "$DB_NAME"
set_env "$env_file" DB_USERNAME "$DB_NAME"
set_env "$env_file" DB_PASSWORD "$DB_PASSWORD"
while IFS= read -r line; do
  if [[ $line == *=* ]]; then set_env "$env_file" "${line%%=*}" "${line#*=}"; fi
done <<<"$ENV_OVERRIDES"
if [[ $(grep '^DB_DATABASE=' "$env_file") != "DB_DATABASE=$DB_NAME" || $(grep '^DB_USERNAME=' "$env_file") != "DB_USERNAME=$DB_NAME" ]]; then
  die "The .env must point at the preview database $DB_NAME. Remove DB_DATABASE and DB_USERNAME from env-overrides."
fi
ploi PATCH "$SITE/env" "$(jq -n --rawfile content "$env_file" '{content: $content}')" >/dev/null
rm "$env_file"

# --- SSL, robots, basic auth -------------------------------------------------

if [[ $SSL == letsencrypt ]] && ! ploi GET "$SITE/certificates" | jq -e 'any(.data[]; .status == "active")' >/dev/null; then
  echo "Requesting a Let's Encrypt certificate"
  certificate=$(ploi POST "$SITE/certificates" "$(jq -n --arg domain "$PREVIEW_DOMAIN" '{type: "letsencrypt", certificate: $domain}')" | jq -r .data.id)
  wait_until 300 "the SSL certificate" certificate_is_active "$certificate"
fi

ploi PATCH "$SITE" '{"disable_robots": true}' >/dev/null

if [[ -n $BASIC_AUTH_USER ]] && ! ploi GET "$SITE/auth-users" | jq -e --arg name "$BASIC_AUTH_USER" 'any(.data[]; .name == $name)' >/dev/null; then
  ploi POST "$SITE/auth-users" "$(jq -n --arg name "$BASIC_AUTH_USER" --arg password "$BASIC_AUTH_PASSWORD" '{name: $name, password: $password}')" >/dev/null
fi

# --- Deploy script -----------------------------------------------------------

if [[ -n $DEPLOY_SCRIPT ]]; then
  script=$(<"$DEPLOY_SCRIPT")
elif [[ -n $SOURCE_SITE ]]; then
  script=$(ploi GET "/servers/$SERVER/sites/$SOURCE_ID/deploy/script" | jq -r .deploy_script)
  script=${script//"$SOURCE_SITE"/"$PREVIEW_DOMAIN"}
else
  script=$(ploi GET "$SITE/deploy/script" | jq -r .deploy_script)
fi
script=${script%%$'\n'"# ploi-preview"*}

# A plain "git pull" breaks on force-pushed branches and would pull the source site's branch.
deploy_script=
while IFS= read -r line; do
  if [[ $line =~ ^([[:space:]]*)git\ pull\ origin ]]; then
    line="${BASH_REMATCH[1]}git fetch origin $(printf %q "$BRANCH") && git reset --hard FETCH_HEAD"
  fi
  deploy_script+="$line"$'\n'
done <<<"$script"
deploy_script+="# ploi-preview"$'\n'"cd /home/$SYSTEM_USER/$PREVIEW_DOMAIN"$'\n'
if [[ $FRESH_SEED == true ]]; then
  # The marker file makes "first deploy" mean "until the database was seeded successfully once".
  deploy_script+="if [ \"\${PREVIEW_FRESH:-}\" = \"1\" ] || [ ! -f storage/app/.preview-seeded ]; then"$'\n'
  deploy_script+="  php$PHP_VERSION artisan migrate:fresh --seed --force && touch storage/app/.preview-seeded || exit 1"$'\n'
  deploy_script+="fi"$'\n'
fi
deploy_script+="$POST_DEPLOY_SCRIPT"$'\n'
ploi PATCH "$SITE/deploy/script" "$(jq -n --arg script "$deploy_script" '{deploy_script: $script}')" >/dev/null

# --- Deploy ------------------------------------------------------------------

preview_fresh=0
if [[ $FRESH_SEED == true && $FRESH_ON_UPDATE == true ]]; then preview_fresh=1; fi

echo "Deploying $BRANCH to $PREVIEW_DOMAIN"
LAST_DEPLOY_AT=$(ploi GET "$SITE" | jq -r .data.last_deploy_at)
SEEN_DEPLOYING=false
DEPLOY_STATUS=
DEPLOY_STARTED=$SECONDS
ploi POST "$SITE/deploy" "$(jq -n --arg fresh "$preview_fresh" '{variables: {preview_fresh: $fresh}}')" >/dev/null
wait_until "${DEPLOY_TIMEOUT:-900}" "the deployment" deploy_finished
if [[ $DRY_RUN != true && $DEPLOY_STATUS != active ]]; then
  log=$(ploi GET "$SITE/log" | jq -r '.data[0].id')
  ploi GET "$SITE/log/$log" | jq -r .data.content || true
  die "The deployment failed."
fi

# --- Queues and scheduler ----------------------------------------------------

if [[ $QUEUES == true && -n $SOURCE_SITE ]] && ! ploi GET "$SITE/queues" | jq -e '.data | length > 0' >/dev/null; then
  while IFS= read -r queue; do
    if [[ -n $queue ]]; then ploi POST "$SITE/queues" "$queue" >/dev/null; fi
  done < <(ploi GET "/servers/$SERVER/sites/$SOURCE_ID/queues" \
    | jq -c '.data[] | {connection, queue, maximum_seconds, sleep, processes, backoff, maximum_tries} | with_entries(select(.value != null))')
fi

if [[ $SCHEDULER == true && -n $SOURCE_SITE ]]; then
  crontabs=$(ploi_all "/servers/$SERVER/crontabs")
  if ! jq -e --arg path "/$PREVIEW_DOMAIN" 'any(.[]; .command | contains($path))' <<<"$crontabs" >/dev/null; then
    while IFS= read -r crontab; do
      if [[ -n $crontab ]]; then ploi POST "/servers/$SERVER/crontabs" "$crontab" >/dev/null; fi
    done < <(jq -c --arg source "/$SOURCE_SITE" --arg preview "/$PREVIEW_DOMAIN" \
      '.[] | select(.command | contains($source)) | {user, frequency, command: (.command | split($source) | join($preview))}' <<<"$crontabs")
  fi
fi

# --- Report ------------------------------------------------------------------

{
  echo "url=$URL"
  echo "site-id=$SITE_ID"
  echo "database=$DB_NAME"
} >>"$GITHUB_OUTPUT"

comment=${COMMENT_TEMPLATE//'{url}'/"$URL"}
comment=${comment//'{branch}'/"$BRANCH"}
comment=${comment//'{sha}'/"${SHA:0:7}"}
comment=${comment//'{database}'/"$DB_NAME"}
upsert_comment "$PULL_REQUEST" "$comment"
create_deployment "$SHA" "$URL"
notice "Preview deployed to $URL"
