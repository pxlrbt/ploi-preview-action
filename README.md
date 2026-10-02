# Ploi Preview Action

Two composite GitHub Actions that give every pull request of a Laravel project its own preview site on a [Ploi](https://ploi.io) server and remove it again when the pull request is closed.

- `deploy` creates the site `<branch>.<domain>` with its own MySQL database and user, builds the `.env`, deploys the branch and comments the link on the pull request.
- `cleanup` deletes the site, database and database user. On a schedule it prunes stale and orphaned previews.

## Setup

Run this inside the repository that should get previews. It asks a few questions, sets the secret and variables with `gh` and writes the workflow:

```bash
curl -fsSL https://raw.githubusercontent.com/pxlrbt/ploi-preview-action/main/setup.sh | bash
```

Requirements: `gh` (logged in), `jq`, `curl`, a Ploi API token and a wildcard DNS record `*.<domain>` pointing at the server. `setup.sh --uninstall` removes everything again; `setup.sh --non-interactive` takes answers from environment variables (see the header of the script).

## Workflow

```yaml
name: Preview

on:
  pull_request:
    types: [opened, synchronize, reopened, closed]
  schedule:
    - cron: '0 3 * * *'

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
      - uses: pxlrbt/ploi-preview-action/deploy@v1
        with:
          api-token: ${{ secrets.PLOI_API_TOKEN }}
          server: my-server
          domain: preview.example.com
          source-site: example.com

  cleanup:
    if: github.event_name == 'pull_request' && github.event.action == 'closed'
    runs-on: ubuntu-latest
    steps:
      - uses: pxlrbt/ploi-preview-action/cleanup@v1
        with:
          api-token: ${{ secrets.PLOI_API_TOKEN }}
          server: my-server
          domain: preview.example.com
          source-site: example.com

  prune:
    if: github.event_name == 'schedule'
    runs-on: ubuntu-latest
    steps:
      - uses: pxlrbt/ploi-preview-action/cleanup@v1
        with:
          api-token: ${{ secrets.PLOI_API_TOKEN }}
          server: my-server
          domain: preview.example.com
          source-site: example.com
          max-age-days: 14
```

## Inputs

| Input | Default | Description |
| --- | --- | --- |
| `api-token` | required | Ploi API token |
| `server` | required | Ploi server id or name |
| `domain` | required | Base domain; previews are served from `<slug>.<domain>` |
| `subdomain-strategy` | `branch` | `branch` (kebab-cased branch name) or `hash` (8 characters) |
| `source-site` | | Site whose deploy script, PHP version, queue workers and cronjobs are copied |
| `deploy-script` | | Path to a deploy script in the repository; replaces the one of the source site |
| `env-file` | `.env.dev` | File in the repository that is the base of the preview's `.env` |
| `env-overrides` | | Additional `KEY=VALUE` lines that win over `env-file` |
| `fresh-seed` | `true` | Run `php artisan migrate:fresh --seed --force` on the first deploy |
| `fresh-on-update` | `false` | Also reset the database on every later deploy |
| `post-deploy-script` | | Bash that runs on the server at the end of every deploy |
| `ssl` | `letsencrypt` | `letsencrypt` or `none` |
| `queues` | `false` | Copy the queue workers of the source site |
| `scheduler` | `false` | Copy the cronjobs of the source site |
| `basic-auth-user`, `basic-auth-password` | | Protect the preview with basic auth |
| `label` | | Only deploy pull requests that carry this label |
| `db-prefix` | `preview_` | Mandatory prefix of the database and its user |
| `comment-template` | | Markdown for the comment; placeholders `{url}`, `{branch}`, `{sha}`, `{database}` |
| `dry-run` | `false` | Only log the changes that would be made on Ploi |
| `max-age-days` | `0` | `cleanup` only: on scheduled runs, remove previews not deployed for this many days |

`cleanup` takes `api-token`, `server`, `domain`, `subdomain-strategy`, `source-site`, `db-prefix`, `max-age-days` and `dry-run`. Pass it the same `subdomain-strategy` and `db-prefix` as `deploy`.

`deploy` outputs `url`, `site-id` and `database`.

## How the preview is built

- The `.env` starts from `env-file`. `APP_URL`, `APP_ENV=preview`, a new `APP_KEY` and the `DB_*` values are forced, then `env-overrides` are applied. The production `.env` is never read into the preview, so keep real credentials for mail, payment and other external services out of `env-file`.
- The deploy script is copied from `source-site` with its domain replaced. `git pull origin …` becomes a fetch and hard reset of the pull request's branch, so force pushes work.
- Every preview sends `X-Robots-Tag: noindex`.
- Two branches whose names differ only in punctuation (`fix/login`, `fix-login`) share a slug. Use `subdomain-strategy: hash` if that can happen.

## Safety

Previews often live next to production sites, so several independent checks guard every destructive call:

- Databases and users are only created and deleted with `db-prefix`, and never under the name of the source site's database.
- Each preview gets its own database user.
- A site only counts as a preview while its prefixed database is linked to it in Ploi. Anything else is never redeployed or deleted.
- The source site itself is never touched; scheduled pruning additionally only removes sites that were installed from the same GitHub repository.
- Pull requests from forks are skipped.

## Limitations

- Ploi's API cannot assign an existing wildcard certificate to a new site, so each preview requests its own Let's Encrypt certificate (mind the limit of 50 certificates per registered domain and week).
- MySQL only.

## Development

```bash
bash scripts/test.sh
```
