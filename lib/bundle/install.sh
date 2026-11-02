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
NO_DNS=0

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
      --no-dns         Do not configure systemd-resolved (mesh DNS)
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
        --no-dns)       NO_DNS=1; shift ;;
        -h|--help)      usage; exit 0 ;;
        *)              warn "Unknown option: $1"; usage >&2; exit 2 ;;
    esac
done

DIR="${DIR/#\~/$HOME}"
[[ -n "$DIR" ]] || die "Empty install directory"
SVC="$(basename "${SERVICE:-nebula.service}")"

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

# If the unit runs as an unprivileged user, the files must be owned by that
# user: the private key is mode 600 and otherwise unreadable for the service.
SERVICE_USER=""
if [[ -n "$SUDO" ]] && command -v systemctl >/dev/null 2>&1; then
    SERVICE_USER="$(systemctl show -p User --value "$SVC" 2>/dev/null || true)"
    [[ "$SERVICE_USER" == "root" ]] && SERVICE_USER=""
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
if [[ "$DIR" == "/etc/nebula" ]]; then
    # The template already points at the default directory: nothing to rewrite.
    cp "$TMPL" "$RENDERED" || { rm -f "$RENDERED"; die "cannot render $TMPL"; }
else
    # Substitute while consuming the line, so the loop always terminates - even
    # when the new path contains the old one. (Replacing in place spun forever
    # when old == new, which stalled every default /etc/nebula install.)
    awk -v old="/etc/nebula" -v new="$DIR" '{
        out = ""
        while ((i = index($0, old)) > 0) {
            out = out substr($0, 1, i-1) new
            $0 = substr($0, i+length(old))
        }
        print out $0
    }' "$TMPL" > "$RENDERED" || { rm -f "$RENDERED"; die "cannot render $TMPL"; }
fi

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

# Keep the ownership of an existing installation when the unit names no user
# (service-owned /etc/nebula directories often belong to a dedicated uid).
if [[ -z "$SERVICE_USER" && -n "$SUDO" && -e "$DIR/$NAME.crt" ]]; then
    SERVICE_USER="$(ls -nd "$DIR/$NAME.crt" 2>/dev/null | awk '{ print $3":"$4 }')"
fi

asroot cp "$CERT" "$DIR/$NAME.crt" || { rm -f "$RENDERED"; die "failed to install $NAME.crt"; }
asroot cp "$KEY"  "$DIR/$NAME.key"  || { rm -f "$RENDERED"; die "failed to install $NAME.key"; }
asroot cp "$CA"   "$DIR/ca.crt"     || { rm -f "$RENDERED"; die "failed to install ca.crt"; }
asroot chmod 644 "$DIR/$NAME.crt" "$DIR/ca.crt" 2>/dev/null || true
asroot chmod 600 "$DIR/$NAME.key" 2>/dev/null || true
if [[ -n "$SERVICE_USER" ]]; then
    asroot chown "$SERVICE_USER" "$DIR/$NAME.crt" "$DIR/$NAME.key" "$DIR/ca.crt" 2>/dev/null \
        || warn "could not hand the installed files to '$SERVICE_USER'"
fi
if [[ "$CERTS_ONLY" == "1" ]]; then
    if [[ -f "$CONFIG" ]]; then
        say "Kept the existing config.yml (--certs-only)"
    else
        warn "--certs-only: no config.yml installed (none existed)"
    fi
else
    asroot cp "$RENDERED" "$CONFIG" || { rm -f "$RENDERED"; die "failed to install config.yml"; }
    asroot chmod 644 "$CONFIG" 2>/dev/null || true
    [[ -n "$SERVICE_USER" ]] && asroot chown "$SERVICE_USER" "$CONFIG" 2>/dev/null || true
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
        # A root-owned 600 key cannot be read as the invoking user; validate
        # with the same privilege used to install the files.
        VAL_CMD=( "$NEBULA" )
        if [[ -n "$SUDO" ]] && { [[ ! -r "$CONFIG" ]] || [[ ! -r "$DIR/$NAME.key" ]]; }; then
            VAL_CMD=( asroot "$NEBULA" )
        fi
        if "${VAL_CMD[@]}" -test -config "$CONFIG"; then
            say "Configuration validated with nebula -test"
        else
            warn "nebula -test reported a problem; check $CONFIG before starting the service"
        fi
    else
        say "No config.yml present; skipped validation"
    fi
else
    say "nebula binary not found in PATH; skipped config validation"
    NEED_BINARY=1
fi

# --- guidance when Nebula itself is not set up ------------------------------
NEED_UNIT=0
START_FAILED=0
: "${NEED_BINARY:=0}"
print_next_steps() {
    (( NEED_BINARY || NEED_UNIT )) || return 0
    local os; os="$(uname -s 2>/dev/null || echo unknown)"
    printf '\n'
    say "Next steps - Nebula is not fully set up on this host yet:"
    if (( NEED_BINARY )); then
        if [[ "$os" == "Darwin" ]]; then
            say "  * Install Nebula:  brew install nebula"
        else
            say "  * Install the Nebula binary:"
            say "      Debian/Ubuntu/Mint:  sudo apt install nebula"
            say "      Fedora/RHEL:         sudo dnf install nebula"
            say "      Arch/CachyOS:        sudo pacman -S nebula"
            say "      Other:               https://github.com/slackhq/nebula/releases"
        fi
    fi
    if (( NEED_UNIT )) && [[ "$os" != "Darwin" ]]; then
        say "  * Install the service unit and start it:"
        say "      sudo systemctl enable --now ${SVC:-nebula.service}"
    fi
    say "  Certificates and config are already in $DIR."
}

# --- optional mesh DNS (systemd-resolved) -----------------------------------
# The bundle carries nebula-dns.conf when the mesh suffix and the lighthouse
# overlay IPs were known at export time.
install_resolved_hook() {
    local iface="$1" domain="$2"; shift 2
    local -a ips=("$@")
    local rc; rc="$(command -v resolvectl)" || return 0
    local tmp; tmp="$(mktemp)"
    {
        printf '[Unit]\n'
        printf 'Description=Apply Nebula DNS settings to systemd-resolved\n'
        printf 'After=%s\n' "$SVC"
        printf 'Wants=%s\n\n' "$SVC"
        printf '[Service]\n'
        printf 'Type=oneshot\n'
        printf 'ExecStartPre=-/usr/bin/sleep 2\n'
        printf 'ExecStart=-%s dns %s %s\n' "$rc" "$iface" "${ips[*]}"
        printf 'ExecStart=-%s domain %s ~%s\n' "$rc" "$iface" "$domain"
        printf 'RemainAfterExit=yes\n\n'
        printf '[Install]\n'
        printf 'WantedBy=multi-user.target\n'
    } > "$tmp"
    local dest="/etc/systemd/system/nebula-manager-resolved.service"
    if asroot cp "$tmp" "$dest"; then
        asroot systemctl daemon-reload >/dev/null 2>&1 || true
        if asroot systemctl enable --now nebula-manager-resolved.service >/dev/null 2>&1; then
            say "Installed $dest (reapplies mesh DNS on boot)"
        else
            warn "could not enable nebula-manager-resolved.service"
        fi
    else
        warn "could not install $dest"
    fi
    rm -f "$tmp"
}

apply_bundle_dns() {
    local f="$BUNDLE_DIR/nebula-dns.conf"
    [[ -f "$f" ]] || return 0
    [[ "$(uname -s 2>/dev/null)" == "Linux" ]] || return 0
    local TUN="" DOMAIN="" LIGHTHOUSES=""
    local k v
    while IFS='=' read -r k v; do
        v="${v%\"}"; v="${v#\"}"
        case "$k" in
            TUN)         TUN="$v" ;;
            DOMAIN)      DOMAIN="$v" ;;
            LIGHTHOUSES) LIGHTHOUSES="$v" ;;
        esac
    done < "$f"
    [[ -n "${DOMAIN:-}" && -n "${LIGHTHOUSES:-}" ]] || return 0
    local -a ips=()
    read -r -a ips <<< "$LIGHTHOUSES"
    (( ${#ips[@]} )) || return 0
    local iface="${TUN:-nebula1}"
    if ! command -v resolvectl >/dev/null 2>&1; then
        warn "resolvectl (systemd-resolved) not found; enable mesh DNS manually:"
        warn "  sudo resolvectl dns $iface ${ips[*]}"
        warn "  sudo resolvectl domain $iface ~$DOMAIN"
        return 0
    fi
    local i
    for i in 1 2 3 4 5 6 7 8 9 10; do
        ip link show "$iface" >/dev/null 2>&1 && break
        sleep 1
    done
    if ! asroot resolvectl dns "$iface" "${ips[@]}"; then
        warn "could not point $iface at ${ips[*]}; set it manually"
        return 0
    fi
    asroot resolvectl domain "$iface" "~$DOMAIN" || warn "could not route ~$DOMAIN to $iface"
    say "Mesh DNS: ~$DOMAIN -> ${ips[*]} via $iface"
    say "The lighthouse only answers for hosts it has seen since it started."
    if [[ -n "$SUDO" ]] || [[ "$(id -u)" -eq 0 ]]; then
        install_resolved_hook "$iface" "$DOMAIN" "${ips[@]}"
    else
        say "Skipped the boot hook (user-owned install); reapply after reboot."
    fi
}

# --- service ----------------------------------------------------------------
if [[ "$NO_START" == "1" ]]; then
    say "Service start skipped (--no-start)"
    if [[ "$NO_DNS" != "1" && -f "$BUNDLE_DIR/nebula-dns.conf" ]]; then
        say "Mesh DNS not applied (the service was not started); re-run without --no-start."
    fi
    print_next_steps
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
            asroot journalctl -xeu "$SVC" --no-pager -n 12 2>/dev/null | sed 's/^/    /' || true
            START_FAILED=1
        fi
    else
        warn "systemd unit '$SVC' not found; install Nebula's service unit first"
        warn "files are installed - start Nebula manually once the unit exists"
        NEED_UNIT=1
    fi
else
    warn "no systemd/launchd detected; start Nebula manually"
fi

if [[ "$NO_DNS" == "1" ]]; then
    say "Mesh DNS setup skipped (--no-dns)"
elif (( START_FAILED )); then
    say "Mesh DNS not applied (the service did not start)."
else
    apply_bundle_dns
fi
print_next_steps
