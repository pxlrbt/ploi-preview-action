# shellcheck shell=bash
# Turns a branch name into the preview's domain and database name, and refuses names
# that could point at anything but a preview. No network calls: scripts/test.sh covers this file.

# short_hash TEXT – the first 8 characters of the text's SHA-1 hash
short_hash() {
  printf %s "$1" | shasum | cut -c1-8
}

# is_valid_slug SLUG – only a-z, 0-9 and dashes, no dash at either end, no dots
is_valid_slug() {
  [[ $1 =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ ]]
}

# preview_slug BRANCH – the subdomain of the preview, e.g. "Fix/Login_Form" becomes "fix-login-form"
preview_slug() {
  local branch=$1
  local slug max_length

  if [[ $SUBDOMAIN_STRATEGY == hash ]]; then
    short_hash "$branch"
    return
  fi

  # Lowercase, replace every run of other characters with one dash, trim dashes at both ends.
  slug=$(tr 'A-Z' 'a-z' <<<"$branch" | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//')
  if [[ -z $slug ]]; then
    short_hash "$branch"
    return
  fi

  # Let's Encrypt allows 64 characters for <slug>.<domain>. Longer slugs are cut and get
  # a hash of the full branch name appended, so two long branches never share a preview.
  max_length=$((63 - ${#DOMAIN}))
  if [[ $max_length -lt 20 ]]; then
    max_length=20
  fi
  if [[ ${#slug} -gt $max_length ]]; then
    slug=${slug:0:max_length-9} # leaves room for "-" and the 8 hash characters
    slug="${slug%-}-$(short_hash "$branch")"
  fi

  echo "$slug"
}

# database_name SLUG – prefix plus slug with underscores. The name is also used for the
# database user, and MySQL allows only 32 characters there.
database_name() {
  local slug=$1
  local name="$DB_PREFIX${slug//-/_}"

  if [[ ${#name} -gt 32 ]]; then
    name="${name:0:23}_$(short_hash "$slug")"
  fi

  echo "$name"
}

# set_preview_names SLUG – sets SLUG, PREVIEW_DOMAIN and DB_NAME.
# Stops the script when one of them could address something that is not a preview.
set_preview_names() {
  SLUG=$1
  PREVIEW_DOMAIN="$SLUG.$DOMAIN"
  DB_NAME=$(database_name "$SLUG")

  if [[ ${#DB_PREFIX} -lt 3 || ${#DB_PREFIX} -gt 20 ]]; then
    fail "db-prefix must be 3 to 20 characters long."
  fi
  if ! is_valid_slug "$SLUG"; then
    fail "Refusing unsafe preview name '$SLUG'."
  fi
  if [[ $PREVIEW_DOMAIN == "$SOURCE_SITE" ]]; then
    fail "The preview domain $PREVIEW_DOMAIN is the source site."
  fi
  if [[ $DB_NAME != "$DB_PREFIX"* ]]; then
    fail "Refusing database name '$DB_NAME': it does not start with the prefix '$DB_PREFIX'."
  fi
  if [[ $DB_NAME == "$SOURCE_DATABASE" ]]; then
    fail "Refusing database name '$DB_NAME': it is the database of the source site."
  fi
}
