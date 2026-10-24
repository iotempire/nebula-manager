#!/usr/bin/env bash
# Nebula client bundle installer (Linux / macOS)
# ==============================================
# Installs the certificate, private key, CA and config that sit next to this
# script. Existing files are backed up first. If config.yml already exists the
# script shows a diff and asks before overwriting it.
#
# Usage:
#   sudo bash install.sh [--dir /etc/nebula] [--service nebula.service]
#                        [--yes] [--no-start]
#
# User-owned target (no sudo needed):
#   bash install.sh --dir ~/nebula --no-start
#
# Non-interactive: --yes (or NEBULA_INSTALL_YES=1). Never pipe this script into
# bash: it needs its own directory and (for the confirmation) a terminal.
set -uo pipefail

BUNDLE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd)"
DIR="/etc/nebula"
SERVICE=""
ASSUME_YES="${NEBULA_INSTALL_YES:-0}"
NO_START=0
CERTS_ONLY=0

say()  { printf '[install] %s\n' "$*"; }
warn() { printf '[install] WARNING: %s\n' "$*" >&2; }
die()  { printf '[install] ERROR: %s\n' "$*" >&2; exit 1; }

usage() {
    cat <<'EOF'
Usage: sudo bash install.sh [options]

Options:
  -d, --dir DIR        Install into DIR (default: /etc/nebula)
  -s, --service NAME   systemd unit / launchd label (default: nebula.service)
  -y, --yes            Do not ask before overwriting an existing config.yml
      --certs-only     Install/refresh only cert/key/CA; keep any config.yml
      --no-start       Install files only; do not (re)start the service
  -h, --help           This help

The archive contains a private key: transfer it over a trusted channel and
delete it from the client after installation.
EOF
}

while (( $# )); do
    case "$1" in
        -d|--dir)       [[ $# -ge 2 ]] || die "--dir needs a value"; DIR="$2"; shift 2 ;;
        --dir=*)        DIR="${1#*=}"; shift ;;
        -s|--service)   [[ $# -ge 2 ]] || die "--service needs a value"; SERVICE="$2"; shift 2 ;;
        --service=*)    SERVICE="${1#*=}"; shift ;;
        -y|--yes)       ASSUME_YES=1; shift ;;
        --certs-only)   CERTS_ONLY=1; shift ;;
        --no-start)     NO_START=1; shift ;;
        -h|--help)      usage; exit 0 ;;
        *)              warn "Unknown option: $1"; usage >&2; exit 2 ;;
    esac
done

DIR="${DIR/#\~/$HOME}"
[[ -n "$DIR" ]] || die "Empty install directory"

# --- elevation policy -------------------------------------------------------
# Use sudo only when the target really is not writable by us (or when we are
# not root). This keeps user-owned directories (and tests) sudo-free.
SUDO=""
if [[ "$(id -u)" -ne 0 ]]; then
    writable=0
    if [[ -d "$DIR" ]]; then
        [[ -w "$DIR" ]] && writable=1
    else
        parent="$(dirname "$DIR")"
        [[ -d "$parent" && -w "$parent" ]] && writable=1
    fi
    if (( ! writable )); then
        command -v sudo >/dev/null 2>&1 \
            || die "root is required for $DIR and sudo is not installed"
        SUDO="sudo"
    fi
fi
asroot() { if [[ -n "$SUDO" ]]; then sudo "$@"; else "$@"; fi; }

# --- locate the bundle files ------------------------------------------------
shopt -s nullglob
CA="$BUNDLE_DIR/ca.crt"
[[ -f "$CA" ]] || die "ca.crt not found in $BUNDLE_DIR"

CERT="" KEY="" NAME=""
for f in "$BUNDLE_DIR"/*.crt; do
    base="$(basename "$f")"
    [[ "$base" == "ca.crt" ]] && continue
    n="${base%.crt}"
    if [[ -f "$BUNDLE_DIR/$n.key" ]]; then
        CERT="$f"; KEY="$BUNDLE_DIR/$n.key"; NAME="$n"; break
    fi
done
[[ -n "$CERT" ]] || die "no <name>.crt + <name>.key pair found in $BUNDLE_DIR"

TMPL=""
for c in "$BUNDLE_DIR/config.yml.template" "$BUNDLE_DIR/config.yml"; do
    [[ -f "$c" ]] && { TMPL="$c"; break; }
done
[[ -n "$TMPL" ]] || die "config.yml.template / config.yml not found in $BUNDLE_DIR"

# --- render the config for the chosen directory -----------------------------
RENDERED="$(mktemp)" || die "cannot create a temporary file"
CLEANUP_FILES=("$RENDERED")
cleanup() { rm -f "${CLEANUP_FILES[@]}"; }
trap cleanup EXIT
awk -v old="/etc/nebula" -v new="$DIR" '{
    while ((i = index($0, old)) > 0)
        $0 = substr($0, 1, i-1) new substr($0, i+length(old))
    print
}' "$TMPL" > "$RENDERED" || { rm -f "$RENDERED"; die "cannot render $TMPL"; }

CONFIG="$DIR/config.yml"

# --- existing config: show a diff and ask -----------------------------------
if [[ "$CERTS_ONLY" != "1" && -f "$CONFIG" ]]; then
    say "config.yml already exists: $CONFIG"
    say "Proposed changes (- existing, + bundle):"
    CURRENT="$CONFIG"
    if [[ ! -r "$CONFIG" ]]; then
        # Service-owned configs are often unreadable; show the diff through the
        # same privilege path used for the write.
        TMPCUR="$(mktemp)"
        CLEANUP_FILES+=("$TMPCUR")
        if asroot cat "$CONFIG" > "$TMPCUR" 2>/dev/null; then
            CURRENT="$TMPCUR"
        else
            warn "cannot read $CONFIG; showing the proposed file instead"
            CURRENT="/dev/null"
        fi
    fi
    if command -v diff >/dev/null 2>&1; then
        diff -u "$CURRENT" "$RENDERED" || true
    else
        warn "diff is not available; showing the proposed file instead"
        cat "$RENDERED"
    fi
    if [[ "$ASSUME_YES" != "1" ]]; then
        if [[ ! -t 0 ]]; then
            warn "refusing to overwrite config.yml without a terminal or --yes"
            rm -f "$RENDERED"
            exit 1
        fi
        printf 'Overwrite the existing config? [y/N] '
        read -r answer || answer=""
        case "$answer" in
            y|Y|yes|YES) ;;
            *) say "aborted - nothing was changed"
               say "Tip: --certs-only refreshes cert/key/CA without touching config.yml"
               rm -f "$RENDERED"; exit 1 ;;
        esac
    fi
fi

# --- install ----------------------------------------------------------------
asroot mkdir -p "$DIR" || { rm -f "$RENDERED"; die "cannot create $DIR"; }
STAMP="$(date +%Y%m%d-%H%M%S)"
backup() { [[ -f "$1" ]] && asroot cp -p "$1" "$1.bak.$STAMP" || true; }

if [[ "$CERTS_ONLY" != "1" ]]; then backup "$CONFIG"; fi
backup "$DIR/$NAME.crt"
backup "$DIR/$NAME.key"
backup "$DIR/ca.crt"

asroot cp "$CERT" "$DIR/$NAME.crt" || { rm -f "$RENDERED"; die "failed to install $NAME.crt"; }
asroot cp "$KEY"  "$DIR/$NAME.key"  || { rm -f "$RENDERED"; die "failed to install $NAME.key"; }
asroot cp "$CA"   "$DIR/ca.crt"     || { rm -f "$RENDERED"; die "failed to install ca.crt"; }
asroot chmod 644 "$DIR/$NAME.crt" "$DIR/ca.crt" 2>/dev/null || true
asroot chmod 600 "$DIR/$NAME.key" 2>/dev/null || true
if [[ "$CERTS_ONLY" == "1" ]]; then
    if [[ -f "$CONFIG" ]]; then
        say "Kept the existing config.yml (--certs-only)"
    else
        warn "--certs-only: no config.yml installed (none existed)"
    fi
else
    asroot cp "$RENDERED" "$CONFIG" || { rm -f "$RENDERED"; die "failed to install config.yml"; }
    asroot chmod 644 "$CONFIG" 2>/dev/null || true
fi
rm -f "$RENDERED"

say "Installed '$NAME' into $DIR"
if [[ "$CERTS_ONLY" == "1" ]]; then
    say "  $NAME.crt, $NAME.key, ca.crt"
else
    say "  $NAME.crt, $NAME.key, ca.crt, config.yml"
fi

# --- validate ---------------------------------------------------------------
NEBULA=""
if command -v nebula >/dev/null 2>&1; then
    NEBULA="$(command -v nebula)"
elif [[ -x "$DIR/nebula" ]]; then
    NEBULA="$DIR/nebula"
fi
if [[ -n "$NEBULA" ]]; then
    if [[ -f "$CONFIG" ]]; then
        if "$NEBULA" -test -config "$CONFIG"; then
            say "Configuration validated with nebula -test"
        else
            warn "nebula -test reported a problem; check $CONFIG before starting the service"
        fi
    else
        say "No config.yml present; skipped validation"
    fi
else
    say "nebula binary not found in PATH; skipped config validation"
fi

# --- service ----------------------------------------------------------------
if [[ "$NO_START" == "1" ]]; then
    say "Service start skipped (--no-start)"
    say "Done. Start Nebula manually or with your service manager."
    exit 0
fi

OS="$(uname -s 2>/dev/null || echo unknown)"
if [[ "$OS" == "Darwin" ]]; then
    if command -v brew >/dev/null 2>&1 && brew services list 2>/dev/null | awk 'NR>1 { print $1 }' | grep -qx nebula; then
        if brew services restart nebula; then
            say "Restarted nebula via 'brew services'"
        else
            warn "could not restart nebula via 'brew services'"
        fi
    else
        LABEL="$SERVICE"
        if [[ -z "$LABEL" ]]; then
            for p in "$HOME/Library/LaunchAgents"/*nebula*.plist \
                     /Library/LaunchDaemons/*nebula*.plist \
                     /Library/LaunchAgents/*nebula*.plist; do
                [[ -f "$p" ]] && { LABEL="$(basename "$p" .plist)"; break; }
            done
        fi
        if [[ -n "$LABEL" ]]; then
            if launchctl print "system/$LABEL" >/dev/null 2>&1; then
                if asroot launchctl kickstart -k "system/$LABEL"; then
                    say "Restarted launchd service $LABEL"
                else
                    warn "could not restart launchd service $LABEL"
                fi
            elif launchctl print "gui/$(id -u)/$LABEL" >/dev/null 2>&1; then
                if launchctl kickstart -k "gui/$(id -u)/$LABEL"; then
                    say "Restarted launchd service $LABEL"
                else
                    warn "could not restart launchd service $LABEL"
                fi
            else
                warn "launchd label '$LABEL' is not loaded; start Nebula manually"
            fi
        else
            warn "no Nebula launchd/brew service found; start Nebula manually"
        fi
    fi
elif command -v systemctl >/dev/null 2>&1; then
    SVC="${SERVICE:-nebula.service}"
    SVC="$(basename "$SVC")"
    if systemctl cat "$SVC" >/dev/null 2>&1; then
        asroot systemctl enable "$SVC" >/dev/null 2>&1 || true
        if asroot systemctl restart "$SVC"; then
            say "Restarted $SVC"
        elif asroot systemctl start "$SVC"; then
            say "Started $SVC"
        else
            warn "could not start $SVC; run 'systemctl status $SVC' for details"
        fi
    else
        warn "systemd unit '$SVC' not found; install Nebula's service unit first"
        warn "files are installed - start Nebula manually once the unit exists"
    fi
else
    warn "no systemd/launchd detected; start Nebula manually"
fi
