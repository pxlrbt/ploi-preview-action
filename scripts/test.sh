#!/usr/bin/env bash
# Checks the naming and safety helpers: bash scripts/test.sh
source "$(dirname "$0")/lib.sh"

assert() {
  if [[ $2 != "$3" ]]; then
    echo "FAIL $1: expected '$3', got '$2'"
    exit 1
  fi
}

# refuses DESCRIPTION COMMAND... – passes when the command aborts
refuses() {
  local description=$1
  shift
  if ("$@") >/dev/null 2>&1; then
    echo "FAIL $description: expected a refusal"
    exit 1
  fi
}

DOMAIN=dash.pxlrbt.de
long_branch=feature/JIRA-1234-a-very-long-branch-name-that-never-seems-to-end-at-all

assert 'slug lowercases and replaces symbols' "$(slug 'Feature/Add_Login!')" feature-add-login
assert 'slug trims dashes' "$(slug '--fix--')" fix
assert 'long slug fits the domain into 64 characters' "$(slug "$long_branch" | wc -c | tr -d ' ')" 50
assert 'long slugs stay unique' "$([[ $(slug "$long_branch") != $(slug "${long_branch}2") ]] && echo yes)" yes
assert 'symbol-only branch falls back to a hash' "$(slug '///' | wc -c | tr -d ' ')" 9
assert 'hash strategy' "$(SUBDOMAIN_STRATEGY=hash slug main)" "$(hash8 main)"

assert 'database name' "$(db_name feature-add-login)" preview_feature_add_login
assert 'long database name is capped at 32' "$(db_name "$(slug "$long_branch")" | wc -c | tr -d ' ')" 33
assert 'long database name keeps the prefix' "$(db_name "$(slug "$long_branch")" | cut -c1-8)" preview_

preview_names fix-login
assert 'preview domain' "$PREVIEW_DOMAIN" fix-login.dash.pxlrbt.de
assert 'preview database' "$DB_NAME" preview_fix_login

refuses 'slug with a dot' preview_names evil.sub
refuses 'empty slug' preview_names ''
DB_PREFIX=p_ refuses 'short prefix' preview_names main
DOMAIN=pxlrbt.de SOURCE_SITE=dash.pxlrbt.de refuses 'source site as preview' preview_names dash
SOURCE_DATABASE=preview_main refuses 'source database' preview_names main

env_file=$(mktemp)
printf 'APP_ENV=local\nDB_DATABASE=production\nMAIL_MAILER=smtp' >"$env_file"
set_env "$env_file" DB_DATABASE preview_main
set_env "$env_file" APP_KEY 'base64:a+b/c='
assert 'set_env replaces and appends' "$(cat "$env_file")" $'APP_ENV=local\nMAIL_MAILER=smtp\nDB_DATABASE=preview_main\nAPP_KEY=base64:a+b/c='
rm "$env_file"

echo 'All checks passed.'
