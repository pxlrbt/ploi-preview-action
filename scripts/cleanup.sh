#!/usr/bin/env bash
# Removes the preview of a closed pull request, or prunes stale and orphaned previews
# when the workflow runs on a schedule.
source "$(dirname "$0")/lib.sh"

skip_forks
require API_TOKEN SERVER DOMAIN
resolve_server
load_source_site

# remove_preview SLUG – sets REMOVED=true when there was something to delete
remove_preview() {
  local site site_id database linked_domain id
  preview_names "$1"
  REMOVED=false

  site=$(find_site "$PREVIEW_DOMAIN")
  if [[ -n $site ]]; then
    site_id=$(jq -r .id <<<"$site")
    if ! is_preview "$site_id"; then
      die "$PREVIEW_DOMAIN exists but database $DB_NAME is not linked to it. Refusing to delete it."
    fi
    for id in $(ploi_all "/servers/$SERVER/crontabs" | jq -r --arg path "/$PREVIEW_DOMAIN" '.[] | select(.command | contains($path)) | .id'); do
      ploi DELETE "/servers/$SERVER/crontabs/$id" >/dev/null
    done
    for id in $(ploi GET "/servers/$SERVER/sites/$site_id/queues" | jq -r '.data[].id'); do
      ploi DELETE "/servers/$SERVER/sites/$site_id/queues/$id" >/dev/null
    done
    echo "Deleting site $PREVIEW_DOMAIN"
    ploi DELETE "/servers/$SERVER/sites/$site_id" >/dev/null
    REMOVED=true
  fi

  database=$(find_database "$DB_NAME")
  if [[ -n $database ]]; then
    linked_domain=$(jq -r '.site.root_domain // empty' <<<"$database")
    if [[ -n $linked_domain && $linked_domain != "$PREVIEW_DOMAIN" ]]; then
      die "Database $DB_NAME belongs to $linked_domain. Refusing to delete it."
    fi
    echo "Deleting database $DB_NAME"
    ploi DELETE "/servers/$SERVER/databases/$(jq -r .id <<<"$database")" >/dev/null
    REMOVED=true
  fi
}

# --- Closed pull request -----------------------------------------------------

PULL_REQUEST=$(event .pull_request.number)
if [[ -n $PULL_REQUEST ]]; then
  remove_preview "$(slug "$(event .pull_request.head.ref)")"
  if [[ $REMOVED == true ]]; then
    upsert_comment "$PULL_REQUEST" "Preview removed."
    deactivate_deployments
  else
    notice "No preview found for $PREVIEW_DOMAIN."
  fi
  exit 0
fi

# --- Scheduled prune ---------------------------------------------------------

if ((MAX_AGE_DAYS <= 0)); then
  notice "Nothing to prune: max-age-days is 0."
  exit 0
fi

open_previews=
while IFS=$'\t' read -r number branch; do
  if [[ -n $number ]]; then open_previews+="$(slug "$branch") $number"$'\n'; fi
done < <(gh pr list --repo "$GITHUB_REPOSITORY" --state open --limit 1000 --json number,headRefName --jq '.[] | [.number, .headRefName] | @tsv')

mapfile -t sites < <(ploi_all "/servers/$SERVER/sites" | jq -c --arg suffix ".$DOMAIN" '.[] | select(.domain | endswith($suffix))')
for site in "${sites[@]}"; do
  domain=$(jq -r .domain <<<"$site")
  site_id=$(jq -r .id <<<"$site")
  candidate=${domain%".$DOMAIN"}
  if [[ $domain == "$SOURCE_SITE" || ! $candidate =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ ]]; then continue; fi
  preview_names "$candidate"
  if ! is_preview "$site_id"; then continue; fi
  repository=$(ploi GET "/servers/$SERVER/sites/$site_id/repository" | jq -r '.data.repository | "\(.user)/\(.name)", .name' | tr 'A-Z' 'a-z')
  if ! grep -qxF "$(tr 'A-Z' 'a-z' <<<"$GITHUB_REPOSITORY")" <<<"$repository"; then continue; fi

  pull_request=$(awk -v slug="$candidate" '$1 == slug { print $2; exit }' <<<"$open_previews")
  last_deploy=$(jq -r '.last_deploy_at // .created_at' <<<"$site")
  age_days=$((($(date +%s) - $(date -d "$last_deploy" +%s)) / 86400))
  if [[ -n $pull_request ]] && ((age_days < MAX_AGE_DAYS)); then continue; fi

  remove_preview "$candidate"
  deactivate_deployments
  if [[ -n $pull_request ]]; then
    upsert_comment "$pull_request" "Preview removed after $age_days days without a deployment. Push a commit to recreate it."
  fi
  notice "Pruned $domain"
done
