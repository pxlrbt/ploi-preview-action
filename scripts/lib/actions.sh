# shellcheck shell=bash
# Helpers around GitHub Actions: messages, inputs, the event payload and waiting.

# fail MESSAGE – shows the message as an error in the workflow run and stops the script
fail() {
  echo "::error::$*" >&2
  exit 1
}

# notice MESSAGE – shows the message as a highlighted note in the workflow run
notice() {
  echo "::notice::$*"
}

# hide_in_logs VALUE... – tells GitHub to replace these values with *** in all log output
hide_in_logs() {
  local value
  for value in "$@"; do
    if [[ -n $value ]]; then
      echo "::add-mask::$value"
    fi
  done
}

# require_inputs VARIABLE... – stops when one of the named inputs is empty
require_inputs() {
  local variable input_name
  for variable in "$@"; do
    # ${!variable} reads the variable whose name is stored in $variable.
    if [[ -z ${!variable:-} ]]; then
      input_name=$(tr 'A-Z_' 'a-z-' <<<"$variable")
      fail "Input '$input_name' is required."
    fi
  done
}

# event_value JQ_PATH – one value of the event that triggered the workflow, empty when missing.
# GitHub stores the event as JSON in the file $GITHUB_EVENT_PATH.
event_value() {
  jq -r "$1 // empty" "$GITHUB_EVENT_PATH"
}

# pull_request_has_label LABEL
pull_request_has_label() {
  jq -e --arg label "$1" 'any(.pull_request.labels[]?; .name == $label)' "$GITHUB_EVENT_PATH" >/dev/null
}

# Pull requests from forks get no secrets, so there is nothing to deploy or clean up.
skip_pull_requests_from_forks() {
  local head_repository
  head_repository=$(event_value .pull_request.head.repo.full_name)
  if [[ -n $head_repository && $head_repository != "$GITHUB_REPOSITORY" ]]; then
    notice "Pull requests from forks get no preview."
    exit 0
  fi
}

# wait_until SECONDS DESCRIPTION COMMAND... – runs COMMAND every 5 seconds until it succeeds,
# and stops the script when that takes longer than SECONDS
wait_until() {
  local timeout=$1 description=$2
  local deadline=$((SECONDS + timeout))
  shift 2 # what is left in "$@" is the command

  if [[ $DRY_RUN == true ]]; then
    return
  fi
  until "$@"; do
    if [[ $SECONDS -ge $deadline ]]; then
      fail "Timed out waiting for $description."
    fi
    sleep 5
  done
}
