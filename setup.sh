#!/usr/bin/env bash
# Sets up Ploi preview environments for the repository in the current directory.
#
#   setup.sh                     ask every question
#   setup.sh --non-interactive   take defaults; answers come from the environment
#   setup.sh --uninstall         remove secrets, variables, label and workflow again
#
# Every question can be answered up front through its environment variable, e.g.
#   PLOI_API_TOKEN=… PLOI_SERVER=my-server PLOI_SOURCE_SITE=example.com PREVIEW_DOMAIN=preview.example.com setup.sh --non-interactive
set -euo pipefail

ACTION=pxlrbt/ploi-preview-action
ACTION_VERSION=v1
WORKFLOW=.github/workflows/preview.yml
INTERACTIVE=true
UNINSTALL=false

for argument in "$@"; do
  case $argument in
    --non-interactive) INTERACTIVE=false ;;
    --uninstall) UNINSTALL=true ;;
    *) echo "Unknown option $argument" >&2 && exit 1 ;;
  esac
done

fail() {
  echo "✗ $*" >&2
  exit 1
}

# ask VARIABLE QUESTION [DEFAULT] – keeps a value that is already set in the environment
ask() {
  local name=$1 question=$2 default=${3:-} answer
  if [[ -n ${!name:-} ]]; then return; fi
  if [[ $INTERACTIVE == true ]]; then
    read -r -p "$question${default:+ [$default]}: " answer </dev/tty
  fi
  printf -v "$name" %s "${answer:-$default}"
}

# choose VARIABLE QUESTION OPTION... – pick one option from a numbered list
choose() {
  local name=$1 question=$2 answer
  shift 2
  if [[ -n ${!name:-} ]]; then return; fi
  if [[ $INTERACTIVE != true ]]; then fail "$name must be set with --non-interactive."; fi
  PS3="$question: "
  select answer in "$@"; do
    if [[ -n $answer ]]; then break; fi
  done </dev/tty
  printf -v "$name" %s "$answer"
}

# confirmed VARIABLE – true for y, yes, true or 1
confirmed() {
  [[ $(tr 'A-Z' 'a-z' <<<"${!1}") =~ ^(y|yes|j|ja|true|1)$ ]]
}

# options COMMAND... – prints nothing itself; fills the array OPTIONS (macOS ships bash 3.2 without mapfile)
options() {
  local line
  OPTIONS=()
  while IFS= read -r line; do OPTIONS+=("$line"); done < <("$@")
}

ploi() {
  curl -fsS "https://ploi.io/api$1" -H "Authorization: Bearer $PLOI_API_TOKEN" -H 'Accept: application/json'
}

# --- Prerequisites -----------------------------------------------------------

git rev-parse --show-toplevel >/dev/null 2>&1 || fail "Run this inside a git repository."
cd "$(git rev-parse --show-toplevel)"
command -v gh >/dev/null || fail "GitHub CLI missing. Install it from https://cli.github.com and run 'gh auth login'."
gh auth status >/dev/null 2>&1 || fail "GitHub CLI is not logged in. Run 'gh auth login'."
command -v jq >/dev/null || fail "jq is missing."
command -v curl >/dev/null || fail "curl is missing."
REPOSITORY=$(gh repo view --json nameWithOwner --jq .nameWithOwner)

if [[ $UNINSTALL == true ]]; then
  gh secret delete PLOI_API_TOKEN || true
  gh secret delete PREVIEW_BASIC_AUTH_PASSWORD 2>/dev/null || true
  for variable in PLOI_SERVER PLOI_SOURCE_SITE PREVIEW_DOMAIN; do
    gh variable delete "$variable" || true
  done
  gh label delete preview --yes 2>/dev/null || true
  rm -f "$WORKFLOW"
  echo "✓ Removed the preview setup from $REPOSITORY. Commit the deleted $WORKFLOW."
  exit 0
fi

echo "Setting up Ploi previews for $REPOSITORY"

# --- Ploi --------------------------------------------------------------------

if [[ -z ${PLOI_API_TOKEN:-} ]]; then
  if [[ $INTERACTIVE != true ]]; then fail "PLOI_API_TOKEN must be set with --non-interactive."; fi
  echo "Create an API token for this repository at https://ploi.io/profile/api-keys"
  (open https://ploi.io/profile/api-keys || xdg-open https://ploi.io/profile/api-keys) >/dev/null 2>&1 || true
  read -r -s -p "Ploi API token: " PLOI_API_TOKEN </dev/tty
  echo
fi
servers=$(ploi '/servers?per_page=50') || fail "Ploi rejected the API token."

# ponytail: only the first 50 servers and sites are offered; paginate if an account outgrows that
options jq -r '.data[].name' <<<"$servers"
choose PLOI_SERVER "Server" "${OPTIONS[@]}"
server_id=$(jq -r --arg name "$PLOI_SERVER" '.data[] | select(.name == $name or (.id | tostring) == $name) | .id' <<<"$servers")
if [[ -z $server_id ]]; then fail "Server '$PLOI_SERVER' not found."; fi

sites=$(ploi "/servers/$server_id/sites?per_page=50")
options jq -r '.data[].domain' <<<"$sites"
choose PLOI_SOURCE_SITE "Source site (deploy script, queue workers, cronjobs)" "${OPTIONS[@]}"

# --- Questions ---------------------------------------------------------------

ask PREVIEW_DOMAIN "Base domain of the previews (<branch>.<domain>)" "preview.$PLOI_SOURCE_SITE"
ask SUBDOMAIN_STRATEGY "Subdomain from 'branch' name or 'hash'" branch
ask ENV_FILE "Env file in the repository" .env.dev
ask DEPLOY_SCRIPT "Own deploy script in the repository (empty = copy the source site's)" ""
ask SSL "SSL: 'letsencrypt' or 'none'" letsencrypt
ask FRESH_SEED "Run migrate:fresh --seed on the first deploy (y/n)" y
ask FRESH_ON_UPDATE "Reset the database on every push as well (y/n)" n
ask QUEUES "Copy queue workers (y/n)" n
ask SCHEDULER "Copy the scheduler cronjobs (y/n)" n
ask ONLY_WITH_LABEL "Only deploy pull requests labeled 'preview' (y/n)" n
ask BASIC_AUTH_USER "Basic auth user (empty = no basic auth)" ""
if [[ -n $BASIC_AUTH_USER && -z ${BASIC_AUTH_PASSWORD:-} ]]; then
  if [[ $INTERACTIVE != true ]]; then fail "BASIC_AUTH_PASSWORD must be set with --non-interactive."; fi
  read -r -s -p "Basic auth password: " BASIC_AUTH_PASSWORD </dev/tty
  echo
fi
ask MAX_AGE_DAYS "Remove previews after days without a deploy (0 = never)" 14
ask TEST_LOGIN "Test login shown in the pull request comment (empty = none)" ""
ask OPEN_PULL_REQUEST "Commit the workflow on a branch and open a pull request (y/n)" y

# --- GitHub ------------------------------------------------------------------

printf %s "$PLOI_API_TOKEN" | gh secret set PLOI_API_TOKEN
gh variable set PLOI_SERVER --body "$PLOI_SERVER"
gh variable set PLOI_SOURCE_SITE --body "$PLOI_SOURCE_SITE"
gh variable set PREVIEW_DOMAIN --body "$PREVIEW_DOMAIN"
if [[ -n $BASIC_AUTH_USER ]]; then
  printf %s "$BASIC_AUTH_PASSWORD" | gh secret set PREVIEW_BASIC_AUTH_PASSWORD
fi
if confirmed ONLY_WITH_LABEL; then
  gh label create preview --description "Deploy a preview environment" --color 5319e7 --force
fi

# --- Workflow ----------------------------------------------------------------

if [[ -f $WORKFLOW && $INTERACTIVE == true ]]; then
  ask OVERWRITE_WORKFLOW "$WORKFLOW exists. Overwrite (y/n)" n
  if ! confirmed OVERWRITE_WORKFLOW; then fail "Kept the existing $WORKFLOW. Secrets and variables are set."; fi
fi

# input NAME VALUE – one line of an action's "with:" block
input() {
  printf '          %s: %s\n' "$1" "$2"
}

connection=$(
  input api-token '${{ secrets.PLOI_API_TOKEN }}'
  input server '${{ vars.PLOI_SERVER }}'
  input domain '${{ vars.PREVIEW_DOMAIN }}'
  input source-site '${{ vars.PLOI_SOURCE_SITE }}'
  if [[ $SUBDOMAIN_STRATEGY != branch ]]; then input subdomain-strategy "$SUBDOMAIN_STRATEGY"; fi
)
event_types="opened, synchronize, reopened, closed"
if confirmed ONLY_WITH_LABEL; then event_types="opened, synchronize, reopened, labeled, closed"; fi

mkdir -p "$(dirname "$WORKFLOW")"
{
  echo "name: Preview"
  echo
  echo "on:"
  echo "  pull_request:"
  echo "    types: [$event_types]"
  if ((MAX_AGE_DAYS > 0)); then
    echo "  schedule:"
    echo "    - cron: '0 3 * * *'"
  fi
  cat <<'YAML'

concurrency:
  group: preview-${{ github.event.pull_request.number || 'prune' }}

permissions:
  contents: read
  pull-requests: write
  deployments: write

jobs:
  deploy:
    if: github.event_name == 'pull_request' && github.event.action != 'closed'
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v7
YAML
  echo "      - uses: $ACTION/deploy@$ACTION_VERSION"
  echo "        with:"
  echo "$connection"
  if [[ $ENV_FILE != .env.dev ]]; then input env-file "$ENV_FILE"; fi
  if [[ -n $DEPLOY_SCRIPT ]]; then input deploy-script "$DEPLOY_SCRIPT"; fi
  if [[ $SSL != letsencrypt ]]; then input ssl "$SSL"; fi
  if ! confirmed FRESH_SEED; then input fresh-seed false; fi
  if confirmed FRESH_ON_UPDATE; then input fresh-on-update true; fi
  if confirmed QUEUES; then input queues true; fi
  if confirmed SCHEDULER; then input scheduler true; fi
  if confirmed ONLY_WITH_LABEL; then input label preview; fi
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
  cat <<'YAML'

  cleanup:
    if: github.event_name == 'pull_request' && github.event.action == 'closed'
    runs-on: ubuntu-latest
    steps:
YAML
  echo "      - uses: $ACTION/cleanup@$ACTION_VERSION"
  echo "        with:"
  echo "$connection"
  if ((MAX_AGE_DAYS > 0)); then
    cat <<'YAML'

  prune:
    if: github.event_name == 'schedule'
    runs-on: ubuntu-latest
    steps:
YAML
    echo "      - uses: $ACTION/cleanup@$ACTION_VERSION"
    echo "        with:"
    echo "$connection"
    input max-age-days "$MAX_AGE_DAYS"
  fi
} >"$WORKFLOW"

# --- Env file ----------------------------------------------------------------

created_env_file=false
if [[ ! -f $ENV_FILE && -f .env.example ]]; then
  sed -E 's/^APP_ENV=.*/APP_ENV=preview/; s/^APP_DEBUG=.*/APP_DEBUG=true/; s/^MAIL_MAILER=.*/MAIL_MAILER=log/; s/^(DB_(DATABASE|USERNAME|PASSWORD))=.*/\1=/' \
    .env.example >"$ENV_FILE"
  created_env_file=true
fi

# --- Pull request ------------------------------------------------------------

if confirmed OPEN_PULL_REQUEST; then
  git switch -c setup/ploi-preview
  git add "$WORKFLOW"
  if [[ -f $ENV_FILE ]]; then git add "$ENV_FILE"; fi
  git commit -m "Add Ploi preview environments"
  git push -u origin setup/ploi-preview
  gh pr create --title "Add Ploi preview environments" \
    --body "Deploys every pull request to \`<branch>.$PREVIEW_DOMAIN\` and removes the preview when it is closed."
fi

echo
echo "✓ Secrets: PLOI_API_TOKEN${BASIC_AUTH_USER:+, PREVIEW_BASIC_AUTH_PASSWORD}"
echo "✓ Variables: PLOI_SERVER=$PLOI_SERVER, PLOI_SOURCE_SITE=$PLOI_SOURCE_SITE, PREVIEW_DOMAIN=$PREVIEW_DOMAIN"
echo "✓ Workflow: $WORKFLOW"
if [[ $created_env_file == true ]]; then
  echo "✓ Created $ENV_FILE from .env.example – make sure it contains no real credentials for mail, payment or other external services."
elif [[ ! -f $ENV_FILE ]]; then
  echo "! $ENV_FILE is missing. Commit one before the first preview."
fi
echo "Next: make sure *.$PREVIEW_DOMAIN points at the server, then open a pull request."
