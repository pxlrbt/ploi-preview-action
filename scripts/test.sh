#!/usr/bin/env bash
# Checks everything that works without the network: names, safety checks, .env and deploy script.
# Run with: bash scripts/test.sh
source "$(dirname "$0")/lib.sh"

# assert DESCRIPTION ACTUAL EXPECTED
assert() {
  if [[ $2 != "$3" ]]; then
    echo "FAIL $1"
    echo "  expected: $3"
    echo "  got:      $2"
    exit 1
  fi
}

# refuses DESCRIPTION COMMAND... – passes when the command stops the script
refuses() {
  local description=$1
  shift
  if ("$@") >/dev/null 2>&1; then
    echo "FAIL $description: expected a refusal"
    exit 1
  fi
}

# length TEXT
length() {
  printf %s "$1" | wc -c | tr -d ' '
}

DOMAIN=dash.pxlrbt.de
long_branch=feature/JIRA-1234-a-very-long-branch-name-that-never-seems-to-end-at-all

# --- Preview slug ------------------------------------------------------------

assert 'slug lowercases and replaces symbols' "$(preview_slug 'Feature/Add_Login!')" feature-add-login
assert 'slug trims dashes' "$(preview_slug '--fix--')" fix
assert 'long slug keeps <slug>.<domain> within 64 characters' "$(length "$(preview_slug "$long_branch")")" 49
assert 'long slugs stay unique' \
  "$([[ $(preview_slug "$long_branch") != $(preview_slug "${long_branch}2") ]] && echo yes)" yes
assert 'branch of symbols only falls back to a hash' "$(length "$(preview_slug '///')")" 8
assert 'hash strategy' "$(SUBDOMAIN_STRATEGY=hash preview_slug main)" "$(short_hash main)"

# --- Database name -----------------------------------------------------------

assert 'database name' "$(database_name feature-add-login)" preview_feature_add_login
assert 'long database name is capped at 32' "$(length "$(database_name "$(preview_slug "$long_branch")")")" 32
assert 'long database name keeps the prefix' "$(database_name "$(preview_slug "$long_branch")" | cut -c1-8)" preview_

# --- Safety checks -----------------------------------------------------------

set_preview_names fix-login
assert 'preview domain' "$PREVIEW_DOMAIN" fix-login.dash.pxlrbt.de
assert 'preview database' "$DB_NAME" preview_fix_login

refuses 'slug with a dot' set_preview_names evil.sub
refuses 'empty slug' set_preview_names ''
DB_PREFIX=p_ refuses 'short prefix' set_preview_names main
DOMAIN=pxlrbt.de SOURCE_SITE=dash.pxlrbt.de refuses 'source site as preview' set_preview_names dash
SOURCE_DATABASE=preview_main refuses 'source database' set_preview_names main

# --- .env --------------------------------------------------------------------

base_file=$(mktemp)
env_file=$(mktemp)
printf 'APP_ENV=local\nDB_DATABASE=production\nMAIL_MAILER=smtp' >"$base_file"

set_preview_names main
URL=https://main.dash.pxlrbt.de
APP_KEY='base64:a+b/c='
DB_PASSWORD=secret
ENV_OVERRIDES=$'MAIL_MAILER=log\nAPP_NAME=Preview'
build_env_file "$base_file" "$env_file"

assert 'the .env forces the preview values and applies overrides' "$(cat "$env_file")" 'APP_URL=https://main.dash.pxlrbt.de
APP_ENV=preview
APP_KEY=base64:a+b/c=
DB_CONNECTION=mysql
DB_HOST=127.0.0.1
DB_PORT=3306
DB_DATABASE=preview_main
DB_USERNAME=preview_main
DB_PASSWORD=secret
MAIL_MAILER=log
APP_NAME=Preview'
assert 'read_env_value' "$(read_env_value DB_DATABASE <"$env_file")" preview_main

ENV_OVERRIDES='DB_DATABASE=production' refuses 'override pointing at another database' build_env_file "$base_file" "$env_file"
rm "$base_file" "$env_file"

# --- Deploy script -----------------------------------------------------------

BRANCH=fix/login
SOURCE_SITE=dash.pxlrbt.de
SYSTEM_USER=ploi
PHP_VERSION=8.5
FRESH_SEED=true
POST_DEPLOY_SCRIPT='php artisan about'
set_preview_names fix-login

source_script='cd /home/ploi/dash.pxlrbt.de
git pull origin main
composer install --no-interaction --no-dev
php artisan migrate --force'

expected_script='cd /home/ploi/fix-login.dash.pxlrbt.de
git fetch origin fix/login && git reset --hard FETCH_HEAD
composer install --no-interaction
php artisan migrate --force
# ploi-preview
cd /home/ploi/fix-login.dash.pxlrbt.de
if [ "${PREVIEW_FRESH:-}" = "1" ] || [ ! -f storage/app/.preview-seeded ]; then
  php8.5 artisan migrate:fresh --seed --force && touch storage/app/.preview-seeded || exit 1
fi
php artisan about'

assert 'deploy script copied from the source site' "$(build_deploy_script "$source_script" source-site)" "$expected_script"
assert 'building it again from its own output changes nothing' \
  "$(build_deploy_script "$expected_script" preview)" "$expected_script"
assert 'a script from the repository keeps --no-dev' \
  "$(build_deploy_script 'composer install --no-dev' repository | head -n1)" 'composer install --no-dev'
assert 'a hostile branch name is escaped' \
  "$(BRANCH='x; rm -rf /' build_deploy_script 'git pull origin main' preview | head -n1)" \
  'git fetch origin x\;\ rm\ -rf\ / && git reset --hard FETCH_HEAD'
assert 'without fresh-seed nothing is migrated' \
  "$(FRESH_SEED=false build_deploy_script 'true' preview | grep -c migrate:fresh || true)" 0

echo 'All checks passed.'
