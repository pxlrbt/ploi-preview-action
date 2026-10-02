# shellcheck shell=bash
# Every call to the Ploi API (https://developers.ploi.io). One function per call, so the
# deploy and cleanup scripts read as a list of steps.
#
# All functions use SERVER (the server id) and API_TOKEN.

# --- Transport ---------------------------------------------------------------

# ploi_request METHOD PATH [JSON_BODY] – prints the response body.
# Fails when Ploi answers with an error status. In dry-run mode only GET requests are sent.
ploi_request() {
  local method=$1 path=$2 body=${3:-}
  local response status attempt

  if [[ $DRY_RUN == true && $method != GET ]]; then
    echo "[dry-run] $method $path" >&2
    echo '{"data": {"id": 0}}'
    return
  fi

  for attempt in 1 2 3 4; do
    # -w appends the HTTP status as a last line; the body is sent only when there is one.
    # shellcheck disable=SC2086
    response=$(curl -sS --max-time 120 -X "$method" "https://ploi.io/api$path" \
      -H "Authorization: Bearer $API_TOKEN" \
      -H 'Accept: application/json' \
      -H 'Content-Type: application/json' \
      ${body:+--data-binary @-} \
      -w $'\n%{http_code}' <<<"$body")
    status=${response##*$'\n'}   # the last line
    response=${response%$'\n'*}  # everything before the last line

    # 429 means "too many requests": wait and try again.
    if [[ $status != 429 ]]; then
      break
    fi
    sleep 30
  done

  if [[ $status != 2* ]]; then
    echo "::error::Ploi API $method $path failed ($status): $response" >&2
    return 1
  fi
  echo "$response"
}

# ploi_list PATH – Ploi returns lists page by page; this prints all pages as one JSON array
ploi_list() {
  local path=$1 page=1
  local response has_more_pages

  while true; do
    response=$(ploi_request GET "$path?per_page=50&page=$page")
    jq -c '.data[]' <<<"$response"

    has_more_pages=$(jq -r '(.meta.last_page // 1) > (.meta.current_page // 1)' <<<"$response")
    if [[ $has_more_pages != true ]]; then
      break
    fi
    page=$((page + 1))
  done | jq -s .
}

# --- Server ------------------------------------------------------------------

# Accepts a server name in SERVER and replaces it with the server's id.
resolve_server() {
  local id

  if [[ $SERVER =~ ^[0-9]+$ ]]; then
    return
  fi
  id=$(ploi_list /servers | jq -r --arg name "$SERVER" 'map(select(.name == $name))[0].id // empty')
  if [[ -z $id ]]; then
    fail "Ploi server '$SERVER' not found."
  fi
  SERVER=$id
}

# --- Sites -------------------------------------------------------------------

# find_site DOMAIN – prints the site as JSON, or nothing when it does not exist
find_site() {
  ploi_list "/servers/$SERVER/sites" \
    | jq -c --arg domain "$1" 'map(select(.domain == $domain))[0] // empty'
}

# get_site SITE_ID – prints the site as JSON
get_site() {
  ploi_request GET "/servers/$SERVER/sites/$1" | jq .data
}

# create_site DOMAIN SYSTEM_USER – prints the id of the new site
create_site() {
  local body
  body=$(jq -n \
    --arg domain "$1" \
    --arg user "$2" \
    '{root_domain: $domain, web_directory: "/public", project_type: "laravel", system_user: $user}')
  ploi_request POST "/servers/$SERVER/sites" "$body" | jq -r .data.id
}

# delete_site SITE_ID
delete_site() {
  ploi_request DELETE "/servers/$SERVER/sites/$1" >/dev/null
}

# site_is_ready SITE_ID – Ploi finished creating the site (a failed deploy also counts as ready)
site_is_ready() {
  get_site "$1" | jq -e '.status == "active" or .status == "deploy-failed"' >/dev/null
}

# site_has_php_version SITE_ID VERSION
site_has_php_version() {
  [[ $(get_site "$1" | jq -r .php_version) == "$2" ]]
}

# set_site_php_version SITE_ID VERSION
set_site_php_version() {
  local body
  body=$(jq -n --arg version "$2" '{php_version: $version}')
  ploi_request POST "/servers/$SERVER/sites/$1/php-version" "$body" >/dev/null
}

# block_search_engines SITE_ID – makes the site send an X-Robots-Tag header
block_search_engines() {
  ploi_request PATCH "/servers/$SERVER/sites/$1" '{"disable_robots": true}' >/dev/null
}

# print_latest_site_log SITE_ID – the output of the last deploy
print_latest_site_log() {
  local log_id
  log_id=$(ploi_request GET "/servers/$SERVER/sites/$1/log" | jq -r '.data[0].id')
  ploi_request GET "/servers/$SERVER/sites/$1/log/$log_id" | jq -r .data.content
}

# --- Repository --------------------------------------------------------------

# site_has_repository SITE_ID
site_has_repository() {
  get_site "$1" | jq -e '.has_repository == true' >/dev/null
}

# repository_is_installed SITE_ID – the installation is finished, not only started
repository_is_installed() {
  get_site "$1" | jq -e '.status == "active" and .has_repository == true' >/dev/null
}

# install_repository SITE_ID BRANCH – connects the site to this GitHub repository
install_repository() {
  local body
  body=$(jq -n \
    --arg name "$GITHUB_REPOSITORY" \
    --arg branch "$2" \
    '{provider: "github", name: $name, branch: $branch}')
  ploi_request POST "/servers/$SERVER/sites/$1/repository" "$body" >/dev/null
}

# site_belongs_to_repository SITE_ID – true when the site was installed from this GitHub repository
site_belongs_to_repository() {
  local this_repository
  this_repository=$(tr 'A-Z' 'a-z' <<<"$GITHUB_REPOSITORY")

  # Ploi reports the repository either as user + name or as "user/name" in name; accept both.
  ploi_request GET "/servers/$SERVER/sites/$1/repository" \
    | jq -r '.data.repository | "\(.user)/\(.name)", .name' \
    | tr 'A-Z' 'a-z' \
    | grep -qxF "$this_repository"
}

# --- .env and deploy script --------------------------------------------------

# get_site_env SITE_ID – prints the content of the site's .env, fails when there is none
get_site_env() {
  ploi_request GET "/servers/$SERVER/sites/$1/env" | jq -er '(.content // .data) | strings'
}

# update_site_env SITE_ID FILE – uploads FILE as the site's .env
update_site_env() {
  local body
  body=$(jq -n --rawfile content "$2" '{content: $content}')
  ploi_request PATCH "/servers/$SERVER/sites/$1/env" "$body" >/dev/null
}

# get_deploy_script SITE_ID
get_deploy_script() {
  ploi_request GET "/servers/$SERVER/sites/$1/deploy/script" | jq -r .deploy_script
}

# update_deploy_script SITE_ID SCRIPT
update_deploy_script() {
  local body
  body=$(jq -n --arg script "$2" '{deploy_script: $script}')
  ploi_request PATCH "/servers/$SERVER/sites/$1/deploy/script" "$body" >/dev/null
}

# start_deployment SITE_ID PREVIEW_FRESH – PREVIEW_FRESH (0 or 1) reaches the deploy script
# as the environment variable $PREVIEW_FRESH
start_deployment() {
  local body
  body=$(jq -n --arg fresh "$2" '{variables: {preview_fresh: $fresh}}')
  ploi_request POST "/servers/$SERVER/sites/$1/deploy" "$body" >/dev/null
}

# --- SSL and basic auth ------------------------------------------------------

# site_has_active_certificate SITE_ID
site_has_active_certificate() {
  ploi_request GET "/servers/$SERVER/sites/$1/certificates" \
    | jq -e 'any(.data[]; .status == "active")' >/dev/null
}

# request_certificate SITE_ID DOMAIN – asks for a Let's Encrypt certificate, prints its id
request_certificate() {
  local body
  body=$(jq -n --arg domain "$2" '{type: "letsencrypt", certificate: $domain}')
  ploi_request POST "/servers/$SERVER/sites/$1/certificates" "$body" | jq -r .data.id
}

# certificate_is_active SITE_ID CERTIFICATE_ID
certificate_is_active() {
  [[ $(ploi_request GET "/servers/$SERVER/sites/$1/certificates/$2" | jq -r .data.status) == active ]]
}

# site_has_basic_auth_user SITE_ID NAME
site_has_basic_auth_user() {
  ploi_request GET "/servers/$SERVER/sites/$1/auth-users" \
    | jq -e --arg name "$2" 'any(.data[]; .name == $name)' >/dev/null
}

# create_basic_auth_user SITE_ID NAME PASSWORD
create_basic_auth_user() {
  local body
  body=$(jq -n --arg name "$2" --arg password "$3" '{name: $name, password: $password}')
  ploi_request POST "/servers/$SERVER/sites/$1/auth-users" "$body" >/dev/null
}

# --- Databases ---------------------------------------------------------------

# find_database NAME – prints the database as JSON, or nothing when it does not exist
find_database() {
  ploi_list "/servers/$SERVER/databases" \
    | jq -c --arg name "$1" 'map(select(.name == $name))[0] // empty'
}

# create_database NAME SITE_ID – the link to the site is what marks the site as a preview
create_database() {
  local body
  body=$(jq -n --arg name "$1" --argjson site "$2" '{name: $name, site_id: $site}')
  ploi_request POST "/servers/$SERVER/databases" "$body" >/dev/null
}

# database_is_active NAME
database_is_active() {
  [[ $(find_database "$1" | jq -r .status) == active ]]
}

# delete_database DATABASE_ID
delete_database() {
  ploi_request DELETE "/servers/$SERVER/databases/$1" >/dev/null
}

# is_preview_site SITE_ID – a site only counts as a preview while the database DB_NAME
# (which always carries the prefix) is linked to it. Nothing else is ever redeployed or deleted.
is_preview_site() {
  ploi_list "/servers/$SERVER/databases" \
    | jq -e --arg name "$DB_NAME" --argjson site "$1" \
      'any(.[]; .name == $name and .site.id == $site)' >/dev/null
}

# create_database_user DATABASE_ID NAME PASSWORD
create_database_user() {
  local body
  body=$(jq -n --arg user "$2" --arg password "$3" '{user: $user, password: $password}')
  ploi_request POST "/servers/$SERVER/databases/$1/users" "$body" >/dev/null
}

# delete_database_users DATABASE_ID – Ploi removes users in the background, so wait until they are gone
delete_database_users() {
  local users_path="/servers/$SERVER/databases/$1/users"
  local user_id

  for user_id in $(ploi_request GET "$users_path" | jq -r '.data[].id'); do
    ploi_request DELETE "$users_path/$user_id" >/dev/null
  done
  wait_until 120 "the database users to be removed" database_has_no_users "$users_path"
}

# database_has_no_users USERS_PATH
database_has_no_users() {
  ploi_request GET "$1" | jq -e '.data | length == 0' >/dev/null
}

# --- Queue workers and cronjobs ----------------------------------------------

# site_has_queue_workers SITE_ID
site_has_queue_workers() {
  ploi_request GET "/servers/$SERVER/sites/$1/queues" | jq -e '.data | length > 0' >/dev/null
}

# list_queue_worker_settings SITE_ID – one line of JSON per worker, ready for create_queue_worker
list_queue_worker_settings() {
  ploi_request GET "/servers/$SERVER/sites/$1/queues" \
    | jq -c '.data[]
        | {connection, queue, maximum_seconds, sleep, processes, backoff, maximum_tries}
        | with_entries(select(.value != null))'
}

# create_queue_worker SITE_ID SETTINGS_JSON
create_queue_worker() {
  ploi_request POST "/servers/$SERVER/sites/$1/queues" "$2" >/dev/null
}

# delete_queue_workers SITE_ID
delete_queue_workers() {
  local worker_id
  for worker_id in $(ploi_request GET "/servers/$SERVER/sites/$1/queues" | jq -r '.data[].id'); do
    ploi_request DELETE "/servers/$SERVER/sites/$1/queues/$worker_id" >/dev/null
  done
}

# list_cronjobs – all cronjobs of the server as one JSON array (cronjobs are not tied to a site)
list_cronjobs() {
  ploi_list "/servers/$SERVER/crontabs"
}

# create_cronjob SETTINGS_JSON
create_cronjob() {
  ploi_request POST "/servers/$SERVER/crontabs" "$1" >/dev/null
}

# delete_cronjobs_of_site DOMAIN – deletes the cronjobs whose command runs inside the site's directory
delete_cronjobs_of_site() {
  local cronjob_id
  for cronjob_id in $(list_cronjobs | jq -r --arg path "/$1" '.[] | select(.command | contains($path)) | .id'); do
    ploi_request DELETE "/servers/$SERVER/crontabs/$cronjob_id" >/dev/null
  done
}

# --- Source site -------------------------------------------------------------

# Looks up the source site, if one is configured. Sets SOURCE_JSON (the site), SOURCE_ID and
# SOURCE_DATABASE (its database name, which must never be used for a preview).
load_source_site() {
  local source_env

  if [[ -z $SOURCE_SITE ]]; then
    return
  fi

  SOURCE_JSON=$(find_site "$SOURCE_SITE")
  if [[ -z $SOURCE_JSON ]]; then
    fail "Source site '$SOURCE_SITE' not found on the server."
  fi
  SOURCE_ID=$(jq -r .id <<<"$SOURCE_JSON")

  source_env=$(get_site_env "$SOURCE_ID") \
    || fail "Could not read the .env of $SOURCE_SITE to protect its database."
  SOURCE_DATABASE=$(read_env_value DB_DATABASE <<<"$source_env" | tr -d "\"'")
}
