# shellcheck shell=bash
# Builds the two texts a preview needs: its .env and its deploy script.
# No network calls: scripts/test.sh covers this file.

# The line that separates the copied deploy script from the block this action appends.
DEPLOY_SCRIPT_MARKER='# ploi-preview'

# set_env_value FILE KEY VALUE – replaces the line KEY=... of a .env file, or appends it
set_env_value() {
  local file=$1 key=$2 value=$3

  # Copy every line except the old KEY=... line, then add the new one.
  { grep -v "^$key=" "$file" || true; } >"$file.tmp"
  printf '%s=%s\n' "$key" "$value" >>"$file.tmp"
  mv "$file.tmp" "$file"
}

# read_env_value KEY – reads .env content from its input and prints the value of KEY.
# Usage: read_env_value DB_DATABASE <<<"$env_content"
read_env_value() {
  sed -n "s/^$1=//p" | tail -n1
}

# build_env_file BASE_FILE TARGET_FILE – writes the preview's .env to TARGET_FILE.
# Uses URL, APP_KEY, DB_NAME, DB_PASSWORD and ENV_OVERRIDES.
build_env_file() {
  local base_file=$1 target_file=$2
  local line key value

  cp "$base_file" "$target_file"

  set_env_value "$target_file" APP_URL "$URL"
  set_env_value "$target_file" APP_ENV preview
  set_env_value "$target_file" APP_KEY "$APP_KEY"
  set_env_value "$target_file" DB_CONNECTION mysql
  set_env_value "$target_file" DB_HOST 127.0.0.1
  set_env_value "$target_file" DB_PORT 3306
  set_env_value "$target_file" DB_DATABASE "$DB_NAME"
  set_env_value "$target_file" DB_USERNAME "$DB_NAME"
  set_env_value "$target_file" DB_PASSWORD "$DB_PASSWORD"

  # env-overrides: one KEY=VALUE per line, applied last.
  while IFS= read -r line; do
    if [[ $line == *=* ]]; then
      key=${line%%=*}  # everything before the first "="
      value=${line#*=} # everything after the first "="
      set_env_value "$target_file" "$key" "$value"
    fi
  done <<<"$ENV_OVERRIDES"

  # Last line of defence: whatever the overrides did, the .env must use the preview database.
  if [[ $(grep '^DB_DATABASE=' "$target_file") != "DB_DATABASE=$DB_NAME" ]] \
    || [[ $(grep '^DB_USERNAME=' "$target_file") != "DB_USERNAME=$DB_NAME" ]]; then
    fail "The .env must point at the preview database $DB_NAME. Remove DB_DATABASE and DB_USERNAME from env-overrides."
  fi
}

# build_deploy_script SCRIPT ORIGIN – prints the deploy script of the preview.
# ORIGIN tells where SCRIPT comes from:
#   repository   the file given as deploy-script input
#   source-site  copied from the source site
#   preview      the script Ploi generated for the preview itself
# Uses BRANCH, SOURCE_SITE, PREVIEW_DOMAIN, SYSTEM_USER, PHP_VERSION, FRESH_SEED and POST_DEPLOY_SCRIPT.
build_deploy_script() {
  local script=$1 origin=$2
  local line indentation quoted_branch

  if [[ $origin == source-site ]]; then
    # Point every path at the preview instead of the source site.
    script=${script//"$SOURCE_SITE"/"$PREVIEW_DOMAIN"}
  fi
  if [[ $origin != repository ]]; then
    # Previews install dev dependencies so seeders can use factories and Faker.
    script=${script//' --no-dev'/}
  fi
  # Cut off the block an earlier run appended: everything from the marker line on.
  script=${script%%$'\n'"$DEPLOY_SCRIPT_MARKER"*}

  # "git pull origin <branch>" would pull the source site's branch and breaks on force pushes.
  # Replace it with a fetch and hard reset of the pull request's branch.
  quoted_branch=$(printf %q "$BRANCH") # escaped so a strange branch name cannot inject commands
  while IFS= read -r line; do
    if [[ $line =~ ^([[:space:]]*)git\ pull\ origin ]]; then
      indentation=${BASH_REMATCH[1]}
      line="${indentation}git fetch origin $quoted_branch && git reset --hard FETCH_HEAD"
    fi
    printf '%s\n' "$line"
  done <<<"$script"

  # The block this action appends.
  echo "$DEPLOY_SCRIPT_MARKER"
  echo "cd /home/$SYSTEM_USER/$PREVIEW_DOMAIN"
  if [[ $FRESH_SEED == true ]]; then
    # Reset and seed the database until that worked once (the marker file remembers it),
    # and whenever the action asks for it through PREVIEW_FRESH (fresh-on-update).
    echo 'if [ "${PREVIEW_FRESH:-}" = "1" ] || [ ! -f storage/app/.preview-seeded ]; then'
    echo "  php$PHP_VERSION artisan migrate:fresh --seed --force && touch storage/app/.preview-seeded || exit 1"
    echo 'fi'
  fi
  echo "$POST_DEPLOY_SCRIPT"
}
