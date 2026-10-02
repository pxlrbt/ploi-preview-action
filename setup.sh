#!/usr/bin/env bash
# Sets up Ploi preview environments for the repository in the current directory.
#
#   setup.sh                     ask every question
#   setup.sh --non-interactive   take the defaults; answers come from the environment
#   setup.sh --uninstall         remove secrets, variables, label and workflow again
#
# Every question can be answered up front through its environment variable, e.g.
#   PLOI_API_TOKEN=… PLOI_SERVER=my-server PLOI_SOURCE_SITE=example.com setup.sh --non-interactive
#
# How to read this file: main() lists the steps in order, each step is a function below it.
# The script has to run with the bash 3.2 that macOS ships, so it avoids newer features.
set -euo pipefail

ACTION=pxlrbt/ploi-preview-action
ACTION_VERSION=v1
WORKFLOW=.github/workflows/preview.yml
INTERACTIVE=true
UNINSTALL=false

main() {
  read_options "$@"
  check_prerequisites

  if [[ $UNINSTALL == true ]]; then
    uninstall
    exit 0
  fi

  echo "Setting up Ploi previews for $REPOSITORY"
  ask_for_ploi_token
  ask_for_server_and_source_site
  ask_questions

  store_secrets_and_variables
  write_workflow
  create_env_file
  open_pull_request
  print_summary
}

# --- Helpers -----------------------------------------------------------------

fail() {
  echo "✗ $*" >&2
  exit 1
}

# ask VARIABLE QUESTION [DEFAULT] – stores the answer in VARIABLE.
# A value that is already set in the environment is kept without asking.
ask() {
  local variable=$1 question=$2 default=${3:-}
  local answer=

  if [[ -n ${!variable:-} ]]; then
    return
  fi
  if [[ $INTERACTIVE == true ]]; then
    # /dev/tty is the keyboard; plain input would be the script itself when run through "curl | bash".
    read -r -p "$question${default:+ [$default]}: " answer </dev/tty
  fi
  printf -v "$variable" %s "${answer:-$default}"
}

# ask_secret VARIABLE QUESTION – like ask, but the typed value stays invisible
ask_secret() {
  local variable=$1 question=$2
  local answer=

  if [[ -n ${!variable:-} ]]; then
    return
  fi
  if [[ $INTERACTIVE != true ]]; then
    fail "$variable must be set with --non-interactive."
  fi
  read -r -s -p "$question: " answer </dev/tty
  echo
  printf -v "$variable" %s "$answer"
}

# choose VARIABLE QUESTION OPTION... – lets the user pick one option from a numbered list
choose() {
  local variable=$1 question=$2
  local answer=
  shift 2

  if [[ -n ${!variable:-} ]]; then
    return
  fi
  if [[ $INTERACTIVE != true ]]; then
    fail "$variable must be set with --non-interactive."
  fi
  PS3="$question: "
  select answer in "$@"; do
    if [[ -n $answer ]]; then
      break
    fi
  done </dev/tty
  printf -v "$variable" %s "$answer"
}

# said_yes VARIABLE – true when the answer stored in VARIABLE is y, yes, true or 1
said_yes() {
  local answer
  answer=$(tr 'A-Z' 'a-z' <<<"${!1}")
  [[ $answer =~ ^(y|yes|j|ja|true|1)$ ]]
}

# ploi_get PATH – a GET request to the Ploi API
ploi_get() {
  curl -fsS "https://ploi.io/api$1" \
    -H "Authorization: Bearer $PLOI_API_TOKEN" \
    -H 'Accept: application/json'
}

# --- Steps -------------------------------------------------------------------

read_options() {
  local option
  for option in "$@"; do
    case $option in
      --non-interactive) INTERACTIVE=false ;;
      --uninstall) UNINSTALL=true ;;
      *) fail "Unknown option $option" ;;
    esac
  done
}

# Sets REPOSITORY (owner/name) and moves to the repository root.
check_prerequisites() {
  git rev-parse --show-toplevel >/dev/null 2>&1 || fail "Run this inside a git repository."
  cd "$(git rev-parse --show-toplevel)"

  command -v gh >/dev/null || fail "GitHub CLI missing. Install it from https://cli.github.com and run 'gh auth login'."
  gh auth status >/dev/null 2>&1 || fail "GitHub CLI is not logged in. Run 'gh auth login'."
  command -v jq >/dev/null || fail "jq is missing."
  command -v curl >/dev/null || fail "curl is missing."

  REPOSITORY=$(gh repo view --json nameWithOwner --jq .nameWithOwner)
}

uninstall() {
  local variable

  gh secret delete PLOI_API_TOKEN || true
  gh secret delete PREVIEW_BASIC_AUTH_PASSWORD 2>/dev/null || true
  for variable in PLOI_SERVER PLOI_SOURCE_SITE PREVIEW_DOMAIN; do
    gh variable delete "$variable" || true
  done
  gh label delete preview --yes 2>/dev/null || true
  rm -f "$WORKFLOW"

  echo "✓ Removed the preview setup from $REPOSITORY. Commit the deleted $WORKFLOW."
}

# Sets PLOI_API_TOKEN and SERVERS (the server list, which also proves the token works).
ask_for_ploi_token() {
  if [[ -z ${PLOI_API_TOKEN:-} && $INTERACTIVE == true ]]; then
    echo "Create an API token for this repository at https://ploi.io/profile/api-keys"
    (open https://ploi.io/profile/api-keys || xdg-open https://ploi.io/profile/api-keys) >/dev/null 2>&1 || true
  fi
  ask_secret PLOI_API_TOKEN "Ploi API token"

  # ponytail: only the first 50 servers and sites are offered; paginate if an account outgrows that
  SERVERS=$(ploi_get '/servers?per_page=50') || fail "Ploi rejected the API token."
}

# Sets PLOI_SERVER (name) and PLOI_SOURCE_SITE (domain), both picked from lists.
ask_for_server_and_source_site() {
  local names=() domains=()
  local name domain server_id sites

  while IFS= read -r name; do
    names+=("$name")
  done <<<"$(jq -r '.data[].name' <<<"$SERVERS")"
  choose PLOI_SERVER "Server" "${names[@]}"

  server_id=$(jq -r --arg name "$PLOI_SERVER" \
    '.data[] | select(.name == $name or (.id | tostring) == $name) | .id' <<<"$SERVERS")
  if [[ -z $server_id ]]; then
    fail "Server '$PLOI_SERVER' not found."
  fi

  sites=$(ploi_get "/servers/$server_id/sites?per_page=50")
  while IFS= read -r domain; do
    domains+=("$domain")
  done <<<"$(jq -r '.data[].domain' <<<"$sites")"
  choose PLOI_SOURCE_SITE "Source site (deploy script, queue workers, cronjobs)" "${domains[@]}"
}

ask_questions() {
  local repository_name default_prefix

  # Default database prefix: "preview_<repository>_", cut to the 20 characters the action allows.
  repository_name=$(tr 'A-Z' 'a-z' <<<"${REPOSITORY#*/}" | sed -E 's/[^a-z0-9]+/_/g' | cut -c1-11)
  default_prefix="preview_${repository_name}_"

  ask PREVIEW_DOMAIN "Base domain of the previews (<branch>.<domain>)" "preview.$PLOI_SOURCE_SITE"
  ask SUBDOMAIN_STRATEGY "Subdomain from 'branch' name or 'hash'" branch
  ask DB_PREFIX "Prefix of the preview databases (3-20 characters, unique per project)" "$default_prefix"
  ask ENV_FILE "Env file in the repository" .env.dev
  ask DEPLOY_SCRIPT "Own deploy script in the repository (empty = copy the source site's)" ""
  ask SSL "SSL: 'letsencrypt' or 'none'" letsencrypt
  ask FRESH_SEED "Run migrate:fresh --seed on the first deploy (y/n)" y
  ask FRESH_ON_UPDATE "Reset the database on every push as well (y/n)" n
  ask QUEUES "Copy queue workers (y/n)" n
  ask SCHEDULER "Copy the scheduler cronjobs (y/n)" n
  ask ONLY_WITH_LABEL "Only deploy pull requests labeled 'preview' (y/n)" n
  ask BASIC_AUTH_USER "Basic auth user (empty = no basic auth)" ""
  if [[ -n $BASIC_AUTH_USER ]]; then
    ask_secret BASIC_AUTH_PASSWORD "Basic auth password"
  fi
  ask MAX_AGE_DAYS "Remove previews after days without a deploy (0 = never)" 14
  ask TEST_LOGIN "Test login shown in the pull request comment (empty = none)" ""
  ask OPEN_PULL_REQUEST "Commit the workflow on a branch and open a pull request (y/n)" y
}

# Secrets hold the token and password; plain variables hold what may be changed later
# in the repository settings without touching the workflow.
store_secrets_and_variables() {
  printf %s "$PLOI_API_TOKEN" | gh secret set PLOI_API_TOKEN
  if [[ -n $BASIC_AUTH_USER ]]; then
    printf %s "$BASIC_AUTH_PASSWORD" | gh secret set PREVIEW_BASIC_AUTH_PASSWORD
  fi

  gh variable set PLOI_SERVER --body "$PLOI_SERVER"
  gh variable set PLOI_SOURCE_SITE --body "$PLOI_SOURCE_SITE"
  gh variable set PREVIEW_DOMAIN --body "$PREVIEW_DOMAIN"

  if said_yes ONLY_WITH_LABEL; then
    gh label create preview --description "Deploy a preview environment" --color 5319e7 --force
  fi
}

# --- Workflow file -----------------------------------------------------------

write_workflow() {
  if [[ -f $WORKFLOW && $INTERACTIVE == true ]]; then
    ask OVERWRITE_WORKFLOW "$WORKFLOW exists. Overwrite (y/n)" n
    if ! said_yes OVERWRITE_WORKFLOW; then
      fail "Kept the existing $WORKFLOW. Secrets and variables are set."
    fi
  fi

  mkdir -p "$(dirname "$WORKFLOW")"
  {
    print_workflow_header
    print_deploy_job
    print_cleanup_job
    if [[ $MAX_AGE_DAYS -gt 0 ]]; then
      print_prune_job
    fi
  } >"$WORKFLOW"
}

# input NAME VALUE – prints one line of an action's "with:" block
input() {
  printf '          %s: %s\n' "$1" "$2"
}

# The inputs all three jobs share. The quoted ${{ ... }} parts are GitHub expressions,
# written to the file as they are.
print_connection_inputs() {
  input api-token '${{ secrets.PLOI_API_TOKEN }}'
  input server '${{ vars.PLOI_SERVER }}'
  input domain '${{ vars.PREVIEW_DOMAIN }}'
  input source-site '${{ vars.PLOI_SOURCE_SITE }}'
  input db-prefix "$DB_PREFIX"
  if [[ $SUBDOMAIN_STRATEGY != branch ]]; then
    input subdomain-strategy "$SUBDOMAIN_STRATEGY"
  fi
}

print_workflow_header() {
  local event_types="opened, synchronize, reopened, closed"
  if said_yes ONLY_WITH_LABEL; then
    event_types="opened, synchronize, reopened, labeled, closed"
  fi

  echo "name: Preview"
  echo
  echo "on:"
  echo "  pull_request:"
  echo "    types: [$event_types]"
  if [[ $MAX_AGE_DAYS -gt 0 ]]; then
    echo "  schedule:"
    echo "    - cron: '0 3 * * *'"
  fi
  # <<'YAML' prints the following lines unchanged up to the line "YAML".
  cat <<'YAML'

concurrency:
  group: preview-${{ github.event.pull_request.number || 'prune' }}

permissions:
  contents: read
  pull-requests: write
  deployments: write

jobs:
YAML
}

# Only inputs that differ from the action's defaults are written.
print_deploy_job() {
  cat <<'YAML'
  deploy:
    if: github.event_name == 'pull_request' && github.event.action != 'closed'
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v7
YAML
  echo "      - uses: $ACTION/deploy@$ACTION_VERSION"
  echo "        with:"
  print_connection_inputs

  if [[ $ENV_FILE != .env.dev ]]; then input env-file "$ENV_FILE"; fi
  if [[ -n $DEPLOY_SCRIPT ]]; then input deploy-script "$DEPLOY_SCRIPT"; fi
  if [[ $SSL != letsencrypt ]]; then input ssl "$SSL"; fi
  if ! said_yes FRESH_SEED; then input fresh-seed false; fi
  if said_yes FRESH_ON_UPDATE; then input fresh-on-update true; fi
  if said_yes QUEUES; then input queues true; fi
  if said_yes SCHEDULER; then input scheduler true; fi
  if said_yes ONLY_WITH_LABEL; then input label preview; fi
  if [[ -n $BASIC_AUTH_USER ]]; then
    input basic-auth-user "$BASIC_AUTH_USER"
    input basic-auth-password '${{ secrets.PREVIEW_BASIC_AUTH_PASSWORD }}'
  fi
  if [[ -n $TEST_LOGIN ]]; then
    input comment-template '|'
    echo '            **Preview:** {url}'
    echo '            Branch `{branch}` @ `{sha}`'
    echo "            Login: $TEST_LOGIN"
  fi
}

print_cleanup_job() {
  cat <<'YAML'

  cleanup:
    if: github.event_name == 'pull_request' && github.event.action == 'closed'
    runs-on: ubuntu-latest
    steps:
YAML
  echo "      - uses: $ACTION/cleanup@$ACTION_VERSION"
  echo "        with:"
  print_connection_inputs
}

print_prune_job() {
  cat <<'YAML'

  prune:
    if: github.event_name == 'schedule'
    runs-on: ubuntu-latest
    steps:
YAML
  echo "      - uses: $ACTION/cleanup@$ACTION_VERSION"
  echo "        with:"
  print_connection_inputs
  input max-age-days "$MAX_AGE_DAYS"
}

# --- Env file and pull request -----------------------------------------------

# Creates the env file from .env.example when the repository has none yet:
# preview environment, mail only logged, empty database values. Sets CREATED_ENV_FILE.
create_env_file() {
  CREATED_ENV_FILE=false
  if [[ -f $ENV_FILE || ! -f .env.example ]]; then
    return
  fi

  sed -E \
    -e 's/^APP_ENV=.*/APP_ENV=preview/' \
    -e 's/^APP_DEBUG=.*/APP_DEBUG=true/' \
    -e 's/^MAIL_MAILER=.*/MAIL_MAILER=log/' \
    -e 's/^(DB_(DATABASE|USERNAME|PASSWORD))=.*/\1=/' \
    .env.example >"$ENV_FILE"
  CREATED_ENV_FILE=true
}

open_pull_request() {
  if ! said_yes OPEN_PULL_REQUEST; then
    return
  fi

  git switch -c setup/ploi-preview
  git add "$WORKFLOW"
  if [[ -f $ENV_FILE ]]; then
    git add "$ENV_FILE"
  fi
  git commit -m "Add Ploi preview environments"
  git push -u origin setup/ploi-preview
  gh pr create --title "Add Ploi preview environments" \
    --body "Deploys every pull request to \`<branch>.$PREVIEW_DOMAIN\` and removes the preview when it is closed."
}

print_summary() {
  echo
  echo "✓ Secrets: PLOI_API_TOKEN${BASIC_AUTH_USER:+, PREVIEW_BASIC_AUTH_PASSWORD}"
  echo "✓ Variables: PLOI_SERVER=$PLOI_SERVER, PLOI_SOURCE_SITE=$PLOI_SOURCE_SITE, PREVIEW_DOMAIN=$PREVIEW_DOMAIN"
  echo "✓ Workflow: $WORKFLOW"
  if [[ $CREATED_ENV_FILE == true ]]; then
    echo "✓ Created $ENV_FILE from .env.example – make sure it contains no real credentials for mail, payment or other external services."
  elif [[ ! -f $ENV_FILE ]]; then
    echo "! $ENV_FILE is missing. Commit one before the first preview."
  fi
  echo "Next: make sure *.$PREVIEW_DOMAIN points at the server, then open a pull request."
}

main "$@"
