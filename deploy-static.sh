#!/usr/bin/env bash
# Collects the Django static files and deploys them to Cloudflare Workers with
# wrangler.
#
# Deploys as an "assets-only" Worker (no server code): wrangler uploads
# staticfiles/ and Cloudflare serves it. In the dashboard this is
# Workers & Pages -> $CF_WORKER_NAME.
#
# This is the STATIC half of the deployment. The application is deployed
# separately by deploy-be.sh, to the VPS.
#
# The two are genuinely independent: Django keeps the url() references inside
# collected CSS relative and only applies STATIC_URL at render time, so what is
# uploaded here does not depend on where it ends up being served from. Pointing
# the shop at a different STATIC_URL needs a deploy-be.sh run, not a re-upload.
#
# Media is NOT deployed here. Product images and easy-thumbnails output are
# written at runtime by the Oscar dashboard, so they are served from the VPS —
# see the SERVE_MEDIA branch in config/urls.py.
#
# Reads deploy.env for the Cloudflare credentials; both files are gitignored.
# Requires Bun (https://bun.sh). Wrangler runs through `bun x`, so it needs no
# global install.
#
#   ./deploy-static.sh              collect and deploy
#   DRY_RUN=1 ./deploy-static.sh    collect and validate, stop before uploading
#
# CF_STATIC_DOMAIN is attached as a Cloudflare custom domain, which creates the
# DNS record too — so the hostname is known in advance and this can be run
# before or after deploy-be.sh. The API token needs Zone -> Workers Routes ->
# Edit for that; without it wrangler fails on the route after the assets have
# already uploaded.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# Optional — see the same block in deploy-be.sh. CI supplies these from the
# environment instead of a file.
ENV_FILE="${1:-$SCRIPT_DIR/deploy.env}"
if [[ -f "$ENV_FILE" ]]; then
    # shellcheck disable=SC1090
    source "$ENV_FILE"
    CONFIG_SOURCE="$ENV_FILE"
elif [[ -n "${1:-}" ]]; then
    echo "error: env file not found: $ENV_FILE" >&2
    exit 1
else
    CONFIG_SOURCE="the environment (no $ENV_FILE present)"
fi

# --- Configuration ------------------------------------------------------------
# Every project-specific value comes from $ENV_FILE — no Worker name, hostname
# or credential is written into this script, so it deploys any target you point
# it at with a different env file.
_missing=()
require() { [[ -n "${!1:-}" ]] || _missing+=("$1"); }

require CLOUDFLARE_API_TOKEN   # "Edit Cloudflare Workers" template
require CLOUDFLARE_ACCOUNT_ID  # right-hand side of any dashboard page
require CF_WORKER_NAME         # the Worker this uploads to — it REPLACES its assets
require STATIC_URL             # must match CF_STATIC_DOMAIN; checked below

if ((${#_missing[@]})); then
    echo "error: the following must be set in $CONFIG_SOURCE:" >&2
    printf '         %s\n' "${_missing[@]}" >&2
    exit 1
fi

# Optional: empty serves from the *.workers.dev URL instead of a custom domain.
CF_STATIC_DOMAIN="${CF_STATIC_DOMAIN:-}"

# Pins Workers runtime behaviour. Must be >= 2025-04-01 for requests to be
# served from static assets without invoking a Worker script.
CF_COMPATIBILITY_DATE="${CF_COMPATIBILITY_DATE:-2025-04-01}"

# Pinned deliberately. `bun x wrangler` unpinned resolves the `latest` dist-tag
# on every run, which makes each deploy depend on whatever Cloudflare published
# most recently — and a bad release then breaks deploys that changed nothing.
# That is not hypothetical: 4.117.0 declares `miniflare@5.x-alpha` as a
# dependency, which bun refuses to resolve, so every deploy failed until this
# was pinned. 4.116.0 is the last release before that.
#
# Bump deliberately, after checking the new version actually runs:
#     bun x wrangler@<version> --version
WRANGLER_VERSION="${WRANGLER_VERSION:-4.116.0}"

export CLOUDFLARE_API_TOKEN CLOUDFLARE_ACCOUNT_ID

WRANGLER=(bun x "wrangler@$WRANGLER_VERSION")
# Mirrors STATIC_ROOT in config/settings.py. Not a deploy.env setting: it is a
# code-level path, and the two must not be able to drift independently.
DIST="staticfiles"

echo "==> Cloudflare Worker: $CF_WORKER_NAME (wrangler $WRANGLER_VERSION)"
if [[ -n "$CF_STATIC_DOMAIN" ]]; then
    echo "==> Custom domain:     $CF_STATIC_DOMAIN"
fi

# --- Preconditions ------------------------------------------------------------
if ! command -v bun >/dev/null 2>&1; then
    echo "error: bun not found. Install from https://bun.sh" >&2
    exit 1
fi
if ! command -v uv >/dev/null 2>&1; then
    echo "error: uv not found. Install from https://docs.astral.sh/uv/" >&2
    exit 1
fi
# STATIC_URL belongs to deploy-be.sh, but a mismatch is worth catching here:
# the shop would request its CSS from a host this script never publishes to, and
# the only symptom is an unstyled page.
if [[ -n "$CF_STATIC_DOMAIN" && "$STATIC_URL" != /* ]]; then
    static_host="${STATIC_URL#*://}"
    static_host="${static_host%%/*}"
    if [[ "$static_host" != "$CF_STATIC_DOMAIN" ]]; then
        echo "error: STATIC_URL points at '$static_host' but CF_STATIC_DOMAIN is" >&2
        echo "       '$CF_STATIC_DOMAIN'. The app would load assets from a host this script" >&2
        echo "       does not deploy to. Make them agree in $ENV_FILE." >&2
        exit 1
    fi
    if [[ "$STATIC_URL" != https://* ]]; then
        echo "error: STATIC_URL ('$STATIC_URL') must be https:// — the storefront is served" >&2
        echo "       over HTTPS and browsers block mixed-content stylesheets and scripts." >&2
        exit 1
    fi
    if [[ "$STATIC_URL" != */ ]]; then
        echo "error: STATIC_URL ('$STATIC_URL') must end in a slash, or every asset URL will" >&2
        echo "       be concatenated without a separator." >&2
        exit 1
    fi
fi

# deploy.env holds a live deploy credential and the VPS password; refuse to run
# from a world-readable copy.
perms="$(stat -f '%Lp' "$ENV_FILE" 2>/dev/null || stat -c '%a' "$ENV_FILE" 2>/dev/null || echo '')"
if [[ -n "$perms" && "${perms: -1}" != "0" ]]; then
    echo "    WARNING: $ENV_FILE is readable by other users (mode $perms) and contains an"
    echo "    API token and the server password. Fix with: chmod 600 $ENV_FILE"
fi

# --- Collect ------------------------------------------------------------------
# DEBUG=False selects ManifestStaticFilesStorage, which content-hashes every
# file — that is what makes the immutable caching below safe. It is passed
# through the environment because django-environ's read_env uses setdefault, so
# os.environ wins over the local .env (which has DEBUG=True).
echo "==> Collecting static files"
DEBUG=False uv run python manage.py collectstatic --noinput --clear

if [[ ! -f "$DIST/staticfiles.json" ]]; then
    echo "error: $DIST/staticfiles.json missing after collectstatic — the manifest storage" >&2
    echo "       did not run, which means DEBUG was not False." >&2
    exit 1
fi

# --- Headers ------------------------------------------------------------------
# Written here rather than committed, because it is deployment-target specific.
#
# CORS is not optional: the assets are now on a different origin from the pages
# that reference them, and browsers block cross-origin @font-face without
# Access-Control-Allow-Origin. Oscar's bootstrap/font-awesome icons vanish
# silently otherwise — no visible error, just missing glyphs.
#
# collectstatic emits every file twice, under its plain name and a
# content-hashed one. Templates only ever reference the hashed name, so caching
# by extension is safe: a change produces a new hash and therefore a new URL.
cat >"$DIST/_headers" <<'EOF'
/*
  Access-Control-Allow-Origin: *
  X-Content-Type-Options: nosniff
  Cache-Control: public, max-age=31536000, immutable

/staticfiles.json
  Cache-Control: no-store
EOF

echo "==> Prepared $DIST ($(find "$DIST" -type f | wc -l | tr -d ' ') files)"

# --- Wrangler config ----------------------------------------------------------
# Generated into a temp dir rather than committed, so this gitignored script
# stays the single source of deployment truth and no stray wrangler.jsonc shows
# up in `git status`. assets.directory is absolute because the config no longer
# sits next to the directory it points at.
#
# No not_found_handling: this is an asset host, not an SPA. A miss should 404
# rather than silently return some other file.
#
# custom_domain:true is what attaches $CF_STATIC_DOMAIN and creates its DNS
# record — as opposed to a plain route pattern, which expects the record to
# already exist. It is idempotent, so re-running this is safe.
WRANGLER_CONFIG_DIR="$(mktemp -d)"
trap 'rm -rf "$WRANGLER_CONFIG_DIR"' EXIT
WRANGLER_CONFIG="$WRANGLER_CONFIG_DIR/wrangler.json"

ROUTES_JSON=""
if [[ -n "$CF_STATIC_DOMAIN" ]]; then
    ROUTES_JSON=$(printf ',\n  "routes": [\n    { "pattern": "%s", "custom_domain": true }\n  ]' "$CF_STATIC_DOMAIN")
fi

cat >"$WRANGLER_CONFIG" <<EOF
{
  "name": "$CF_WORKER_NAME",
  "compatibility_date": "$CF_COMPATIBILITY_DATE",
  "assets": {
    "directory": "$SCRIPT_DIR/$DIST"
  }$ROUTES_JSON
}
EOF

if [[ -n "${DRY_RUN:-}" ]]; then
    echo "==> DRY_RUN — collecting and validating without uploading"
    "${WRANGLER[@]}" deploy --config "$WRANGLER_CONFIG" --dry-run
    echo "==> DRY_RUN complete; nothing was uploaded."
    exit 0
fi

# --- Deploy -------------------------------------------------------------------
echo "==> Deploying to Cloudflare Workers"
"${WRANGLER[@]}" deploy --config "$WRANGLER_CONFIG"

# --- Verify -------------------------------------------------------------------
# Fetching a real hashed asset rather than the root: an assets-only Worker 404s
# on "/", so a 404 there would prove nothing either way. Warn rather than fail —
# a freshly attached custom domain needs a minute for DNS and the edge cert.
if [[ -n "$CF_STATIC_DOMAIN" ]]; then
    probe="$(python3 -c "
import json
m = json.load(open('$DIST/staticfiles.json'))
print(next(v for k, v in m['paths'].items() if k.endswith('.css')))
" 2>/dev/null || true)"
    if [[ -n "$probe" ]]; then
        echo "==> Checking https://$CF_STATIC_DOMAIN/$probe"
        code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 20 "https://$CF_STATIC_DOMAIN/$probe" || echo 000)"
        if [[ "$code" == "200" ]]; then
            echo "    OK — assets are being served"
            acao="$(curl -s -o /dev/null -w '%header{access-control-allow-origin}' --max-time 20 "https://$CF_STATIC_DOMAIN/$probe" 2>/dev/null || true)"
            if [[ -n "$acao" ]]; then
                echo "    CORS: Access-Control-Allow-Origin: $acao"
            else
                echo "    WARNING: no Access-Control-Allow-Origin header — cross-origin webfonts"
                echo "    will be blocked and Oscar's icons will render as blank boxes."
                echo "    Confirm _headers was uploaded with the assets."
            fi
        else
            echo "    Not reachable yet (HTTP $code)."
            case "$code" in
                000) echo "    No response — DNS or the edge certificate may still be provisioning." ;;
                404) echo "    404 = the asset set uploaded, but not this file. Check the manifest." ;;
                5*) echo "    5xx from Cloudflare — check the Worker in the dashboard." ;;
            esac
        fi
    fi
fi

echo
echo "==> Done."
echo "    Service: https://dash.cloudflare.com/$CLOUDFLARE_ACCOUNT_ID/workers/services/view/$CF_WORKER_NAME/production"
echo
if [[ "${STATIC_URL:-/static/}" == /* ]]; then
    echo "    NEXT: STATIC_URL in $ENV_FILE is still same-origin, so the shop is not yet"
    echo "    pointing at this Worker. Set it to https://$CF_STATIC_DOMAIN/ and run:"
    echo
    echo "        ./deploy-be.sh"
    echo
else
    echo "    The shop serves assets from ${STATIC_URL}"
    echo
    echo "    IMPORTANT: this REPLACED the Worker's whole asset set — a deploy serves"
    echo "    exactly the files just uploaded, so the previously hashed names are gone."
    echo "    The running app still asks for the OLD names until its manifest is updated,"
    echo "    so if any asset changed, the site is serving 404s for them RIGHT NOW."
    echo
    echo "        ./deploy-be.sh      # ships the matching manifest — run this next"
fi
