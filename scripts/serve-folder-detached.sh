#!/bin/bash
# serve-folder-detached.sh — Apache server for a folder, detached (no iTerm)
# Usage: serve-folder-detached.sh <folder> [<port>]
#   - If <port> is given, use it (callers from apache-start.sh pass the
#     collision-probed value stored in state.json).
#   - Else derive from folder path: 8100 + cksum(path) % 100 (legacy; collides
#     heavily for paths sharing the .worktrees/ prefix — avoid).
#   - Writes PID to /tmp/apache-<port>.pid
#   - Logs to /tmp/apache-<port>.log
#   - Does NOT daemonize itself — caller should invoke via `nohup ... &`

set -e

FOLDER="${1:-.}"
FOLDER="$(cd "$FOLDER" && pwd)"

if [[ -n "${2:-}" ]]; then
    PORT="$2"
else
    PORT=$((8100 + $(echo "$FOLDER" | cksum | cut -d' ' -f1) % 100))
fi

# Resolution order:
#   1. WTF_HTTPD_ROOT env var (e.g. /opt/local/apache2 for MacPorts, custom builds)
#   2. Homebrew Apple Silicon (/opt/homebrew/opt/httpd)
#   3. Homebrew Intel (/usr/local/opt/httpd)
# WTF_HTTPD_MIME and WTF_HTTPD_PHP_MODULE override the auto-derived paths if set.
if [[ -n "${WTF_HTTPD_ROOT:-}" ]]; then
    HTTPD_ROOT="$WTF_HTTPD_ROOT"
    HTTPD_PREFIX="${WTF_HTTPD_ROOT%/opt/httpd}"
    MIME_TYPES="${WTF_HTTPD_MIME:-$HTTPD_PREFIX/etc/httpd/mime.types}"
    PHP_MODULE="${WTF_HTTPD_PHP_MODULE:-$HTTPD_PREFIX/opt/php/lib/httpd/modules/libphp.so}"
elif [[ -d "/opt/homebrew/opt/httpd" ]]; then
    HTTPD_ROOT="/opt/homebrew/opt/httpd"
    MIME_TYPES="${WTF_HTTPD_MIME:-/opt/homebrew/etc/httpd/mime.types}"
    PHP_MODULE="${WTF_HTTPD_PHP_MODULE:-/opt/homebrew/opt/php/lib/httpd/modules/libphp.so}"
elif [[ -d "/usr/local/opt/httpd" ]]; then
    HTTPD_ROOT="/usr/local/opt/httpd"
    MIME_TYPES="${WTF_HTTPD_MIME:-/usr/local/etc/httpd/mime.types}"
    PHP_MODULE="${WTF_HTTPD_PHP_MODULE:-/usr/local/opt/php/lib/httpd/modules/libphp.so}"
else
    echo "ERROR: Apache (httpd) not found." >&2
    echo "  Tried: \$WTF_HTTPD_ROOT, /opt/homebrew/opt/httpd, /usr/local/opt/httpd" >&2
    echo "  Install with: brew install httpd php" >&2
    echo "  Or set WTF_HTTPD_ROOT to your Apache install root (see plugin README)." >&2
    exit 1
fi

HTTPD_BIN="$HTTPD_ROOT/bin/httpd"
CONF_FILE="/tmp/apache-$PORT.conf"
PID_FILE="/tmp/apache-$PORT.pid"
LOG_FILE="/tmp/apache-$PORT.log"

# Same-folder = idempotent restart. Different-folder = abort; callers (i.e.
# apache-start.sh) must resolve the collision explicitly. Historically this
# block silently killed the other folder's Apache, which masked state-file
# port collisions and caused edits in one worktree to appear invisible in
# the browser (the port was pointing at a different worktree's DocumentRoot).
if [[ -f "$PID_FILE" ]]; then
    existing_pid=$(cat "$PID_FILE" 2>/dev/null || true)
    if [[ -n "$existing_pid" ]] && kill -0 "$existing_pid" 2>/dev/null; then
        existing_folder=$(grep -E '^DocumentRoot' "$CONF_FILE" 2>/dev/null | awk -F'"' '{print $2}')
        if [[ "$existing_folder" == "$FOLDER" ]]; then
            echo "already-running pid=$existing_pid port=$PORT"
            exit 0
        else
            echo "ERROR: :$PORT already bound to a different folder:" >&2
            echo "  running: $existing_folder" >&2
            echo "  wanted:  $FOLDER" >&2
            echo "Stop the other server first (bash apache-stop.sh <its-slug>)" >&2
            echo "or pass a different port to this script." >&2
            exit 1
        fi
    fi
fi

# Stale PID file but port free, or port held by a non-Apache process. Only
# reap if the port is clear OR held by a prior run of OUR httpd (no way to
# tell here beyond "this was the pid file we wrote last time" — which the
# block above already handled). If something else is bound, abort loudly.
other_pids=$(lsof -ti ":$PORT" 2>/dev/null || true)
if [[ -n "$other_pids" ]]; then
    echo "ERROR: port :$PORT is bound by another process (pids: $other_pids)" >&2
    echo "Free it first: kill -9 $other_pids" >&2
    exit 1
fi

cat > "$CONF_FILE" << EOF
ServerRoot "$HTTPD_ROOT"
ServerName localhost
Listen $PORT
PidFile "$PID_FILE"
ErrorLog "$LOG_FILE"

LoadModule mpm_prefork_module lib/httpd/modules/mod_mpm_prefork.so
LoadModule unixd_module lib/httpd/modules/mod_unixd.so
LoadModule dir_module lib/httpd/modules/mod_dir.so
LoadModule mime_module lib/httpd/modules/mod_mime.so
LoadModule log_config_module lib/httpd/modules/mod_log_config.so
LoadModule autoindex_module lib/httpd/modules/mod_autoindex.so
LoadModule authz_core_module lib/httpd/modules/mod_authz_core.so
LoadModule authz_user_module lib/httpd/modules/mod_authz_user.so
LoadModule authn_core_module lib/httpd/modules/mod_authn_core.so
LoadModule authn_file_module lib/httpd/modules/mod_authn_file.so
LoadModule auth_basic_module lib/httpd/modules/mod_auth_basic.so
LoadModule headers_module lib/httpd/modules/mod_headers.so
LoadModule authz_host_module lib/httpd/modules/mod_authz_host.so
LoadModule access_compat_module lib/httpd/modules/mod_access_compat.so
LoadModule rewrite_module lib/httpd/modules/mod_rewrite.so
LoadModule alias_module lib/httpd/modules/mod_alias.so
LoadModule setenvif_module lib/httpd/modules/mod_setenvif.so
LoadModule env_module lib/httpd/modules/mod_env.so
LoadModule filter_module lib/httpd/modules/mod_filter.so

LoadModule php_module "$PHP_MODULE"
<FilesMatch \.php$>
    SetHandler application/x-httpd-php
</FilesMatch>

DocumentRoot "$FOLDER"

<Directory />
    AllowOverride None
    Require all denied
</Directory>

<Directory "$FOLDER">
    AllowOverride All
    Options Indexes FollowSymLinks
    Require all granted
</Directory>

DirectoryIndex index.php index.html index.htm
TypesConfig "$MIME_TYPES"
LogFormat "%h %l %u %t \"%r\" %>s %b" common
CustomLog "$LOG_FILE" common
EOF

echo "Starting apache on :$PORT for $FOLDER" >> "$LOG_FILE"
exec "$HTTPD_BIN" -f "$CONF_FILE" -DFOREGROUND
