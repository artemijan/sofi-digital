#!/usr/bin/env bash
# Deploys the Sofi shop (Django 5.2 + django-oscar 4.1) to the host in
# deploy.env as a systemd service: start-on-boot, graceful SIGTERM with a 30s
# grace period, logs to a per-service file.
#
# This is the APPLICATION half. The collected static assets are deployed
# separately by deploy-static.sh, to Cloudflare Workers — no CSS/JS is served
# from this box. Media (product images, easy-thumbnails output) IS served from
# here, because the Oscar dashboard writes it at runtime and it therefore cannot
# be shipped to a CDN; see the SERVE_MEDIA branch in config/urls.py.
#
# Configuration comes from deploy.env, shared with deploy-static.sh. THIS SCRIPT
# IS COMMITTED — it holds no secrets and no project-specific values, so CI can
# run it; deploy.env is gitignored (`*.env`) and never leaves your machine. In
# GitHub Actions the same values arrive from the prod Environment's secrets and
# variables instead, and no env file is present at all.
#
#   ./deploy-be.sh                  deploy
#   ./deploy-be.sh other.env        deploy using a different config
#   FORCE_SEED_DATA=1 ./deploy-be.sh   overwrite the remote DB and media
#
# HOW IT IS EXPOSED: gunicorn listens on plain HTTP bound to loopback.
# Cloudflare Tunnel (cloudflared, configured below when CLOUDFLARE_TUNNEL_TOKEN
# is set) forwards $PUBLIC_URL to it, so there is no inbound port to open and no
# TLS certificate on the box. TLS is terminated entirely at the edge and the app
# does no scheme enforcement of its own — see the TLS section of deploy.env.
#
# SUDO: the remote user needs sudo for `mv` into /etc/systemd/system, for
# `systemctl`, and (first run only) for apt-get and dpkg. This script pipes
# REMOTE_PASSWORD to `sudo -S` over ssh stdin, so nothing needs configuring in
# advance and the password never appears in the remote `ps` output. If you use
# key auth and leave REMOTE_PASSWORD empty, grant passwordless sudo instead:
#   debian ALL=(ALL) NOPASSWD: /usr/bin/systemctl, /usr/bin/mv, /usr/bin/apt-get, /usr/bin/dpkg, /usr/bin/cloudflared
#
# WHY ONE GUNICORN WORKER: see the GUNICORN_WORKERS comment in deploy.env. The
# Whoosh index and LocMemCache both assume a single process.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# The env file is optional. In CI there is none: the workflow puts the same
# values in the environment from the GitHub Environment's secrets and variables,
# and writing them to a file first would only put secrets on the runner's disk.
# Either way the require block below is what actually enforces completeness.
#
# An env file named explicitly on the command line must exist, though — that is
# a typo, not a deliberate environment-only run.
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
# Every project-specific value comes from $ENV_FILE. Nothing below names a
# domain, a shop, an email address or a credential, so this script deploys any
# target you point it at with a different env file — and a typo'd or missing
# setting fails here with a list, rather than silently deploying someone else's
# hostname.
#
# The only defaults kept are infrastructure constants that are true regardless
# of which project is being deployed.

_missing=()
require() { [[ -n "${!1:-}" ]] || _missing+=("$1"); }

require REMOTE_HOST          # where to deploy
require REMOTE_USER
require REMOTE_PATH
require SERVICE_NAME         # names the systemd unit and the log file
require PUBLIC_URL           # public origin; drives ALLOWED_HOSTS + CSRF
require STATIC_URL           # CDN origin for the collected assets
require OSCAR_SHOP_NAME      # rendered in the storefront and in emails
require OSCAR_DEFAULT_CURRENCY
require DEFAULT_FROM_EMAIL
require EMAIL_URL

if ((${#_missing[@]})); then
    echo "error: the following must be set in $CONFIG_SOURCE:" >&2
    printf '         %s\n' "${_missing[@]}" >&2
    exit 1
fi

# Optional. Empty means "off" — never "guess a default".
REMOTE_PASSWORD="${REMOTE_PASSWORD:-}"
EXTRA_ALLOWED_HOSTS="${EXTRA_ALLOWED_HOSTS:-}"
CLOUDFLARE_TUNNEL_TOKEN="${CLOUDFLARE_TUNNEL_TOKEN:-}"
DJANGO_SECRET_KEY="${DJANGO_SECRET_KEY:-}"
OSCAR_SHOP_TAGLINE="${OSCAR_SHOP_TAGLINE:-}"
DJANGO_SUPERUSER_USERNAME="${DJANGO_SUPERUSER_USERNAME:-}"
DJANGO_SUPERUSER_EMAIL="${DJANGO_SUPERUSER_EMAIL:-}"
DJANGO_SUPERUSER_PASSWORD="${DJANGO_SUPERUSER_PASSWORD:-}"

# Infrastructure defaults — not project identity.
SSH_PORT="${SSH_PORT:-22}"
APP_PORT="${APP_PORT:-8000}"
BIND_ADDRESS="${BIND_ADDRESS:-127.0.0.1}"
GUNICORN_WORKERS="${GUNICORN_WORKERS:-1}"
GUNICORN_THREADS="${GUNICORN_THREADS:-4}"
GUNICORN_TIMEOUT="${GUNICORN_TIMEOUT:-60}"

# TLS is terminated upstream and the app is reached over plain HTTP, so it does
# no scheme enforcement of its own. See the security block in config/settings.py.
SECURE_SSL_REDIRECT="${SECURE_SSL_REDIRECT:-False}"
SECURE_HSTS_SECONDS="${SECURE_HSTS_SECONDS:-0}"
TRUST_PROXY_SSL_HEADER="${TRUST_PROXY_SSL_HEADER:-True}"
SESSION_COOKIE_SECURE="${SESSION_COOKIE_SECURE:-True}"
CSRF_COOKIE_SECURE="${CSRF_COOKIE_SECURE:-True}"

PUBLIC_URL="${PUBLIC_URL%/}"

# createsuperuser --noinput reads all three or fails; a password with no
# username would abort the deploy after migrations have already run.
if [[ -n "$DJANGO_SUPERUSER_PASSWORD" ]]; then
    if [[ -z "$DJANGO_SUPERUSER_USERNAME" || -z "$DJANGO_SUPERUSER_EMAIL" ]]; then
        echo "error: DJANGO_SUPERUSER_PASSWORD is set, so DJANGO_SUPERUSER_USERNAME and" >&2
        echo "       DJANGO_SUPERUSER_EMAIL must be set too in $ENV_FILE." >&2
        exit 1
    fi
fi

# Host only — ALLOWED_HOSTS rejects a scheme or a port suffix.
PUBLIC_HOST="${PUBLIC_URL#*://}"
PUBLIC_HOST="${PUBLIC_HOST%%/*}"
PUBLIC_HOST="${PUBLIC_HOST%%:*}"

VENV_PY="$REMOTE_PATH/.venv/bin/python"
LOG_DIR="$REMOTE_PATH/log"
UNIT_NAME="$SERVICE_NAME.service"

# --- Sanity checks before doing any work --------------------------------------
if [[ "$PUBLIC_URL" != https://* ]]; then
    echo "error: PUBLIC_URL is '$PUBLIC_URL' but must be https://." >&2
    echo "       config/settings.py sets SECURE_SSL_REDIRECT, SESSION_COOKIE_SECURE and" >&2
    echo "       CSRF_COOKIE_SECURE whenever DEBUG is off, and this deploy sets DEBUG=False." >&2
    echo "       Over plain HTTP the site redirect-loops and nobody can log in." >&2
    exit 1
fi
if [[ "$GUNICORN_WORKERS" -gt 1 ]]; then
    echo "error: GUNICORN_WORKERS is $GUNICORN_WORKERS. This app cannot run multi-process:" >&2
    echo "       HAYSTACK_SIGNAL_PROCESSOR writes to a Whoosh index that takes an exclusive" >&2
    echo "       lock, so a second worker raises LockError on any product save. SQLite and" >&2
    echo "       LocMemCache push the same way. Raise GUNICORN_THREADS instead." >&2
    exit 1
fi
if [[ "$STATIC_URL" != */ ]]; then
    echo "error: STATIC_URL ('$STATIC_URL') must end in a slash, or every asset URL will be" >&2
    echo "       concatenated without a separator." >&2
    exit 1
fi
if [[ "$STATIC_URL" != /* && "$STATIC_URL" != https://* ]]; then
    echo "error: STATIC_URL ('$STATIC_URL') must be https:// — the storefront is served over" >&2
    echo "       HTTPS and browsers block mixed-content stylesheets and scripts outright." >&2
    exit 1
fi
for f in manage.py pyproject.toml uv.lock config/settings.py config/wsgi.py; do
    [[ -f "$f" ]] || { echo "error: $f not found — run this from the project root." >&2; exit 1; }
done
command -v rsync >/dev/null 2>&1 || { echo "error: rsync not found locally." >&2; exit 1; }

# --- SSH ----------------------------------------------------------------------
# Connections are multiplexed over a single master, so the ~30 ssh and rsync
# calls below authenticate once and then reuse the open channel.
#
# Authentication uses REMOTE_PASSWORD from $ENV_FILE, non-interactively, via
# SSH_ASKPASS: ssh runs the helper script below and reads the password from its
# stdout. Deliberately not sshpass — that is not packaged for macOS and would
# need a third-party tap — and deliberately not a command-line argument, which
# would expose the password in `ps` for the life of every call.
#
# The helper reads the value from its environment rather than embedding it, so
# the file itself is not a secret. It lives in a 0700 temp dir removed on exit.
CTRL_DIR="$(mktemp -d)"
chmod 700 "$CTRL_DIR"
CTRL_PATH="$CTRL_DIR/cm"
ASKPASS_HELPER="$CTRL_DIR/askpass"

SSH_BASE=(
    -p "$SSH_PORT"
    -o ControlMaster=auto
    -o ControlPath="$CTRL_PATH"
    -o ControlPersist=600
)

# Host key policy.
#
# accept-new trusts whatever key the host presents on FIRST contact, and only
# refuses a key that later changes. On your own machine that is fine — the first
# connection already happened and the key is pinned in ~/.ssh/known_hosts.
#
# In CI it is weaker than it looks: the runner is destroyed after every job, so
# every deploy is a first contact, and with password authentication an
# impersonating host would be handed REMOTE_PASSWORD directly. Set
# SSH_KNOWN_HOSTS to pin the key and close that off:
#
#     ssh-keyscan -p 22 <host>        # copy the output into the variable
#
KNOWN_HOSTS_OPTS=()
if [[ -n "${SSH_KNOWN_HOSTS:-}" ]]; then
    printf '%s\n' "$SSH_KNOWN_HOSTS" >"$CTRL_DIR/known_hosts"
    chmod 600 "$CTRL_DIR/known_hosts"
    KNOWN_HOSTS_OPTS=(
        -o UserKnownHostsFile="$CTRL_DIR/known_hosts"
        -o StrictHostKeyChecking=yes
    )
    HOSTKEY_MODE="pinned via SSH_KNOWN_HOSTS"
else
    KNOWN_HOSTS_OPTS=(-o StrictHostKeyChecking=accept-new)
    HOSTKEY_MODE="accept-new (unpinned)"
fi
SSH_BASE+=("${KNOWN_HOSTS_OPTS[@]}")

SSH_AUTH_MODE=""
if [[ -n "${SSH_KEY:-}" ]]; then
    SSH_BASE+=(-i "${SSH_KEY/#\~/$HOME}")
    SSH_AUTH_MODE="key ${SSH_KEY}"
elif [[ -n "$REMOTE_PASSWORD" ]]; then
    # Quoted delimiter: the body is written verbatim, so DEPLOY_SSH_PASSWORD is
    # expanded by the helper at run time, not baked in here.
    cat >"$ASKPASS_HELPER" <<'ASKPASS_EOF'
#!/bin/sh
printf '%s\n' "$DEPLOY_SSH_PASSWORD"
ASKPASS_EOF
    chmod 700 "$ASKPASS_HELPER"
    export DEPLOY_SSH_PASSWORD="$REMOTE_PASSWORD"
    export SSH_ASKPASS="$ASKPASS_HELPER"
    # Without =force, ssh only consults SSH_ASKPASS when it has no terminal.
    # Requires OpenSSH >= 8.4, checked below.
    export SSH_ASKPASS_REQUIRE=force
    # Stop ssh offering agent/default keys first: on a host that accepts both,
    # a few loaded-but-wrong keys can exhaust MaxAuthTries before it ever gets
    # to the password, which surfaces as a bare "Permission denied".
    SSH_BASE+=(-o PubkeyAuthentication=no)
    SSH_BASE+=(-o PreferredAuthentications=password,keyboard-interactive)
    SSH_AUTH_MODE="password from $CONFIG_SOURCE"

    ssh_ver="$(ssh -V 2>&1 | sed -n 's/^OpenSSH_\([0-9]*\)\.\([0-9]*\).*/\1 \2/p')"
    ssh_major="${ssh_ver%% *}"
    ssh_minor="${ssh_ver##* }"
    if [[ -z "$ssh_major" ]] || ((ssh_major < 8 || (ssh_major == 8 && ssh_minor < 4))); then
        echo "error: this ssh ($(ssh -V 2>&1)) predates SSH_ASKPASS_REQUIRE (OpenSSH 8.4)," >&2
        echo "       so REMOTE_PASSWORD cannot be supplied non-interactively." >&2
        echo "       Set SSH_KEY in $ENV_FILE instead, or upgrade OpenSSH." >&2
        exit 1
    fi
else
    SSH_AUTH_MODE="ssh agent / default keys"
fi

cleanup() {
    ssh "${SSH_BASE[@]}" -O exit "$REMOTE_USER@$REMOTE_HOST" >/dev/null 2>&1 || true
    rm -rf "$CTRL_DIR" "${TMP_ENV:-}" "${TMP_UNIT_DIR:-}"
}
trap cleanup EXIT

echo "==> Target: $REMOTE_USER@$REMOTE_HOST:$REMOTE_PATH"
echo "==> Public: $PUBLIC_URL  ->  $BIND_ADDRESS:$APP_PORT"
echo "==> Static: $STATIC_URL"

echo "==> Opening ssh master connection ($SSH_AUTH_MODE; host key $HOSTKEY_MODE)"
if ! ssh "${SSH_BASE[@]}" -fN "$REMOTE_USER@$REMOTE_HOST"; then
    echo "error: could not authenticate to $REMOTE_USER@$REMOTE_HOST:$SSH_PORT." >&2
    if [[ -n "$REMOTE_PASSWORD" && -z "${SSH_KEY:-}" ]]; then
        echo "       REMOTE_PASSWORD from $CONFIG_SOURCE was rejected, or the server refuses" >&2
        echo "       password authentication (sshd PasswordAuthentication no)." >&2
    fi
    exit 1
fi

# Reuses the master opened above, so it never re-authenticates — but it must
# carry the same host-key policy, or rsync would fall back to its own connection
# with different rules if the master ever went away.
RSYNC_SSH="ssh -p $SSH_PORT -o ControlPath=$CTRL_PATH ${KNOWN_HOSTS_OPTS[*]}"
[[ -n "${SSH_KEY:-}" ]] && RSYNC_SSH="$RSYNC_SSH -i ${SSH_KEY/#\~/$HOME}"

remote() {
    # ssh flattens argv into a single string with plain spaces before handing it
    # to the remote shell, so any arg containing a space gets word-split
    # remotely unless we re-quote it here.
    local cmd
    printf -v cmd '%q ' "$@"
    # SC2029: expanding client-side is the point — $cmd is the %q-quoted string
    # built above, and the remote shell must receive it already quoted.
    # shellcheck disable=SC2029
    ssh "${SSH_BASE[@]}" "$REMOTE_USER@$REMOTE_HOST" "$cmd"
}

remote_sh() {
    # For anything needing remote shell features — pipes, redirection, $HOME.
    # PATH is set explicitly because uv installs to ~/.local/bin, which a
    # non-interactive ssh shell does not necessarily pick up from .bashrc.
    # \$HOME is escaped so it resolves on the server, not here.
    # shellcheck disable=SC2029
    ssh "${SSH_BASE[@]}" "$REMOTE_USER@$REMOTE_HOST" \
        "bash -c $(printf '%q' "export PATH=\"\$HOME/.local/bin:\$PATH\"; set -euo pipefail; $1")"
}

rsudo() {
    local cmd
    printf -v cmd '%q ' "$@"
    if [[ -n "$REMOTE_PASSWORD" ]]; then
        # -S reads the password from stdin and -p '' silences the prompt. Going
        # through stdin rather than the command line keeps it out of the remote
        # `ps` output for the life of the call.
        # shellcheck disable=SC2029
        printf '%s\n' "$REMOTE_PASSWORD" |
            ssh "${SSH_BASE[@]}" "$REMOTE_USER@$REMOTE_HOST" "sudo -S -p '' $cmd"
    else
        # shellcheck disable=SC2029
        ssh "${SSH_BASE[@]}" "$REMOTE_USER@$REMOTE_HOST" "sudo -n $cmd"
    fi
}

if ! remote true; then
    echo "error: cannot run commands on $REMOTE_USER@$REMOTE_HOST." >&2
    exit 1
fi
if ! rsudo true >/dev/null 2>&1; then
    echo "error: sudo failed on the remote host." >&2
    echo "       Set REMOTE_PASSWORD in $ENV_FILE, or grant passwordless sudo (see header)." >&2
    exit 1
fi

# --- Remote prerequisites -----------------------------------------------------
REMOTE_ARCH="$(remote uname -m | tr -d '\r\n')"
echo "==> Remote arch: $REMOTE_ARCH"

if ! remote command -v rsync >/dev/null 2>&1; then
    echo "==> Installing rsync on remote"
    rsudo apt-get update -qq
    rsudo apt-get install -y rsync
fi
if ! remote command -v curl >/dev/null 2>&1; then
    echo "==> Installing curl on remote"
    rsudo apt-get update -qq
    rsudo apt-get install -y curl
fi

# uv rather than the system Python. pyproject.toml requires >=3.13; whether the
# distro happens to satisfy that is not something to depend on (Debian 13 does,
# Debian 12 ships 3.11), so the interpreter is provisioned explicitly. uv builds
# the venv from the committed uv.lock, which makes the deployed dependency set
# byte-identical to local.
if ! remote_sh 'command -v uv >/dev/null 2>&1'; then
    echo "==> Installing uv on remote"
    remote_sh 'curl -LsSf https://astral.sh/uv/install.sh | sh'
fi
echo "==> uv: $(remote_sh 'uv --version')"

echo "==> Ensuring Python 3.13 is available on remote"
remote_sh 'uv python install 3.13'

# --- Remote layout ------------------------------------------------------------
echo "==> Ensuring remote directories"
remote mkdir -p "$REMOTE_PATH" "$LOG_DIR" "$REMOTE_PATH/media" "$REMOTE_PATH/whoosh_index"

# --- Sync application code ----------------------------------------------------
# --delete keeps the remote tree from accumulating files deleted locally, and is
# safe here because rsync never deletes excluded paths: the DB, media,
# staticfiles, whoosh_index and log directories below are all protected by their
# own --exclude, so a redeploy cannot destroy them.
echo "==> Syncing application code"
rsync -az --delete --info=stats1 -e "$RSYNC_SSH" \
    --exclude='.git/' \
    --exclude='.venv/' \
    --exclude='.idea/' \
    --exclude='__pycache__/' \
    --exclude='*.py[cod]' \
    --exclude='.env' \
    --exclude='*.env' \
    --exclude='deploy*.sh' \
    --exclude='db.sqlite3*' \
    --exclude='media/' \
    --exclude='staticfiles/' \
    --exclude='whoosh_index/' \
    --exclude='log/' \
    --exclude='.ruff_cache/' \
    --exclude='.pytest_cache/' \
    --exclude='.mypy_cache/' \
    --exclude='.DS_Store' \
    ./ "$REMOTE_USER@$REMOTE_HOST:$REMOTE_PATH/"

# --- Seed data (first deploy only) --------------------------------------------
# The catalogue lives in db.sqlite3 and media/. They are shipped once and never
# again, because after go-live the server copy is authoritative: it holds orders,
# customer accounts and dashboard uploads that do not exist locally. Overwriting
# it with a stale local file would destroy all of that silently.
if remote test -f "$REMOTE_PATH/db.sqlite3" && [[ -z "${FORCE_SEED_DATA:-}" ]]; then
    echo "==> Remote database exists — leaving DB and media untouched"
    echo "    (FORCE_SEED_DATA=1 overwrites them with the local copies.)"
else
    if [[ -n "${FORCE_SEED_DATA:-}" ]] && remote test -f "$REMOTE_PATH/db.sqlite3"; then
        echo
        echo "    WARNING: FORCE_SEED_DATA is set. The remote database and media are about to"
        echo "    be REPLACED by the local copies. Every order, customer account and dashboard"
        echo "    upload made on the server since the last seed will be lost."
        echo "    Press Ctrl-C within 10s to abort."
        echo
        sleep 10
        stamp="$(remote date +%Y%m%d-%H%M%S | tr -d '\r\n')"
        echo "==> Backing up remote DB to db.sqlite3.$stamp.bak"
        remote cp "$REMOTE_PATH/db.sqlite3" "$REMOTE_PATH/db.sqlite3.$stamp.bak"
    fi

    if [[ -f db.sqlite3 ]]; then
        echo "==> Seeding database"
        rsync -az --info=stats1 -e "$RSYNC_SSH" db.sqlite3 \
            "$REMOTE_USER@$REMOTE_HOST:$REMOTE_PATH/db.sqlite3"
    else
        echo "==> No local db.sqlite3 — the remote one will be created by migrate"
    fi
    if [[ -d media ]]; then
        echo "==> Seeding media"
        # No --delete: media/CACHE is regenerated by easy-thumbnails on the
        # server and there is no reason to churn it.
        rsync -az --info=stats1 -e "$RSYNC_SSH" --exclude='CACHE/' media/ \
            "$REMOTE_USER@$REMOTE_HOST:$REMOTE_PATH/media/"
    fi
fi

# --- Django environment -------------------------------------------------------
# The app reads this file itself (django-environ, via
# environ.Env.read_env(BASE_DIR/".env")), so the systemd unit needs no
# EnvironmentFile and the secrets stay out of /etc/systemd/system.
#
# Resolving SECRET_KEY: an explicit value in deploy.env wins; otherwise the key
# already on the server is reused. Regenerating it on every deploy would log
# every customer out and break outstanding password-reset links, so it is only
# generated when there is genuinely nothing to reuse.
if [[ -n "$DJANGO_SECRET_KEY" ]]; then
    SECRET_KEY="$DJANGO_SECRET_KEY"
    echo "==> SECRET_KEY: pinned in $CONFIG_SOURCE"
else
    existing="$(remote grep -m1 '^SECRET_KEY=' "$REMOTE_PATH/.env" 2>/dev/null || true)"
    existing="${existing#SECRET_KEY=}"
    existing="${existing%$'\r'}"
    existing="${existing#\'}"
    existing="${existing%\'}"
    if [[ -n "$existing" ]]; then
        SECRET_KEY="$existing"
        echo "==> SECRET_KEY: reusing the key already on the server"
    else
        # hex, so the value can never contain a quote or a '#' that
        # django-environ or a shell would have to be careful about.
        SECRET_KEY="$(openssl rand -hex 50)"
        echo "==> SECRET_KEY: generated (first deploy)"
    fi
fi

ALLOWED_HOSTS="$PUBLIC_HOST,localhost,127.0.0.1"
[[ -n "$EXTRA_ALLOWED_HOSTS" ]] && ALLOWED_HOSTS="$ALLOWED_HOSTS,$EXTRA_ALLOWED_HOSTS"

echo "==> Writing $REMOTE_PATH/.env"
TMP_ENV="$(mktemp)"

env_line() {
    # A single quote in a value would break the quoting; refuse rather than
    # write a file that silently means something else.
    case "$2" in
        *"'"*)
            echo "error: $1 contains a single quote, which this writer cannot escape." >&2
            echo "       Regenerate the value without one." >&2
            exit 1
            ;;
    esac
    # Single-quoted because django-environ strips the quotes but a bare '#'
    # would otherwise start a comment and silently TRUNCATE the value.
    printf "%s='%s'\n" "$1" "$2" >>"$TMP_ENV"
}

env_line SECRET_KEY "$SECRET_KEY"
env_line DEBUG "False"
env_line ALLOWED_HOSTS "$ALLOWED_HOSTS"
# Not optional. With TLS terminated upstream the app sees http, so Django
# expects Origin: http://<host> while the browser sends https://<host>. Without
# the https origin listed here every POST — login, checkout, dashboard — is
# rejected with "Origin checking failed". PUBLIC_URL is validated as https
# above, so this is always the right value.
env_line CSRF_TRUSTED_ORIGINS "$PUBLIC_URL"
env_line SECURE_SSL_REDIRECT "$SECURE_SSL_REDIRECT"
env_line SECURE_HSTS_SECONDS "$SECURE_HSTS_SECONDS"
env_line TRUST_PROXY_SSL_HEADER "$TRUST_PROXY_SSL_HEADER"
env_line SESSION_COOKIE_SECURE "$SESSION_COOKIE_SECURE"
env_line CSRF_COOKIE_SECURE "$CSRF_COOKIE_SECURE"
# Relative path; config/settings.py anchors it to BASE_DIR.
env_line DATABASE_URL "sqlite:///db.sqlite3"
env_line STATIC_URL "$STATIC_URL"
# Django serves MEDIA_ROOT itself (config/urls.py) — nothing else on this box
# can, since static went to the CDN and there is no nginx.
env_line SERVE_MEDIA "True"
env_line EMAIL_URL "$EMAIL_URL"
env_line DEFAULT_FROM_EMAIL "$DEFAULT_FROM_EMAIL"
env_line OSCAR_SHOP_NAME "$OSCAR_SHOP_NAME"
env_line OSCAR_SHOP_TAGLINE "$OSCAR_SHOP_TAGLINE"
env_line OSCAR_DEFAULT_CURRENCY "$OSCAR_DEFAULT_CURRENCY"

rsync -az --chmod=600 -e "$RSYNC_SSH" "$TMP_ENV" \
    "$REMOTE_USER@$REMOTE_HOST:$REMOTE_PATH/.env"
remote chmod 600 "$REMOTE_PATH/.env"
rm -f "$TMP_ENV"
TMP_ENV=""

if [[ "$STATIC_URL" == "/static/" ]]; then
    echo
    echo "    WARNING: STATIC_URL is still /static/, and nothing on this box serves it —"
    echo "    there is no nginx and Django refuses to serve static files with DEBUG off."
    echo "    The shop will render unstyled until you run ./deploy-static.sh, put the"
    echo "    printed Worker URL in STATIC_URL in $ENV_FILE, and re-run this script."
    echo
fi

# --- Dependencies -------------------------------------------------------------
echo "==> Installing dependencies from uv.lock"
remote_sh "cd $(printf '%q' "$REMOTE_PATH") && uv sync --frozen --no-dev"

# gunicorn deliberately is not in pyproject.toml — it is a deployment concern,
# not an application dependency, and pinning it there would drag it into every
# local dev environment. It must be installed AFTER `uv sync`, which prunes
# anything absent from the lock file and would otherwise remove it each deploy.
echo "==> Installing gunicorn"
remote_sh "cd $(printf '%q' "$REMOTE_PATH") && uv pip install --quiet gunicorn"

# --- Stop the service before touching the database ----------------------------
# SQLite plus a single Whoosh writer lock means the running process contends
# with migrate and rebuild_index. Stopping first turns a possible mid-deploy
# 'database is locked' into a few seconds of clean downtime.
echo "==> Stopping $UNIT_NAME (if running)"
rsudo systemctl stop "$UNIT_NAME" >/dev/null 2>&1 || true

# --- Django management commands -----------------------------------------------
echo "==> Running migrations"
remote_sh "cd $(printf '%q' "$REMOTE_PATH") && $(printf '%q' "$VENV_PY") manage.py migrate --noinput"

# The server serves no static files — the CDN does — but it still needs the
# MANIFEST. ManifestStaticFilesStorage reads staticfiles/staticfiles.json at
# request time to turn {% static 'oscar/css/styles.css' %} into the hashed name
# that exists on the CDN. Without it every template render raises ValueError, so
# this step is not optional even though the output mostly is.
#
# collectstatic has no "manifest only" mode: the hash of each file is derived
# from its content, so it must write the files to hash them. It produces ~23MB
# here and exactly one 26KB file of that is ever read again, so the rest is
# pruned immediately below rather than left to sit on the disk.
#
# Nothing is transferred for this — staticfiles/ is in the rsync excludes and
# the assets are built locally on the server from the synced sources.
echo "==> Building the static manifest"
remote_sh "cd $(printf '%q' "$REMOTE_PATH") && $(printf '%q' "$VENV_PY") manage.py collectstatic --noinput --clear"

# -maxdepth 1 with `rm -rf` rather than find -delete: portable, and it does not
# need to walk 566 files to remove the trees.
remote_sh "cd $(printf '%q' "$REMOTE_PATH") && find staticfiles -mindepth 1 -maxdepth 1 ! -name staticfiles.json -exec rm -rf {} +"
echo "    kept $(remote_sh "cd $(printf '%q' "$REMOTE_PATH") && du -sh staticfiles | cut -f1" | tr -d '\r\n') (manifest only); the assets live at $STATIC_URL"

if ! remote test -s "$REMOTE_PATH/staticfiles/staticfiles.json"; then
    echo "error: staticfiles/staticfiles.json is missing or empty after collectstatic." >&2
    echo "       Every page would raise ValueError on its first {% static %} tag." >&2
    exit 1
fi

# Oscar's checkout renders a country dropdown from this table and the address
# form cannot validate without it, so an empty table breaks checkout outright.
# --initial-only makes this idempotent: the command exits quietly when countries
# are already present, instead of erroring out the way a bare run does.
echo "==> Ensuring country data"
remote_sh "cd $(printf '%q' "$REMOTE_PATH") && $(printf '%q' "$VENV_PY") manage.py oscar_populate_countries --initial-only"

if [[ -n "$DJANGO_SUPERUSER_PASSWORD" ]]; then
    echo "==> Ensuring a superuser exists"
    if remote_sh "cd $(printf '%q' "$REMOTE_PATH") && $(printf '%q' "$VENV_PY") manage.py shell -c \"from django.contrib.auth import get_user_model; print('NONE' if not get_user_model().objects.filter(is_superuser=True).exists() else 'OK')\"" | grep -q NONE; then
        echo "    creating $DJANGO_SUPERUSER_USERNAME"
        # Passed through the environment, not argv, so it stays out of `ps`.
        remote_sh "cd $(printf '%q' "$REMOTE_PATH") && DJANGO_SUPERUSER_USERNAME=$(printf '%q' "$DJANGO_SUPERUSER_USERNAME") DJANGO_SUPERUSER_EMAIL=$(printf '%q' "$DJANGO_SUPERUSER_EMAIL") DJANGO_SUPERUSER_PASSWORD=$(printf '%q' "$DJANGO_SUPERUSER_PASSWORD") $(printf '%q' "$VENV_PY") manage.py createsuperuser --noinput"
    else
        echo "    already present — leaving it alone"
    fi
else
    echo "==> DJANGO_SUPERUSER_PASSWORD unset, skipping superuser creation"
fi

# Rebuilt rather than shipped: the local whoosh_index is gitignored and would be
# stale the moment the server's catalogue diverges. Safe to run now because the
# service is stopped, so nothing else holds the writer lock.
echo "==> Rebuilding the search index"
remote_sh "cd $(printf '%q' "$REMOTE_PATH") && $(printf '%q' "$VENV_PY") manage.py rebuild_index --noinput"

# --- systemd unit -------------------------------------------------------------
echo "==> Installing systemd unit"
TMP_UNIT_DIR="$(mktemp -d)"

cat >"$TMP_UNIT_DIR/$UNIT_NAME" <<EOF
[Unit]
Description=$OSCAR_SHOP_NAME shop (Django/Oscar via gunicorn)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=$REMOTE_USER
Group=$REMOTE_USER
WorkingDirectory=$REMOTE_PATH
ExecStart=$REMOTE_PATH/.venv/bin/gunicorn config.wsgi:application \\
    --bind $BIND_ADDRESS:$APP_PORT \\
    --workers $GUNICORN_WORKERS \\
    --threads $GUNICORN_THREADS \\
    --timeout $GUNICORN_TIMEOUT \\
    --graceful-timeout 30 \\
    --access-logfile - \\
    --error-logfile - \\
    --capture-output
Restart=on-failure
RestartSec=5
KillSignal=SIGTERM
TimeoutStopSec=30
StandardOutput=append:$LOG_DIR/$SERVICE_NAME.log
StandardError=append:$LOG_DIR/$SERVICE_NAME.log

[Install]
WantedBy=multi-user.target
EOF

rsync -az -e "$RSYNC_SSH" "$TMP_UNIT_DIR/$UNIT_NAME" \
    "$REMOTE_USER@$REMOTE_HOST:/tmp/"
rsudo mv "/tmp/$UNIT_NAME" "/etc/systemd/system/$UNIT_NAME"
rsudo chown root:root "/etc/systemd/system/$UNIT_NAME"
rsudo systemctl daemon-reload
rsudo systemctl enable "$UNIT_NAME"
rm -rf "$TMP_UNIT_DIR"
TMP_UNIT_DIR=""

echo "==> Starting $UNIT_NAME"
rsudo systemctl restart "$UNIT_NAME"

# --- Health check -------------------------------------------------------------
# The service can exit *after* systemctl returns success (bad .env, missing
# manifest, import error), so check the socket rather than trusting restart.
#
# Deliberately sends NO X-Forwarded-Proto: this reproduces exactly what reaches
# the app in production — a plain HTTP request from cloudflared — rather than a
# synthetic one that papers over a scheme misconfiguration. The Host header is
# still required, or ALLOWED_HOSTS answers 400.
#
# Redirects are FOLLOWED, because "/" is not a page: Oscar 302s it to
# /catalogue/. Requiring 200 on the first response would fail every deploy of a
# perfectly healthy app. url_effective is then checked as well as the status,
# since following a redirect can only be trusted if it stayed on loopback — a
# hop to https://$PUBLIC_HOST would mean SECURE_SSL_REDIRECT is still on and
# curl went out to the real internet, where a 200 says nothing about this box.
echo "==> Health check (plain HTTP, as cloudflared sends it)"
health_code=""
health_url=""
for _ in 1 2 3 4 5 6 7 8 9 10; do
    sleep 2
    health_out="$(remote curl -sL --max-redirs 3 -o /dev/null \
        -w '%{http_code} %{url_effective}' --max-time 8 \
        -H "Host: $PUBLIC_HOST" \
        "http://127.0.0.1:$APP_PORT/" 2>/dev/null | tr -d '\r\n' || echo "000 -")"
    health_code="${health_out%% *}"
    health_url="${health_out##* }"
    [[ "$health_code" == "200" ]] && break
done

if [[ "$health_code" == "200" && "$health_url" == http://127.0.0.1:* ]]; then
    echo "    OK — the storefront rendered on port $APP_PORT (via $health_url)"
elif [[ "$health_code" == "200" ]]; then
    echo "    FAILED — the check was redirected off this host, to $health_url" >&2
    echo "    The app is still upgrading the scheme itself. Behind the tunnel that is a" >&2
    echo "    loop: the request already arrived over https at the edge. Set" >&2
    echo "    SECURE_SSL_REDIRECT=False in $ENV_FILE and redeploy; Cloudflare's" >&2
    echo "    'Always Use HTTPS' owns the upgrade." >&2
    exit 1
else
    echo "    FAILED — GET / returned HTTP ${health_code:-000} on port $APP_PORT" >&2
    case "$health_code" in
        400) echo "    400 = ALLOWED_HOSTS rejected '$PUBLIC_HOST'." >&2 ;;
        301 | 302) echo "    Still redirecting after 3 hops — likely a redirect loop." >&2 ;;
        500) echo "    500 = application error; the traceback is in the log below." >&2 ;;
        000) echo "    No response at all — the process is probably not running." >&2 ;;
    esac
    echo "    Recent log:" >&2
    remote tail -n 40 "$LOG_DIR/$SERVICE_NAME.log" >&2 || true
    rsudo systemctl --no-pager --lines=15 status "$UNIT_NAME" >&2 || true
    exit 1
fi

# --- Cloudflare Tunnel --------------------------------------------------------
# Installed after the health check, so the tunnel is only ever pointed at an app
# that is already answering locally.
if [[ -n "$CLOUDFLARE_TUNNEL_TOKEN" ]]; then
    if ! remote command -v cloudflared >/dev/null 2>&1; then
        echo "==> Installing cloudflared"
        case "$REMOTE_ARCH" in
            x86_64) cf_arch=amd64 ;;
            aarch64 | arm64) cf_arch=arm64 ;;
            *)
                echo "error: no cloudflared package known for arch $REMOTE_ARCH" >&2
                exit 1
                ;;
        esac
        remote curl -fsSL -o /tmp/cloudflared.deb \
            "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${cf_arch}.deb"
        rsudo dpkg -i /tmp/cloudflared.deb
        remote rm -f /tmp/cloudflared.deb
    fi

    # Reinstall rather than reuse: the token is the whole configuration, and
    # this is the only way to guarantee the running tunnel matches the token in
    # deploy.env. The uninstall is a no-op on a first deploy.
    echo "==> Installing cloudflared service"
    rsudo cloudflared service uninstall >/dev/null 2>&1 || true
    rsudo cloudflared service install "$CLOUDFLARE_TUNNEL_TOKEN"
    rsudo systemctl enable --now cloudflared

    sleep 3
    if remote systemctl is-active --quiet cloudflared; then
        echo "    cloudflared is running"
    else
        echo "    WARNING: cloudflared is not active. Recent log:" >&2
        rsudo journalctl -u cloudflared --no-pager --lines=15 >&2 || true
    fi

    # End-to-end check through Cloudflare. Warn rather than fail: the public
    # hostname route is configured in the dashboard, not by this script, and DNS
    # may not have propagated yet.
    # -L for the same reason as the local check: / is a 302 to /catalogue/.
    echo "==> Checking $PUBLIC_URL from here"
    code="$(curl -sL --max-redirs 5 -o /dev/null -w '%{http_code}' --max-time 20 "$PUBLIC_URL/" || echo 000)"
    if [[ "$code" == "200" ]]; then
        echo "    OK — reachable through Cloudflare"
    else
        echo "    Not reachable yet (HTTP $code)."
        case "$code" in
            521) echo "    521 = Cloudflare cannot reach the origin. Check the tunnel's Public Hostname." ;;
            530) echo "    530 = tunnel not connected, or hostname not routed to this tunnel." ;;
            000) echo "    No response — DNS may not have propagated yet." ;;
        esac
        echo "    Confirm in the dashboard: Zero Trust -> Networks -> Tunnels -> Public Hostname"
        echo "      $PUBLIC_HOST -> HTTP -> 127.0.0.1:$APP_PORT"
        echo "    (127.0.0.1 rather than localhost: the app binds IPv4 only, and localhost"
        echo "     resolves to ::1 first, so every request starts with a refused connection.)"
    fi
else
    echo
    echo "    NOTE: CLOUDFLARE_TUNNEL_TOKEN is not set, so no tunnel was configured."
    echo "    Cloudflare connects to origins on port 443, never $APP_PORT, so $PUBLIC_URL"
    echo "    will return 521 until a tunnel or a reverse proxy fronts this service."
    echo "    See the Cloudflare Tunnel section of $ENV_FILE."
    echo
fi

echo "==> Status"
rsudo systemctl --no-pager --lines=5 status "$UNIT_NAME" || true

echo
echo "==> Done."
echo "    Listening on   $BIND_ADDRESS:$APP_PORT ($GUNICORN_WORKERS worker, $GUNICORN_THREADS threads)"
echo "    Logs           $LOG_DIR/$SERVICE_NAME.log"
echo "    Service        sudo systemctl {status,restart,stop} $UNIT_NAME"
echo "    Static         $STATIC_URL (CDN; this box holds only the manifest)"
echo "    Media          $PUBLIC_URL/media/ (served from this box — runtime uploads)"
echo "    Storefront     $PUBLIC_URL/"
echo "    Dashboard      $PUBLIC_URL/dashboard/"
echo "    Django admin   $PUBLIC_URL/admin/"
if [[ -z "$CLOUDFLARE_TUNNEL_TOKEN" ]]; then
    echo "    NOT exposed publicly — no tunnel is configured."
fi
