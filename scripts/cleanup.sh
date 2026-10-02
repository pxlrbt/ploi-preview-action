#!/usr/bin/env bash
# Removes previews. Two modes, chosen by the event that triggered the workflow:
#   - a pull request was closed: remove the preview of its branch
#   - anything else (the nightly schedule): remove previews that are stale or orphaned
#
# How to read this file: main() picks the mode, remove_preview() does the deleting for both.
# The inputs of cleanup/action.yml arrive as environment variables in capitals.
source "$(dirname "$0")/lib.sh"

main() {
  skip_pull_requests_from_forks
  require_inputs API_TOKEN SERVER DOMAIN
  resolve_server
  load_source_site

  PULL_REQUEST=$(event_value .pull_request.number)
  if [[ -n $PULL_REQUEST ]]; then
    remove_preview_of_pull_request
  else
    prune_previews
  fi
}

# --- Deleting one preview ----------------------------------------------------

# remove_preview SLUG – deletes the preview's cronjobs, queue workers, site, database users
# and database. Sets REMOVED to true when there was something to delete.
#
# Safety: set_preview_names refuses unsafe names, the site is only deleted while its prefixed
# database is linked to it, and the database is only deleted when it carries the prefix and
# belongs to no other site.
remove_preview() {
  local site site_id database database_id linked_domain

  set_preview_names "$1"
  REMOVED=false

  site=$(find_site "$PREVIEW_DOMAIN")
  if [[ -n $site ]]; then
    site_id=$(jq -r .id <<<"$site")
    if ! is_preview_site "$site_id"; then
      fail "$PREVIEW_DOMAIN exists but database $DB_NAME is not linked to it. Refusing to delete it."
    fi

    delete_cronjobs_of_site "$PREVIEW_DOMAIN"
    delete_queue_workers "$site_id"
    echo "Deleting site $PREVIEW_DOMAIN"
    delete_site "$site_id"
    REMOVED=true
  fi

  database=$(find_database "$DB_NAME")
  if [[ -n $database ]]; then
    database_id=$(jq -r .id <<<"$database")
    linked_domain=$(jq -r '.site.root_domain // empty' <<<"$database")
    if [[ -n $linked_domain && $linked_domain != "$PREVIEW_DOMAIN" ]]; then
      fail "Database $DB_NAME belongs to $linked_domain. Refusing to delete it."
    fi

    echo "Deleting database $DB_NAME"
    delete_database_users "$database_id"
    delete_database "$database_id"
    REMOVED=true
  fi
}

# --- Mode 1: a pull request was closed ---------------------------------------

remove_preview_of_pull_request() {
  local branch
  branch=$(event_value .pull_request.head.ref)

  remove_preview "$(preview_slug "$branch")"

  if [[ $REMOVED == true ]]; then
    upsert_comment "$PULL_REQUEST" "Preview removed."
    deactivate_deployments
  else
    notice "No preview found for $PREVIEW_DOMAIN."
  fi
}

# --- Mode 2: scheduled prune -------------------------------------------------

prune_previews() {
  local open_previews sites site

  if [[ $MAX_AGE_DAYS -le 0 ]]; then
    notice "Nothing to prune: max-age-days is 0."
    return
  fi

  open_previews=$(list_open_previews)

  # All sites of the server below the preview domain, one line of JSON each.
  mapfile -t sites < <(
    ploi_list "/servers/$SERVER/sites" \
      | jq -c --arg suffix ".$DOMAIN" '.[] | select(.domain | endswith($suffix))'
  )
  for site in "${sites[@]}"; do
    prune_site_if_stale "$site" "$open_previews"
  done
}

# list_open_previews – one line per open pull request: the slug of its preview, a space, its number
list_open_previews() {
  local pull_requests number branch

  pull_requests=$(list_open_pull_requests)
  while IFS=$'\t' read -r number branch; do
    if [[ -n $number ]]; then
      echo "$(preview_slug "$branch") $number"
    fi
  done <<<"$pull_requests"
}

# prune_site_if_stale SITE_JSON OPEN_PREVIEWS – removes the site's preview when its pull
# request is closed, or when it was not deployed for MAX_AGE_DAYS days
prune_site_if_stale() {
  local site=$1 open_previews=$2
  local domain site_id slug pull_request last_deploy age_days

  domain=$(jq -r .domain <<<"$site")
  site_id=$(jq -r .id <<<"$site")
  slug=${domain%".$DOMAIN"} # the part in front of ".<domain>"

  # Leave everything alone that is not provably a preview of this repository.
  if [[ $domain == "$SOURCE_SITE" ]]; then
    return
  fi
  if ! is_valid_slug "$slug"; then
    return
  fi
  set_preview_names "$slug"
  if ! is_preview_site "$site_id"; then
    return
  fi
  if ! site_belongs_to_repository "$site_id"; then
    return
  fi

  # Keep the preview of an open pull request that was deployed recently.
  pull_request=$(awk -v slug="$slug" '$1 == slug { print $2; exit }' <<<"$open_previews")
  last_deploy=$(jq -r '.last_deploy_at // .created_at' <<<"$site")
  age_days=$(days_since "$last_deploy")
  if [[ -n $pull_request && $age_days -lt $MAX_AGE_DAYS ]]; then
    return
  fi

  remove_preview "$slug"
  deactivate_deployments
  if [[ -n $pull_request ]]; then
    upsert_comment "$pull_request" \
      "Preview removed after $age_days days without a deployment. Push a commit to recreate it."
  fi
  notice "Pruned $domain"
}

# days_since TIMESTAMP – whole days between the timestamp and now
days_since() {
  local now past
  now=$(date +%s)
  past=$(date -d "$1" +%s)
  echo $(((now - past) / 86400))
}

main
