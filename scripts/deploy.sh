#!/usr/bin/env bash
# Creates or updates the preview site of the current pull request.
#
# How to read this file: main() lists the steps in order, each step is a function below it.
# Every step checks what already exists first, so the script can run again after a failure
# and on every push.
#
# The inputs of deploy/action.yml arrive as environment variables in capitals:
# api-token is API_TOKEN, source-site is SOURCE_SITE, and so on.
source "$(dirname "$0")/lib.sh"

main() {
  skip_pull_requests_from_forks
  require_inputs API_TOKEN SERVER DOMAIN
  read_pull_request
  skip_pull_requests_without_label
  check_inputs

  resolve_server
  load_source_site
  set_preview_names "$(preview_slug "$BRANCH")"
  choose_site_settings

  ensure_site_and_database
  wait_until 300 "the site to be ready" site_is_ready "$SITE_ID"
  ensure_php_version
  ensure_repository
  ensure_env_file
  ensure_certificate
  block_search_engines "$SITE_ID"
  ensure_basic_auth
  install_deploy_script
  deploy
  copy_queue_workers
  copy_cronjobs
  report
}

# --- Preparation -------------------------------------------------------------

# Sets BRANCH, PULL_REQUEST and SHA from the event that triggered the workflow.
read_pull_request() {
  BRANCH=$(event_value .pull_request.head.ref)
  PULL_REQUEST=$(event_value .pull_request.number)
  SHA=$(event_value .pull_request.head.sha)

  if [[ -z $PULL_REQUEST ]]; then
    fail "The deploy action only runs on pull_request events."
  fi
}

skip_pull_requests_without_label() {
  if [[ -z $LABEL ]]; then
    return
  fi
  if pull_request_has_label "$LABEL"; then
    return
  fi
  notice "Skipped: the pull request does not carry the '$LABEL' label."
  exit 0
}

check_inputs() {
  if [[ $SSL != letsencrypt && $SSL != none ]]; then
    fail "ssl must be 'letsencrypt' or 'none'. Ploi's API cannot assign an existing wildcard certificate to a new site."
  fi
  # Basic auth needs both values; one alone is a mistake.
  if [[ -n $BASIC_AUTH_USER || -n $BASIC_AUTH_PASSWORD ]]; then
    require_inputs BASIC_AUTH_USER BASIC_AUTH_PASSWORD
  fi
  if [[ ! -f $ENV_FILE ]]; then
    fail "env-file '$ENV_FILE' not found in the repository."
  fi
}

# Sets PHP_VERSION, SYSTEM_USER and URL. PHP version and system user follow the source site.
choose_site_settings() {
  PHP_VERSION= # empty means: keep whatever Ploi gives the new site
  SYSTEM_USER=ploi
  if [[ -n $SOURCE_SITE ]]; then
    PHP_VERSION=$(jq -r .php_version <<<"$SOURCE_JSON")
    SYSTEM_USER=$(jq -r '.system_user // "ploi"' <<<"$SOURCE_JSON")
  fi

  URL="https://$PREVIEW_DOMAIN"
  if [[ $SSL == none ]]; then
    URL="http://$PREVIEW_DOMAIN"
  fi
}

# --- Site and database -------------------------------------------------------

# Sets SITE_ID. Creates the site and its database on the first run; on later runs it only
# accepts a site that is provably a preview of this repository.
ensure_site_and_database() {
  local site
  site=$(find_site "$PREVIEW_DOMAIN")

  if [[ -n $site ]]; then
    SITE_ID=$(jq -r .id <<<"$site")
    if ! is_preview_site "$SITE_ID"; then
      fail "$PREVIEW_DOMAIN already exists and is not a preview created by this action."
    fi
    if [[ $(jq -r .has_repository <<<"$site") == true ]] && ! site_belongs_to_repository "$SITE_ID"; then
      fail "$PREVIEW_DOMAIN is a preview of another repository. Use a domain and db-prefix of your own."
    fi
    return
  fi

  if [[ -n $(find_database "$DB_NAME") ]]; then
    fail "Database $DB_NAME exists without its site. Run the cleanup action for this branch first."
  fi

  echo "Creating site $PREVIEW_DOMAIN"
  SITE_ID=$(create_site "$PREVIEW_DOMAIN" "$SYSTEM_USER")
  if [[ $DRY_RUN == true ]]; then
    notice "Dry run: would create $PREVIEW_DOMAIN with database $DB_NAME."
    exit 0
  fi
  create_database "$DB_NAME" "$SITE_ID"
}

ensure_php_version() {
  if [[ -z $PHP_VERSION ]]; then
    PHP_VERSION=$(get_site "$SITE_ID" | jq -r .php_version)
    return
  fi
  if site_has_php_version "$SITE_ID" "$PHP_VERSION"; then
    return
  fi

  echo "Switching to PHP $PHP_VERSION"
  set_site_php_version "$SITE_ID" "$PHP_VERSION"
  wait_until 120 "the PHP version" site_has_php_version "$SITE_ID" "$PHP_VERSION"
}

ensure_repository() {
  if site_has_repository "$SITE_ID"; then
    return
  fi

  echo "Installing $GITHUB_REPOSITORY@$BRANCH"
  install_repository "$SITE_ID" "$BRANCH"
  wait_until 300 "the repository installation" repository_is_installed "$SITE_ID"
}

# --- .env --------------------------------------------------------------------

# Uploads the .env. Sets DB_PASSWORD and APP_KEY: taken from the existing .env on later runs,
# generated on the first run.
ensure_env_file() {
  local current_env env_file

  # A new site has no .env yet. "2>/dev/null" hides that error, "|| current_env=" treats it as empty.
  current_env=$(get_site_env "$SITE_ID" 2>/dev/null) || current_env=

  if [[ $(read_env_value DB_DATABASE <<<"$current_env") == "$DB_NAME" ]]; then
    DB_PASSWORD=$(read_env_value DB_PASSWORD <<<"$current_env")
    APP_KEY=$(read_env_value APP_KEY <<<"$current_env")
    hide_in_logs "$DB_PASSWORD" "$APP_KEY"
  else
    DB_PASSWORD=$(openssl rand -hex 24)
    APP_KEY="base64:$(openssl rand -base64 32)"
    hide_in_logs "$DB_PASSWORD" "$APP_KEY"
    create_preview_database_user
  fi

  env_file=$(mktemp)
  build_env_file "$ENV_FILE" "$env_file"
  update_site_env "$SITE_ID" "$env_file"
  rm "$env_file"
}

# Gives the preview database exactly one user, named like the database, with DB_PASSWORD.
create_preview_database_user() {
  local database_id

  echo "Creating database user $DB_NAME"
  wait_until 120 "the database" database_is_active "$DB_NAME"
  database_id=$(find_database "$DB_NAME" | jq -r .id)
  delete_database_users "$database_id"
  create_database_user "$database_id" "$DB_NAME" "$DB_PASSWORD"
}

# --- SSL and basic auth ------------------------------------------------------

ensure_certificate() {
  local certificate_id

  if [[ $SSL != letsencrypt ]]; then
    return
  fi
  if site_has_active_certificate "$SITE_ID"; then
    return
  fi

  echo "Requesting a Let's Encrypt certificate"
  certificate_id=$(request_certificate "$SITE_ID" "$PREVIEW_DOMAIN")
  wait_until 300 "the SSL certificate" certificate_is_active "$SITE_ID" "$certificate_id"
}

ensure_basic_auth() {
  if [[ -z $BASIC_AUTH_USER ]]; then
    return
  fi
  if site_has_basic_auth_user "$SITE_ID" "$BASIC_AUTH_USER"; then
    return
  fi
  create_basic_auth_user "$SITE_ID" "$BASIC_AUTH_USER" "$BASIC_AUTH_PASSWORD"
}

# --- Deployment --------------------------------------------------------------

# Picks the script to start from and uploads the version adapted for the preview.
install_deploy_script() {
  local script origin

  if [[ -n $DEPLOY_SCRIPT ]]; then
    script=$(cat "$DEPLOY_SCRIPT")
    origin=repository
  elif [[ -n $SOURCE_SITE ]]; then
    script=$(get_deploy_script "$SOURCE_ID")
    origin=source-site
  else
    script=$(get_deploy_script "$SITE_ID")
    origin=preview
  fi

  update_deploy_script "$SITE_ID" "$(build_deploy_script "$script" "$origin")"
}

deploy() {
  local preview_fresh=0
  if [[ $FRESH_SEED == true && $FRESH_ON_UPDATE == true ]]; then
    preview_fresh=1
  fi

  echo "Deploying $BRANCH to $PREVIEW_DOMAIN"
  LAST_DEPLOY_AT=$(get_site "$SITE_ID" | jq -r .last_deploy_at)
  SEEN_DEPLOYING=false
  DEPLOY_STATUS=
  DEPLOY_STARTED=$SECONDS
  start_deployment "$SITE_ID" "$preview_fresh"
  wait_until "${DEPLOY_TIMEOUT:-900}" "the deployment" deployment_finished

  if [[ $DRY_RUN != true && $DEPLOY_STATUS != active ]]; then
    print_latest_site_log "$SITE_ID" || true
    fail "The deployment failed."
  fi
}

# Ploi gives a deployment no id, so the site's status is the only signal. The deployment is
# over when the status is no longer "deploying" AND there is proof that this deployment ran.
# Sets DEPLOY_STATUS to the final status: "active" (success) or "deploy-failed".
deployment_finished() {
  local site status last_deploy_at
  site=$(get_site "$SITE_ID") || return 1
  status=$(jq -r .status <<<"$site")
  last_deploy_at=$(jq -r .last_deploy_at <<<"$site")

  if [[ $status == deploying ]]; then
    SEEN_DEPLOYING=true
    return 1
  fi

  # Proof 1: the status was "deploying" before. Proof 2: the time of the last deploy changed.
  if [[ $SEEN_DEPLOYING == true || $last_deploy_at != "$LAST_DEPLOY_AT" ]]; then
    DEPLOY_STATUS=$status
    return 0
  fi

  # A site that was already "deploy-failed" and fails again within seconds shows neither proof.
  # After a minute in that state, accept it as the result.
  if [[ $status == deploy-failed && $SECONDS -ge $((DEPLOY_STARTED + 60)) ]]; then
    DEPLOY_STATUS=$status
    return 0
  fi

  return 1
}

# --- Queue workers and cronjobs ----------------------------------------------

# Copies the source site's queue workers once: skipped as soon as the preview has any.
copy_queue_workers() {
  local workers worker

  if [[ $QUEUES != true || -z $SOURCE_SITE ]]; then
    return
  fi
  if site_has_queue_workers "$SITE_ID"; then
    return
  fi

  workers=$(list_queue_worker_settings "$SOURCE_ID")
  while IFS= read -r worker; do
    if [[ -n $worker ]]; then
      create_queue_worker "$SITE_ID" "$worker"
    fi
  done <<<"$workers"
}

# Copies the cronjobs that run inside the source site's directory, with the path rewritten
# to the preview. Skipped as soon as a cronjob for the preview exists.
copy_cronjobs() {
  local cronjobs copies cronjob

  if [[ $SCHEDULER != true || -z $SOURCE_SITE ]]; then
    return
  fi

  cronjobs=$(list_cronjobs)
  if jq -e --arg path "/$PREVIEW_DOMAIN" 'any(.[]; .command | contains($path))' <<<"$cronjobs" >/dev/null; then
    return
  fi

  copies=$(jq -c \
    --arg source "/$SOURCE_SITE" \
    --arg preview "/$PREVIEW_DOMAIN" \
    '.[]
      | select(.command | contains($source))
      | {user, frequency, command: (.command | split($source) | join($preview))}' <<<"$cronjobs")
  while IFS= read -r cronjob; do
    if [[ -n $cronjob ]]; then
      create_cronjob "$cronjob"
    fi
  done <<<"$copies"
}

# --- Report ------------------------------------------------------------------

# Sets the action's outputs and tells the pull request where the preview is.
report() {
  local comment

  {
    echo "url=$URL"
    echo "site-id=$SITE_ID"
    echo "database=$DB_NAME"
  } >>"$GITHUB_OUTPUT"

  # Fill the placeholders of the comment template.
  comment=${COMMENT_TEMPLATE//'{url}'/"$URL"}
  comment=${comment//'{branch}'/"$BRANCH"}
  comment=${comment//'{sha}'/"${SHA:0:7}"}
  comment=${comment//'{database}'/"$DB_NAME"}

  upsert_comment "$PULL_REQUEST" "$comment"
  create_deployment "$SHA" "$URL"
  notice "Preview deployed to $URL"
}

main
