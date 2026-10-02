#!/usr/bin/env bash
# Loaded first by deploy.sh and cleanup.sh: strict mode, the helper files and input defaults.

# Stop at the first failing command, at unset variables and at failures inside pipelines.
set -euo pipefail
shopt -s inherit_errexit

LIBRARY="$(dirname "${BASH_SOURCE[0]}")/lib"
source "$LIBRARY/actions.sh" # messages, inputs and waiting
source "$LIBRARY/names.sh"   # preview domain and database name, including the safety checks
source "$LIBRARY/files.sh"   # builds the .env and the deploy script
source "$LIBRARY/ploi.sh"    # every call to the Ploi API
source "$LIBRARY/github.sh"  # pull request comment and deployment status

# Optional inputs and their defaults
DRY_RUN=${DRY_RUN:-false}
DB_PREFIX=${DB_PREFIX:-preview_}
SUBDOMAIN_STRATEGY=${SUBDOMAIN_STRATEGY:-branch}
SOURCE_SITE=${SOURCE_SITE:-}

# Filled by load_source_site when a source site is configured
SOURCE_DATABASE=
