#!/usr/bin/env bash
# shellcheck shell=bash
#
# lib/fleet.sh - deploy to a fleet of mesh nodes
# =============================================
# Bundles are prepared once, then handed out in one of three ways:
#
#   1. HTTP (recommended for a class): `fleet serve` publishes the bundle
#      directory read-only - with copyparty's password protection when it is
#      installed, otherwise with python's http.server. Everybody can download at
#      the same time and a student just picks the archive with their name.
#
#   2. croc (one receiver at a time): `fleet croc` streams one transfer per
#      bundle, one after the other, and uses the three-word code croc itself
#      prints. Good for a single student, a demo, or a node that is behind NAT
#      without a reachable port.
#
#   3. ssh: probe a target (name expansion, port 22, user candidates), fetch its
#      config, merge a firewall policy locally, show a diff, then upload with a
#      backup, `nebula -test` and a service restart. Passwordless sudo (or root)
#      is required for unattended changes.
#
# Everything here is user-space; privileged remote work is explicit and visible.

[[ -n "${NEBULA_MANAGER_FLEET_SOURCED:-}" ]] && return 0
NEBULA_MANAGER_FLEET_SOURCED=1

###################################################################
################### bundle preparation & sharing ##################
###################################################################
# A bundle contains a client private key. Bundle directories are git-ignored and
# are only ever published with a password unless the network is trusted.

# _fleet_bundle_dir_new ; default output directory for this run.
_fleet_bundle_dir_new() { printf '%s/fleet-bundles-%s' "$PWD" "$(date +%Y%m%d-%H%M%S)"; }

# _fleet_latest_bundle_dir ; newest ./fleet-bundles-* below the cwd.
_fleet_latest_bundle_dir() {
    local d
    d="$(ls -1dt ./fleet-bundles-*/ 2>/dev/null | head -n1)"
    [[ -n "$d" ]] || return 1
    printf '%s' "${d%/}"
}

# _fleet_lan_ip ; the address students are most likely able to reach.
_fleet_lan_ip() {
    local ip="" iface
    if command -v ip >/dev/null 2>&1; then
        ip="$(ip -4 route get 1.1.1.1 2>/dev/null \
            | awk '{ for (i = 1; i <= NF; i++) if ($i == "src") { print $(i + 1); exit } }')"
    fi
    if [[ -z "$ip" ]] && command -v hostname >/dev/null 2>&1; then
        ip="$(hostname -I 2>/dev/null | awk '{ print $1 }')"
    fi
    if [[ -z "$ip" ]] && command -v route >/dev/null 2>&1; then
        iface="$(route -n get default 2>/dev/null | awk '/interface:/ { print $2 }')"
        [[ -n "$iface" ]] && ip="$(ipconfig getifaddr "$iface" 2>/dev/null)"
    fi
    printf '%s' "${ip:-127.0.0.1}"
}

# _fleet_bundle_label <archive> ; the node name encoded in a bundle file name.
_fleet_bundle_label() {
    local b
    b="$(basename "$1")"
    b="${b%-nebula-bundle.zip}"
    b="${b%-nebula-bundle.tar.gz}"
    printf '%s' "$b"
}

# _fleet_bundles_in <dir> ; the bundle archives in a directory.
_fleet_bundles_in() {
    local dir="$1" had_nullglob=0
    shopt -q nullglob && had_nullglob=1
    shopt -s nullglob
    local -a found=( "$dir"/*-nebula-bundle.zip "$dir"/*-nebula-bundle.tar.gz )
    (( had_nullglob )) || shopt -u nullglob
    (( ${#found[@]} )) || return 1
    printf '%s\n' "${found[@]}"
}

# Resolve the policy file for one certificate. Prints the path (or nothing).
# Sets FLEET_FW_TEMP to a temp file the caller must clean up (may be empty).
_fleet_fw_path_for() {
    local name="$1" cert_dir="$2" mode="${3:-}"
    FLEET_FW_TEMP=""
    if [[ -n "$mode" ]]; then
        case "$mode" in
            pack:*) policy_resolve "${mode#pack:}" ;;
            permissive|default)
                FLEET_FW_TEMP="$(node_fw_render_policy "$mode")" || return 1
                printf '%s' "$FLEET_FW_TEMP" ;;
            *) return 0 ;;
        esac
        return 0
    fi
    # No explicit choice: use the node's saved firewall preference, then the
    # last one used in the TUI. Nothing is stored for "host"/"skip".
    local saved="" smode="" spack=""
    saved="$(node_fw_get "$name" 2>/dev/null || true)"
    [[ -n "$saved" ]] || saved="$(node_fw_get last 2>/dev/null || true)"
    [[ -n "$saved" ]] || return 0
    IFS=$'\t' read -r smode spack <<< "$saved"
    case "$smode" in
        pack) [[ -n "$spack" ]] && policy_resolve "$spack" ;;
        permissive|default)
            FLEET_FW_TEMP="$(node_fw_render_policy "$smode")" || return 1
            printf '%s' "$FLEET_FW_TEMP" ;;
        *) return 0 ;;
    esac
    return 0
}

# _fleet_fw_resolve <policy> <firewall-mode> ; sets FFW_POLICY and FFW_TEMP.
_fleet_fw_resolve() {
    local policy="$1" fw_mode="$2"
    FFW_POLICY=""; FFW_TEMP=""
    if [[ -n "$policy" ]]; then
        FFW_POLICY="$(policy_resolve "$policy")" \
            || { log_error "Policy pack not found: $policy"; return 1; }
        return 0
    fi
    case "$fw_mode" in
        ""|host|skip) return 0 ;;
        permissive|default)
            FFW_TEMP="$(node_fw_render_policy "$fw_mode")" || return 1
            FFW_POLICY="$FFW_TEMP" ;;
        pack:*)
            FFW_POLICY="$(policy_resolve "${fw_mode#pack:}")" \
                || { log_error "Policy pack not found: ${fw_mode#pack:}"; return 1; } ;;
        *)
            log_error "Invalid firewall mode: $fw_mode (host|permissive|default|pack:NAME|skip)"
            return 2 ;;
    esac
}

_fleet_fw_cleanup() { [[ -n "${FFW_TEMP:-}" ]] && rm -f "$FFW_TEMP"; FFW_TEMP=""; }

# _fleet_bundle_opts <args...> ; consumes the options shared by
# `fleet bundle`, `fleet croc` and `fleet serve` into FO_*; everything else (with
# its value) is left in FO_REST for the caller.
_fleet_bundle_opts() {
    FO_CERT_DIR=""; FO_OUT=""; FO_POLICY=""; FO_FW=""
    FO_SELECTS=(); FO_EXCLUDES=(); FO_REST=()
    while (( $# )); do
        case "$1" in
            --cert-dir)   shift; FO_CERT_DIR="${1:-}";   if (( $# )); then shift; fi; continue ;;
            --cert-dir=*) FO_CERT_DIR="${1#*=}" ;;
            --select)     shift; FO_SELECTS+=("${1:-}"); if (( $# )); then shift; fi; continue ;;
            --select=*)   FO_SELECTS+=("${1#*=}") ;;
            --exclude)    shift; FO_EXCLUDES+=("${1:-}"); if (( $# )); then shift; fi; continue ;;
            --exclude=*)  FO_EXCLUDES+=("${1#*=}") ;;
            --policy|-P)  shift; FO_POLICY="${1:-}";     if (( $# )); then shift; fi; continue ;;
            --policy=*)   FO_POLICY="${1#*=}" ;;
            --firewall)   shift; FO_FW="${1:-}";         if (( $# )); then shift; fi; continue ;;
            --firewall=*) FO_FW="${1#*=}" ;;
            --out|-o)     shift; FO_OUT="${1:-}";        if (( $# )); then shift; fi; continue ;;
            --out=*)      FO_OUT="${1#*=}" ;;
            *)            FO_REST+=("$1") ;;
        esac
        shift
    done
}

# _fleet_select <cert_dir> ; cert_select with the parsed FO_* selection.
_fleet_select() {
    local cert_dir="$1" s
    local -a args=()
    (( ${#FO_SELECTS[@]} )) || FO_SELECTS=(all)
    for s in "${FO_SELECTS[@]}"; do args+=( --select "$s" ); done
    if (( ${#FO_EXCLUDES[@]} )); then
        for s in "${FO_EXCLUDES[@]}"; do args+=( --exclude "$s" ); done
    fi
    cert_select "$cert_dir" "${args[@]}"
}

# _fleet_render_bundles <cert_dir> <out_dir> <fw_mode> [share_base]
# Renders one self-contained bundle per entry of SEL_NAMES and fills
# FR_NAMES / FR_BUNDLES / FR_SKIPPED. Returns 1 when nothing was written.
FR_NAMES=(); FR_BUNDLES=(); FR_SKIPPED=()
_fleet_render_bundles() {
    local cert_dir="$1" out_dir="$2" fw_mode="$3" share_base="${4:-}"
    local -a temps=()
    local i name fw_path fw_temp logf bundle f
    FR_NAMES=(); FR_BUNDLES=(); FR_SKIPPED=()
    ensure_dir "$out_dir" || return 1
    # Bundle creation redirects stderr to a log. Resolve the service config here,
    # where a "may I read it once with sudo?" prompt is still visible.
    if declare -F pki_detect_network_config >/dev/null; then
        pki_detect_network_config "$cert_dir" >/dev/null || true
    fi
    for i in "${!SEL_NAMES[@]}"; do
        name="${SEL_NAMES[i]}"
        [[ -n "$name" ]] || continue
        if [[ ! -f "$cert_dir/$name.key" ]]; then
            log_warn "Skipping $name: no local private key (mobile certs cannot be bundled)."
            FR_SKIPPED+=("$name")
            continue
        fi
        fw_path=""
        if [[ -n "${FFW_POLICY:-}" ]]; then
            fw_path="$FFW_POLICY"
        elif [[ -n "$fw_mode" ]]; then
            fw_path=""
        else
            FLEET_FW_TEMP=""
            fw_path="$(_fleet_fw_path_for "$name" "$cert_dir")" || fw_path=""
            fw_temp="${FLEET_FW_TEMP:-}"
            [[ -n "$fw_temp" ]] && temps+=("$fw_temp")
        fi
        logf="$out_dir/.bundle-$name.log"
        # No croc code on purpose: it does not exist before `croc send` prints
        # one, so the bundle README keeps its <CROC-CODE> placeholder.
        bundle="$(NEBULA_NO_PROMPT=1 pki_bundle_client_zip "$name" "$out_dir" "$cert_dir" \
                    "$fw_path" "$share_base" "" 2>"$logf" | tail -n1)"
        if [[ -z "$bundle" || ! -f "$bundle" ]]; then
            log_error "Could not create a bundle for $name (see $logf)."
            FR_SKIPPED+=("$name")
            continue
        fi
        FR_NAMES+=("$name"); FR_BUNDLES+=("$bundle")
    done
    if (( ${#temps[@]} )); then
        for f in "${temps[@]}"; do [[ -n "$f" ]] && rm -f "$f"; done
    fi
    (( ${#FR_NAMES[@]} > 0 ))
}

# _fleet_print_bundles <out_dir> ; table of the rendered bundles + next steps.
_fleet_print_bundles() {
    local out_dir="$1" i
    printf '\n%s\n' "Bundles ready ($out_dir):"
    printf '  %-32s %s\n' "Node" "Archive"
    printf '  %-32s %s\n' "----" "-------"
    for i in "${!FR_NAMES[@]}"; do
        printf '  %-32s %s\n' "${FR_NAMES[i]}" "$(basename "${FR_BUNDLES[i]}")"
    done
    if (( ${#FR_SKIPPED[@]} )); then
        printf '\nSkipped: %s\n' "${FR_SKIPPED[*]}"
    fi
    cat <<EOF

Hand them out:
  whole class (HTTP):   nebula-manager fleet serve --dir "$out_dir"
  one at a time:        nebula-manager fleet croc --dir "$out_dir"
  node already set up:  nebula-manager fleet ssh NODE --policy PACK --yes
EOF
}

###################################################################
################### fleet bundle (render only) ####################
###################################################################

fleet_bundle_usage() {
    cat <<'EOF'
Usage: nebula-manager fleet bundle [options]

Render one self-contained bundle per selected certificate: certificate, private
key, ca.crt, rendered client config, install.sh, install.ps1 and README.txt.
Nothing is transferred - hand the archives out afterwards with `fleet serve`
(HTTP, recommended for a class) or `fleet croc` (one receiver at a time).

Selection:
  --select SPEC        all | group:G | without:G | name:GLOB | ip:CIDR | cert:NAME
                       (repeatable; default: all exportable certificates)
  --exclude SPEC       Subtract a selection (repeatable)
  --cert-dir DIR       Certificate workspace

Firewall in the generated client config:
  --policy PACK        Embed a policy pack for every bundle
  --firewall MODE      host | permissive | default | pack:NAME | skip
                       (default: each node's saved choice, else the detected host)

Output:
  --out DIR            Bundle directory (default: ./fleet-bundles-<timestamp>)
EOF
}

fleet_bundle_cli() {
    _fleet_bundle_opts "$@"
    local o
    if (( ${#FO_REST[@]} )); then
        for o in "${FO_REST[@]}"; do
            case "$o" in
                -h|--help) fleet_bundle_usage; return 0 ;;
                *) log_error "Unknown option for 'fleet bundle': $o"
                   fleet_bundle_usage >&2; return 2 ;;
            esac
        done
    fi
    local cert_dir out fwrc=0
    cert_dir="${FO_CERT_DIR:-$(resolve_cert_dir)}"
    _fleet_fw_resolve "$FO_POLICY" "$FO_FW" || fwrc=$?
    if (( fwrc )); then _fleet_fw_cleanup; return "$fwrc"; fi
    if ! _fleet_select "$cert_dir"; then
        log_warn "No certificate matched the selection in $cert_dir."
        _fleet_fw_cleanup
        return 1
    fi
    out="${FO_OUT:-$(_fleet_bundle_dir_new)}"
    if ! _fleet_render_bundles "$cert_dir" "$out" "$FO_FW"; then
        log_error "No bundle could be created."
        _fleet_fw_cleanup
        return 1
    fi
    _fleet_fw_cleanup
    _fleet_print_bundles "$out"
    return 0
}

###################################################################
################# fleet serve (HTTP for a class) ##################
###################################################################

fleet_serve_usage() {
    cat <<'EOF'
Usage: nebula-manager fleet serve [--dir DIR] [options]

Publish a bundle directory over HTTP, read-only, so a whole class can download
at the same time. Students open one URL and pick the archive with their name.

Source:
  --dir DIR            Directory to serve (default: newest ./fleet-bundles-*)

Server:
  --port N             TCP port (default: 8000)
  --bind ADDR          Listen address (default: 0.0.0.0)
  --user NAME          Require this login (copyparty only)
  --password PASS      ...with this password (generated when omitted)
  --backend MODE       auto | copyparty | python (default: auto)
  --url-host HOST      Host printed in the student URLs (default: local IP)
  --dry-run            Print the command and the URLs, start nothing

copyparty is used when installed: one password for the class, browsable list,
resumable downloads. Without copyparty the plain python3 http.server runs - the
same files but **without a password**, so only on a network you trust.
EOF
}

# _fleet_serve_pass ; a readable random password (no shell metacharacters).
_fleet_serve_pass() {
    local p=""
    if command -v openssl >/dev/null 2>&1; then
        p="$(openssl rand -base64 24 2>/dev/null | tr -dc 'A-Za-z0-9' | cut -c1-16)"
    fi
    if [[ -z "$p" ]] && [[ -r /dev/urandom ]]; then
        p="$(head -c 32 /dev/urandom | base64 2>/dev/null | tr -dc 'A-Za-z0-9' | cut -c1-16)"
    fi
    [[ -n "$p" ]] || p="nebula$RANDOM$RANDOM"
    printf '%s' "$p"
}

fleet_serve_cli() {
    local dir="" port=8000 bind="0.0.0.0" user="" pass="" backend="auto" url_host="" dry=0
    local -a rest=()
    if (( $# )); then rest=("$@"); fi
    local i=0
    while (( i < ${#rest[@]} )); do
        case "${rest[i]}" in
            --dir)        i=$((i+1)); dir="${rest[i]:-}" ;;
            --dir=*)      dir="${rest[i]#*=}" ;;
            --port)       i=$((i+1)); port="${rest[i]:-}" ;;
            --port=*)     port="${rest[i]#*=}" ;;
            --bind)       i=$((i+1)); bind="${rest[i]:-}" ;;
            --bind=*)     bind="${rest[i]#*=}" ;;
            --user)       i=$((i+1)); user="${rest[i]:-}" ;;
            --user=*)     user="${rest[i]#*=}" ;;
            --password|--pass) i=$((i+1)); pass="${rest[i]:-}" ;;
            --password=*) pass="${rest[i]#*=}" ;;
            --backend)    i=$((i+1)); backend="${rest[i]:-}" ;;
            --backend=*)  backend="${rest[i]#*=}" ;;
            --url-host|--host) i=$((i+1)); url_host="${rest[i]:-}" ;;
            --url-host=*) url_host="${rest[i]#*=}" ;;
            --dry-run|-n) dry=1 ;;
            -h|--help)    fleet_serve_usage; return 0 ;;
            *) log_error "Unknown option for 'fleet serve': ${rest[i]}"
               fleet_serve_usage >&2; return 2 ;;
        esac
        i=$((i+1))
    done

    if [[ -z "$dir" ]]; then
        dir="$(_fleet_latest_bundle_dir)" || dir=""
    fi
    if [[ -z "$dir" ]]; then
        log_error "No bundle directory found. Create one first: nebula-manager fleet bundle"
        return 1
    fi
    [[ -d "$dir" ]] || { log_error "Not a directory: $dir"; return 1; }
    [[ "$port" =~ ^[0-9]+$ ]] || { log_error "--port must be a number"; return 2; }

    case "$backend" in
        auto)
            if command -v copyparty >/dev/null 2>&1; then backend="copyparty"; else backend="python"; fi ;;
        copyparty|python) : ;;
        *) log_error "Invalid --backend: $backend (auto|copyparty|python)"; return 2 ;;
    esac

    local generated=0
    if [[ "$backend" == "copyparty" && -n "$user" && -z "$pass" ]]; then
        pass="$(_fleet_serve_pass)"; generated=1
    fi

    local host="${url_host:-$(_fleet_lan_ip)}"
    local path_part="/" url
    [[ "$backend" == "copyparty" ]] && path_part="/bundles/"
    url="http://$host:$port$path_part"

    local -a cmd=()
    if [[ "$backend" == "copyparty" ]]; then
        cmd=( copyparty -p "$port" -i "$bind" )
        if [[ -n "$user" ]]; then
            cmd+=( -a "${user}:${pass}" -v "${dir}:/bundles:r,${user}" )
        else
            cmd+=( -v "${dir}:/bundles:r" )
        fi
    else
        cmd=( python3 -m http.server "$port" --directory "$dir" --bind "$bind" )
    fi

    local -a listed=()
    mapfile -t listed < <(_fleet_bundles_in "$dir" 2>/dev/null)

    printf '\n%s\n' "Serving $dir (${#listed[@]} bundle(s)) over HTTP"
    printf '  URL:      %s\n' "$url"
    if [[ "$backend" == "copyparty" && -n "$user" ]]; then
        printf '  login:    %s / %s\n' "$user" "$pass"
        (( generated )) && printf '            (password generated for this run)\n'
        printf '  notes:    read-only, no uploads; students can browse and pick their file\n'
    elif [[ "$backend" == "copyparty" ]]; then
        printf '  notes:    read-only, **no password** - anyone who reaches the port can download\n'
    else
        printf '  backend:  python3 http.server - plain directory index, **no password**\n'
        printf '            install copyparty for a login: python3 -m pip install --user copyparty\n'
        [[ -n "$user" ]] && log_warn "--user is ignored with the python backend: it has no authentication."
    fi

    if (( ${#listed[@]} )); then
        printf '\n  %s\n' "Download URLs (one archive per student):"
        local f
        for f in "${listed[@]}"; do
            printf '    %s\n' "$url$(basename "$f")"
        done
    else
        log_warn "No *-nebula-bundle.zip/.tar.gz in $dir - did 'fleet bundle' run?"
    fi

    cat <<EOF

Students (read-only, no uploads):
  open the URL, download the archive with their name, unpack it and run
    sudo bash install.sh                                  # Linux / macOS
    powershell -ExecutionPolicy Bypass -File install.ps1  # Windows

Only reachable inside this network. For students elsewhere:
  * forward TCP $port on your router to $host, or
  * reverse tunnel to a public host:  ssh -R $port:localhost:$port YOUR-VPS
    (then hand out http://YOUR-VPS:$port$path_part), or
  * open the local firewall:  sudo ufw allow $port/tcp

The archives contain private keys: share this URL with your class only.
EOF

    if (( dry )); then
        printf '\nCommand: %s\nDry run: the server was not started.\n' "${cmd[*]}"
        return 0
    fi
    printf '\nServer: %s\n(Ctrl-C stops it.)\n\n' "${cmd[*]}"
    "${cmd[@]}"
    log_info "HTTP server stopped."
    return 0
}

###################################################################
################# fleet croc (one at a time) ######################
###################################################################

# _fleet_croc_code <logfile> ; the three-word code croc printed (may be empty).
_fleet_croc_code() {
    awk '/Code is:/ { print $NF; exit }' "$1" 2>/dev/null
}

# _fleet_croc_relay_refused <logfile> ; croc exits 0 even when the relay refuses.
_fleet_croc_relay_refused() {
    grep -qiE 'relay admission rejected|relay connection failed|could not connect to' \
        "$1" 2>/dev/null
}

# _fleet_croc_send <archive> <logfile> <relay> <local_only>
# Runs croc in the foreground and streams its output, so the code croc prints is
# visible while the transfer waits for the receiver.
_fleet_croc_send() {
    local archive="$1" logf="$2" relay="${3:-}" local_only="${4:-0}"
    local -a args=( --yes send "$archive" )
    [[ -n "$relay" ]] && args=( --relay "$relay" "${args[@]}" )
    (( local_only )) && args=( --local "${args[@]}" )
    CROC_NO_UPDATE_CHECK=1 croc "${args[@]}" 2>&1 | tee "$logf"
    return "${PIPESTATUS[0]}"
}

fleet_croc_usage() {
    cat <<'EOF'
Usage: nebula-manager fleet croc [--dir DIR | --bundle FILE | --select SPEC] [...]

Share bundles with croc, one receiver at a time. croc picks its own three-word
code and the command prints it; the student runs `croc CODE`, unpacks the archive
and runs the installer.

For a whole class use `fleet serve` (HTTP) instead: croc's public relay limits
admissions per source IP, and a lab full of students shares one address.

Source (pick one):
  --dir DIR            Share every bundle in DIR, one after the other
  --bundle FILE        Share exactly this archive (repeatable)
  --select SPEC ...    Render the bundles first, then share them

Options:
  --cert-dir DIR       Certificate workspace (with --select)
  --policy PACK        Embed a policy pack (with --select)
  --firewall MODE      host | permissive | default | pack:NAME | skip
  --out DIR            Bundle directory (default: ./fleet-bundles-<timestamp>)
  --local              LAN only: multicast discovery + local relay, no internet
  --relay HOST[:PORT]  Use this croc relay (both sides must pass it)
  --dry-run            List what would be shared, start nothing

Ctrl-C aborts the current transfer and stops; the remaining bundles are listed
so you can run the command again for them.
EOF
}

fleet_croc_cli() {
    _fleet_bundle_opts "$@"
    local dir="" relay="${CROC_RELAY:-}" local_only=0 dry=0
    local -a files=() rest=()
    if (( ${#FO_REST[@]} )); then rest=("${FO_REST[@]}"); fi
    local i=0
    while (( i < ${#rest[@]} )); do
        case "${rest[i]}" in
            --dir)            i=$((i+1)); dir="${rest[i]:-}" ;;
            --dir=*)          dir="${rest[i]#*=}" ;;
            --bundle)         i=$((i+1)); files+=("${rest[i]:-}") ;;
            --bundle=*)       files+=("${rest[i]#*=}") ;;
            --relay)          i=$((i+1)); relay="${rest[i]:-}" ;;
            --relay=*)        relay="${rest[i]#*=}" ;;
            --local)          local_only=1 ;;
            --no-local)       local_only=0 ;;
            --dry-run|-n)     dry=1 ;;
            -h|--help)        fleet_croc_usage; return 0 ;;
            *) log_error "Unknown option for 'fleet croc': ${rest[i]}"
               fleet_croc_usage >&2; return 2 ;;
        esac
        i=$((i+1))
    done

    local -a archives=() labels=()
    local f fwrc=0
    if (( ${#files[@]} )); then
        for f in "${files[@]}"; do
            [[ -f "$f" ]] || { log_error "Bundle not found: $f"; return 1; }
            archives+=("$f"); labels+=("$(_fleet_bundle_label "$f")")
        done
    elif [[ -n "$dir" ]]; then
        [[ -d "$dir" ]] || { log_error "Not a directory: $dir"; return 1; }
        local -a found=()
        mapfile -t found < <(_fleet_bundles_in "$dir")
        if (( ${#found[@]} == 0 )); then
            log_error "No *-nebula-bundle.zip/.tar.gz in $dir"
            return 1
        fi
        for f in "${found[@]}"; do
            archives+=("$f"); labels+=("$(_fleet_bundle_label "$f")")
        done
    else
        local cert_dir out
        cert_dir="${FO_CERT_DIR:-$(resolve_cert_dir)}"
        _fleet_fw_resolve "$FO_POLICY" "$FO_FW" || fwrc=$?
        if (( fwrc )); then _fleet_fw_cleanup; return "$fwrc"; fi
        if ! _fleet_select "$cert_dir"; then
            log_warn "No certificate matched the selection in $cert_dir."
            _fleet_fw_cleanup
            return 1
        fi
        out="${FO_OUT:-$(_fleet_bundle_dir_new)}"
        if ! _fleet_render_bundles "$cert_dir" "$out" "$FO_FW"; then
            log_error "No bundle could be created."
            _fleet_fw_cleanup
            return 1
        fi
        _fleet_fw_cleanup
        archives=("${FR_BUNDLES[@]}")
        labels=("${FR_NAMES[@]}")
    fi

    if [[ -n "$relay" ]]; then
        printf '\nRelay: %s (both sides must use it)\n' "$relay"
    fi
    if (( local_only )); then
        printf '\nMode: LAN only (--local). Sender and student must be on the same network.\n'
    fi

    if (( dry )); then
        local -a dcmd=( --yes send )
        [[ -n "$relay" ]] && dcmd=( --relay "$relay" "${dcmd[@]}" )
        (( local_only )) && dcmd=( --local "${dcmd[@]}" )
        printf '\nWould share %d bundle(s), one after the other:\n' "${#archives[@]}"
        for i in "${!archives[@]}"; do
            printf '  %-32s %s\n' "${labels[i]}" "$(basename "${archives[i]}")"
        done
        printf '\nCommand per bundle: croc %s <archive>\n' "${dcmd[*]}"
        printf 'Dry run: no transfer was started.\n'
        return 0
    fi

    if ! command -v croc >/dev/null 2>&1; then
        log_error "croc is not installed. Install it (https://getcroc.com) or use 'fleet serve' instead."
        return 1
    fi

    local n="${#archives[@]}" rc logf logdir code
    local -a codes=() states=()
    for i in "${!archives[@]}"; do
        printf '\n=== Sharing %d/%d: %s ===\n' "$((i+1))" "$n" "${labels[i]}"
        printf 'Archive: %s\n\n' "${archives[i]}"
        logdir="$(dirname "${archives[i]}")"
        logf="$logdir/.croc-${labels[i]}.log"
        _fleet_croc_send "${archives[i]}" "$logf" "$relay" "$local_only"
        rc=$?
        code="$(_fleet_croc_code "$logf")"
        codes[i]="$code"
        if (( rc == 130 || rc == 143 )); then
            states[i]="interrupted"
            log_warn "Stopped during ${labels[i]}."
            break
        fi
        if (( rc == 0 )) && ! _fleet_croc_relay_refused "$logf"; then
            states[i]="delivered"
            log_success "Delivered ${labels[i]}${code:+ (croc code $code)}"
        else
            states[i]="failed"
            if _fleet_croc_relay_refused "$logf"; then
                log_error "croc's relay refused the transfer for ${labels[i]} (see $logf)."
                log_info "Retry in a minute, use --local inside one lab LAN, or serve the files: nebula-manager fleet serve --dir \"$logdir\""
            else
                log_error "Transfer failed for ${labels[i]}${code:+ (croc code $code)} - see $logf"
            fi
        fi
    done

    printf '\n%s\n' "croc sharing summary:"
    printf '  %-32s %-26s %s\n' "Node" "croc code" "Result"
    printf '  %-32s %-26s %s\n' "----" "---------" "------"
    local pending=0
    for i in "${!archives[@]}"; do
        [[ -n "${states[i]:-}" ]] || states[i]="not shared"
        [[ "${states[i]}" == "delivered" ]] || pending=$((pending + 1))
        printf '  %-32s %-26s %s\n' "${labels[i]}" "${codes[i]:--}" "${states[i]}"
    done

    if (( pending )); then
        printf '\nNot delivered - run again when the receivers are ready:\n'
        for i in "${!archives[@]}"; do
            [[ "${states[i]}" == "delivered" ]] && continue
            printf '  nebula-manager fleet croc --bundle %q\n' "${archives[i]}"
        done
    fi
    return 0
}
###################################################################
########################## SSH deployment #########################
###################################################################

_fleet_host_valid() { [[ "$1" =~ ^[A-Za-z0-9._-]+$ ]]; }
_fleet_user_valid() { [[ "$1" =~ ^[A-Za-z0-9._-]+$ ]]; }
_fleet_path_valid() { [[ "$1" =~ ^[A-Za-z0-9._/-]+$ ]]; }
_fleet_svc_valid()  { [[ "$1" =~ ^[A-Za-z0-9@._-]+$ ]]; }

# fleet_mesh_domains [cert_dir] ; unique cert-name domains, most common first.
fleet_mesh_domains() {
    local cert_dir="${1:-$(resolve_cert_dir)}"
    declare -F cert_domain_list >/dev/null || return 0
    cert_domain_list "$cert_dir" 2>/dev/null | awk -F'\t' 'NF && $1 != "" { print $1 }'
}

# fleet_host_candidates <target> [cert_dir]
fleet_host_candidates() {
    local target="$1" cert_dir="${2:-$(resolve_cert_dir)}" d
    if [[ "$target" == *.* ]]; then
        printf '%s\n' "$target"
        return 0
    fi
    while IFS= read -r d; do
        [[ -n "$d" ]] && printf '%s.%s\n' "$target" "$d"
    done < <(fleet_mesh_domains "$cert_dir")
    printf '%s\n' "$target.netbird.cloud" "$target.local" "$target"
}

# fleet_tcp_open <host> <port>
fleet_tcp_open() {
    local host="$1" port="${2:-22}"
    _fleet_host_valid "$host" || return 1
    if command -v nc >/dev/null 2>&1; then
        nc -z -w 2 "$host" "$port" >/dev/null 2>&1
        return $?
    fi
    timeout 2 bash -c "exec 3<>/dev/tcp/$host/$port" >/dev/null 2>&1
}

fleet_ssh_opts() {
    local -a o=( -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new )
    if (( ${FLEET_AUTH_INTERACTIVE:-0} )); then
        o+=( -o PreferredAuthentications=publickey,password,keyboard-interactive
              -o NumberOfPasswordPrompts=3 )
    else
        o+=( -o BatchMode=yes -o PreferredAuthentications=publickey )
    fi
    printf '%s\n' "${o[@]}"
}

# --- ssh auth modes ---------------------------------------------------------
# FLEET_AUTH_INTERACTIVE=1
#   Allow password / keyboard-interactive logins. Everything is key-only
#   without it.
# FLEET_SUDO_TTY=1
#   Privileged remote commands need a TTY (`requiretty`).
# FLEET_SUDO_PASSWORD=1
#   sudo needs a password. sudo caches that per TTY, so each privileged step
#   runs in its own `ssh -tt` session (see fleet_ssh_cli).
# FLEET_SSH_MASTER
#   Path of a reusable connection, opened only when the *ssh* login itself needs
#   a password (a key login has nothing to cache, and a master that dies takes
#   every later step with it).
FLEET_AUTH_INTERACTIVE=${FLEET_AUTH_INTERACTIVE:-0}
FLEET_SUDO_TTY=${FLEET_SUDO_TTY:-0}
FLEET_SUDO_PASSWORD=${FLEET_SUDO_PASSWORD:-0}
FLEET_SSH_MASTER=${FLEET_SSH_MASTER:-}

# _fleet_want_interactive ; is a password prompt useful right now?
# FLEET_INTERACTIVE_MODE=auto (default) allows prompts when a human is at a
# terminal and NEBULA_NO_PROMPT is not set. In cron/CI, and in every test (the
# harness sets NEBULA_NO_PROMPT=1), it stays key-only. --interactive and
# --no-interactive override the decision.
_fleet_want_interactive() {
    case "${FLEET_INTERACTIVE_MODE:-auto}" in
        on|1|yes|true)  return 0 ;;
        off|0|no|false) return 1 ;;
    esac
    [[ "${NEBULA_NO_PROMPT:-0}" == 1 ]] && return 1
    [[ -t 0 ]] && return 0
    [[ -t 2 && -r /dev/tty ]] && return 0
    return 1
}

# _fleet_ssh_master_start <user> <host> <port>
# Open a reusable connection for an ssh *password* login (one prompt, not one
# per step). Returns 1 when no usable master could be opened; callers then just
# run without it.
_fleet_ssh_master_start() {
    local user="$1" host="$2" port="$3" sock i
    (( FLEET_AUTH_INTERACTIVE )) || return 0
    [[ -n "$FLEET_SSH_MASTER" ]] && return 0
    sock="${TMPDIR:-/tmp}/nm-ssh-$$-${RANDOM}"
    log_info "Opening one shared SSH session to $user@$host (the ssh password is asked once)..."
    # -N: no remote command, just the multiplexed connection.
    ssh -M -S "$sock" -N -o ControlPersist=600 -o ConnectTimeout=10 \
        -o StrictHostKeyChecking=accept-new \
        -o PreferredAuthentications=publickey,password,keyboard-interactive \
        -o NumberOfPasswordPrompts=3 -p "$port" "$user@$host" &
    for i in 1 2 3 4 5 6 7 8 9 10; do
        [[ -e "$sock" ]] && break
        sleep 1
    done
    if [[ ! -e "$sock" ]]; then
        log_warn "Could not open the shared SSH session; each step will ask for the password separately."
        rm -f "$sock" 2>/dev/null || true
        return 1
    fi
    FLEET_SSH_MASTER="$sock"
    # An existing socket is not proof of a working session: a master that died
    # makes every later call fail with "Shared connection ... closed". Prove it.
    if ! ssh -S "$FLEET_SSH_MASTER" -o ConnectTimeout=5 -p "$port" "$user@$host" true >/dev/null 2>&1; then
        log_warn "The shared SSH session is not usable; each step will ask for the password separately."
        _fleet_ssh_master_stop
        return 1
    fi
    return 0
}

_fleet_ssh_master_stop() {
    [[ -n "$FLEET_SSH_MASTER" ]] || return 0
    ssh -S "$FLEET_SSH_MASTER" -O exit "x" >/dev/null 2>&1 || true
    rm -f "$FLEET_SSH_MASTER" 2>/dev/null || true
    FLEET_SSH_MASTER=""
}

# _fleet_ssh <user> <host> <port> <command...>
_fleet_ssh() {
    local user="$1" host="$2" port="$3"; shift 3
    local -a o=()
    mapfile -t o < <(fleet_ssh_opts)
    if [[ -n "$FLEET_SSH_MASTER" ]]; then
        ssh -S "$FLEET_SSH_MASTER" "${o[@]}" -p "$port" "$user@$host" "$@"
    else
        ssh "${o[@]}" -p "$port" "$user@$host" "$@"
    fi
}

# _fleet_ssh_tty ... ; same, but allocate a remote TTY (sudo can prompt).
# Never touch stdin here: callers use it to feed uploads (`tee`), and the remote
# sudo prompt is answered through the remote tty that ssh wires to our stdin.
_fleet_ssh_tty() {
    local user="$1" host="$2" port="$3"; shift 3
    local -a o=() cmd=(ssh -tt)
    mapfile -t o < <(fleet_ssh_opts)
    [[ -n "$FLEET_SSH_MASTER" ]] && cmd+=(-S "$FLEET_SSH_MASTER")
    cmd+=("${o[@]}" -p "$port" "$user@$host" "$@")
    "${cmd[@]}"
}

# _fleet_run_priv <remote command...> ; run with the probed sudo prefix.
_fleet_run_priv() {
    if (( FLEET_SUDO_TTY )); then
        _fleet_ssh_tty "$FLEET_USER" "$FLEET_HOST" "$FLEET_PORT" "$@"
    else
        _fleet_ssh "$FLEET_USER" "$FLEET_HOST" "$FLEET_PORT" "$@"
    fi
}

_fleet_ssh_ok() {
    local user="$1" host="$2" port="$3"
    _fleet_ssh "$user" "$host" "$port" true >/dev/null 2>&1
}

# fleet_probe <target> [options] ; sets FLEET_HOST FLEET_USER FLEET_PORT FLEET_SUDO
fleet_probe() {
    local target="$1"; shift
    local port=22 cert_dir="" target_user="" target_host="$target"
    local -a hosts=() users=() domains=()
    while (( $# )); do
        case "$1" in
            --port)     shift; port="${1:-22}" ;;
            --port=*)   port="${1#*=}" ;;
            --host)     shift; hosts+=("${1:-}") ;;
            --host=*)   hosts+=("${1#*=}") ;;
            --domain)   shift; domains+=("${1:-}") ;;
            --domain=*) domains+=("${1#*=}") ;;
            --user)     shift; users+=("${1:-}") ;;
            --user=*)   users+=("${1#*=}") ;;
            --cert-dir) shift; cert_dir="${1:-}" ;;
            --cert-dir=*) cert_dir="${1#*=}" ;;
            *) log_error "Unknown probe option: $1"; return 2 ;;
        esac
        shift
    done
    cert_dir="${cert_dir:-$(resolve_cert_dir)}"
    [[ "$port" =~ ^[0-9]+$ ]] || { log_error "Invalid port: $port"; return 2; }

    if [[ "$target" == *@* ]]; then
        target_user="${target%%@*}"
        target_host="${target#*@}"
    fi

    local -a candidates=("${hosts[@]}")
    local h d
    for d in "${domains[@]}"; do
        [[ -n "$d" ]] || continue
        _fleet_host_valid "$d" || { log_warn "Ignoring invalid domain: $d"; continue; }
        candidates+=("$target_host.$d")
    done
    while IFS= read -r h; do
        [[ -n "$h" ]] && candidates+=("$h")
    done < <(fleet_host_candidates "$target_host" "$cert_dir")
    # Deduplicate while preserving order.
    local -a uniq=()
    for h in "${candidates[@]}"; do
        [[ -n "$h" ]] || continue
        [[ " ${uniq[*]:-} " == *" $h "* ]] || uniq+=("$h")
    done
    candidates=("${uniq[@]}")

    local -a open=()
    for h in "${candidates[@]}"; do
        if fleet_tcp_open "$h" "$port"; then
            log_info "SSH port $port is open on $h"
            open+=("$h")
        else
            log_info "No SSH port $port on $h"
        fi
    done
    if (( ${#open[@]} == 0 )); then
        log_error "Could not reach any candidate on port $port: ${candidates[*]}"
        log_info "Try an explicit address (--host), or a NetBird/Tailscale name (e.g. node4.netbird.cloud)."
        return 1
    fi

    local -a ucand=()
    [[ -n "$target_user" ]] && ucand+=("$target_user")
    ucand+=("${users[@]}")
    if (( ${#ucand[@]} == 0 )); then
        ucand=("$(id -un 2>/dev/null || echo "$USER")" root user)
    fi
    local -a uuniq=()
    local u
    for u in "${ucand[@]}"; do
        [[ -n "$u" ]] || continue
        _fleet_user_valid "$u" || { log_warn "Ignoring invalid user name: $u"; continue; }
        [[ " ${uuniq[*]:-} " == *" $u "* ]] || uuniq+=("$u")
    done

    local found_user="" found_host="" found_key=0
    # Discovery is key-only on purpose: with password auth enabled ssh would
    # prompt for every candidate user.
    local _saved_interactive="$FLEET_AUTH_INTERACTIVE"
    FLEET_AUTH_INTERACTIVE=0
    for h in "${open[@]}"; do
        for u in "${uuniq[@]}"; do
            log_info "Trying $u@$h (key auth)..."
            if _fleet_ssh_ok "$u" "$h" "$port"; then
                found_user="$u"; found_host="$h"; found_key=1; break 2
            fi
        done
    done
    if [[ -z "$found_user" && "$_saved_interactive" == 1 ]]; then
        # Interactive mode: one password attempt for the most likely user (the
        # current one). Trying every candidate would mean several prompts in a
        # row; the question below lets the user name another account instead.
        FLEET_AUTH_INTERACTIVE=1
        local first_user="${uuniq[0]}"
        log_info "No key login worked; trying a password login as $first_user (you will be prompted)."
        for h in "${open[@]}"; do
            if _fleet_ssh "$first_user" "$h" "$port" true >/dev/null 2>&1; then
                found_user="$first_user"; found_host="$h"; break
            fi
        done
    fi
    FLEET_AUTH_INTERACTIVE="$_saved_interactive"
    if [[ -z "$found_user" ]]; then
        # Offer one interactive attempt (e.g. a personal account not in the
        # candidate list). Non-interactive callers use --user.
        if [[ -t 0 ]]; then
            local asked
            read -rp "$(show_status 'question') No login worked. Try another user: " asked || asked=""
            if [[ -n "$asked" ]] && _fleet_user_valid "$asked"; then
                for h in "${open[@]}"; do
                    if _fleet_ssh_ok "$asked" "$h" "$port"; then
                        found_user="$asked"; found_host="$h"; break
                    fi
                done
            fi
        fi
    fi
    if [[ -z "$found_user" ]]; then
        log_error "Port $port is open, but no login worked for: ${uuniq[*]}"
        log_info "Set up a key first: ssh-copy-id USER@${open[0]}"
        log_info "Then retry, or pass --user USER --host HOST / --interactive."
        return 1
    fi

    FLEET_HOST="$found_host"
    FLEET_USER="$found_user"
    FLEET_PORT="$port"

    # Reuse one connection only when the *ssh* login itself needed a password.
    # With key auth a master saves nothing (sudo's timestamp is per TTY) and a
    # master that dies would fail every later step.
    if (( FLEET_AUTH_INTERACTIVE )) && (( ! found_key )); then
        _fleet_ssh_master_start "$found_user" "$found_host" "$port" || true
    fi

    local sudo_prefix=""
    if [[ "$found_user" != "root" ]]; then
        if _fleet_ssh "$found_user" "$found_host" "$port" "sudo -n true" >/dev/null 2>&1; then
            sudo_prefix="sudo -n"
        elif (( FLEET_AUTH_INTERACTIVE )); then
            # sudo's timestamp is per-TTY by default (timestamp_type=tty), so
            # `sudo -v` in one session never authorizes the next one - never
            # warm it. Classify without prompting first: passwordless sudo that
            # only wants a TTY (`requiretty`) needs no password either.
            if _fleet_ssh_tty "$found_user" "$found_host" "$port" "sudo -n true" >/dev/null 2>&1; then
                # Passwordless sudo that only works with a TTY (sudoers
                # `requiretty`): no password needed, just allocate one.
                FLEET_SUDO_TTY=1
                sudo_prefix="sudo -n"
            elif [[ ! -t 0 && ! -r /dev/tty ]]; then
                # A remote sudo prompt is answered through our stdin/pty: with
                # no terminal at all the session would die instantly (or wait
                # for a password nobody can type). Say so instead.
                log_error "$found_user@$found_host needs a sudo password, but there is no terminal."
                log_info "Run the manager in a terminal, or use passwordless sudo / root login."
                _fleet_ssh_master_stop
                return 1
            else
                log_info "$found_user@$found_host: sudo will ask for your password (remote side)."
                FLEET_SUDO_PASSWORD=1
                sudo_prefix="sudo"
            fi
        else
            log_error "$found_user@$found_host requires a password for sudo."
            log_info "Unattended changes need passwordless sudo (sudoers) or root login."
            log_info "When run in a terminal (or with --interactive), the manager asks for the sudo password."
            return 1
        fi
    fi

    FLEET_SUDO="$sudo_prefix"
    local _mode="key auth"
    if (( ! found_key )); then
        _mode="password login"
    elif (( FLEET_AUTH_INTERACTIVE )); then
        _mode="key auth, prompts allowed"
    fi
    local _sudo="no sudo needed"
    if [[ -n "$sudo_prefix" ]]; then
        if (( FLEET_SUDO_PASSWORD )); then _sudo="sudo password (per session)"
        elif (( FLEET_SUDO_TTY )); then _sudo="sudo (TTY)"
        else _sudo="passwordless sudo"; fi
    fi
    log_success "Using $FLEET_USER@$FLEET_HOST:$FLEET_PORT ($_mode, $_sudo)"
    return 0
}

fleet_ssh_usage() {
    cat <<'EOF'
Usage: nebula-manager fleet ssh TARGET [options]

TARGET may be a name (node4), a FQDN (node4.example.net), or user@host.
Names without a dot are expanded using your certificate domains, then
`<name>.netbird.cloud`, `<name>.local` and the bare name. Port 22 is probed
first; then key-based login is tried as the target user, the current user,
root and `user`.

Change the remote config:
  --policy PACK          merge a firewall policy pack into the remote config
  --firewall MODE        host | permissive | default | pack:NAME | skip
  --firewall-file FILE   merge a local firewall file (bare firewall: or a pack)
  --relay IP[,IP]        set relay.use_relays + the relay list (repeatable)
  --no-relay             remove the remote relay: block
  --config FILE          push this complete config.yml instead of merging
  --from-store           push <cert-dir>/<name>.yml (the node's stored config)
  --remote-config PATH   Remote config path (default: /etc/nebula/config.yml)

Connection / safety:
  --host HOST            Extra candidate (repeatable)
  --domain DOMAIN        Also try <target>.DOMAIN (repeatable)
  --user USER            Extra login candidate (repeatable)
  --port N               SSH port (default: 22)
  --interactive          Force password/keyboard-interactive logins and let sudo
                         ask for a password on the remote host (one shared SSH
                         session; typed once).
  --no-interactive       Never prompt: keys only, sudo must be passwordless.
                         (Default: prompts are allowed when you are at a
                         terminal and NEBULA_NO_PROMPT is not set; scripts,
                         cron and CI stay key-only.)
  --service NAME         systemd unit (default: nebula.service)
  --yes                  Do not ask before applying
  --dry-run              Show the planned remote commands; change nothing
  --no-restart           Validate but do not restart the service

The remote config is fetched first, merged locally, diffed, then uploaded with
a timestamped backup. Requires key-based SSH and (unless root) passwordless sudo.
EOF
}

fleet_ssh_cli() {
    FLEET_SSH_TMP=()
    _fleet_ssh_cli_body "$@"
    local rc=$?
    local f
    for f in "${FLEET_SSH_TMP[@]:-}"; do
        [[ -n "$f" ]] && rm -rf "$f"
    done
    _fleet_ssh_master_stop
    return $rc
}

_fleet_ssh_cli_body() {
    local target="" port=22 policy="" fw_mode="" fw_file="" config_file="" remote_cfg="/etc/nebula/config.yml"
    local service="nebula.service" assume_yes=0 dry=0 no_restart=0 cert_dir="" from_store=0 store_name=""
    local relay_csv="" relay_off=0 interact=auto
    FLEET_SSH_TMP=()
    local -a extra_hosts=() extra_users=() extra_domains=()
    while (( $# )); do
        case "$1" in
            --host)          shift; extra_hosts+=("${1:-}") ;;
            --host=*)        extra_hosts+=("${1#*=}") ;;
            --user)          shift; extra_users+=("${1:-}") ;;
            --user=*)        extra_users+=("${1#*=}") ;;
            --domain)        shift; extra_domains+=("${1:-}") ;;
            --domain=*)      extra_domains+=("${1#*=}") ;;
            --port)          shift; port="${1:-22}" ;;
            --port=*)        port="${1#*=}" ;;
            --policy|-P)     shift; policy="${1:-}" ;;
            --policy=*)      policy="${1#*=}" ;;
            --firewall)      shift; fw_mode="${1:-}" ;;
            --firewall=*)    fw_mode="${1#*=}" ;;
            --firewall-file) shift; fw_file="${1:-}" ;;
            --firewall-file=*) fw_file="${1#*=}" ;;
            --config)        shift; config_file="${1:-}" ;;
            --config=*)      config_file="${1#*=}" ;;
            --from-store)    from_store=1 ;;
            --from-store=*)  from_store=1; store_name="${1#*=}" ;;
            --relay)         shift; relay_csv="${relay_csv:+$relay_csv,}${1:-}" ;;
            --relay=*)       relay_csv="${relay_csv:+$relay_csv,}${1#*=}" ;;
            --no-relay)      relay_off=1 ;;
            --remote-config) shift; remote_cfg="${1:-}" ;;
            --remote-config=*) remote_cfg="${1#*=}" ;;
            --service)       shift; service="${1:-}" ;;
            --service=*)     service="${1#*=}" ;;
            --cert-dir)      shift; cert_dir="${1:-}" ;;
            --cert-dir=*)    cert_dir="${1#*=}" ;;
            --interactive|--ask-auth|--ask-password) interact=on ;;
            --batch|--no-interactive) interact=off ;;
            --yes|-y)        assume_yes=1 ;;
            --dry-run|-n)    dry=1 ;;
            --no-restart)    no_restart=1 ;;
            -h|--help)       fleet_ssh_usage; return 0 ;;
            -*)              log_error "Unknown option for 'fleet ssh': $1"; return 2 ;;
            *)               if [[ -z "$target" ]]; then target="$1"; else log_error "Unexpected argument: $1"; return 2; fi ;;
        esac
        shift
    done
    [[ -n "$target" ]] || { fleet_ssh_usage >&2; return 2; }
    _fleet_path_valid "$remote_cfg" || { log_error "Invalid remote config path: $remote_cfg"; return 2; }
    _fleet_svc_valid "$service"    || { log_error "Invalid service name: $service"; return 2; }

    # --from-store: the per-node config written next to the certificate, which is
    # what "everything the store knows about this node" means in practice.
    if (( from_store )); then
        [[ -n "$store_name" ]] || store_name="${target##*@}"
        [[ -n "$cert_dir" ]] || cert_dir="$(resolve_cert_dir)"
        config_file="$cert_dir/$store_name.yml"
        if [[ ! -f "$config_file" ]]; then
            log_error "No stored node config: $config_file"
            log_info "Create it with: nebula-manager cert config generate --all --force"
            log_info "Or push another file with --config FILE."
            return 1
        fi
    fi

    local pack_path="" fw_tmp=""

    if [[ -z "$config_file" && -z "$policy" && -z "$fw_mode" && -z "$fw_file" \
            && -z "$relay_csv" && "$relay_off" == 0 ]]; then
        log_error "Nothing to change: pass --policy PACK, --firewall MODE, --firewall-file FILE, --relay IP, --no-relay or --config FILE."
        return 2
    fi
    if [[ "$relay_csv" != "" && "$relay_off" == 1 ]]; then
        log_error "Use either --relay or --no-relay, not both."; return 2
    fi
    if [[ -n "$config_file" && ( -n "$policy" || -n "$fw_mode" || -n "$fw_file" || -n "$relay_csv" || "$relay_off" == 1 ) ]]; then
        log_warn "--config replaces the whole file; ignoring the policy/firewall/relay merge."
    fi
    if [[ -n "$fw_file" && ( -n "$policy" || -n "$fw_mode" ) ]]; then
        log_error "Use either --firewall-file or --policy/--firewall, not both."; return 2
    fi
    if [[ -n "$fw_file" ]]; then
        [[ -f "$fw_file" ]] || { log_error "Firewall file not found: $fw_file"; return 1; }
        if yq -e '.firewall' "$fw_file" >/dev/null 2>&1; then
            pack_path="$fw_file"
        else
            # `policy export` writes a bare firewall mapping; wrap it.
            pack_path="$(mktemp)" || return 1
            FLEET_SSH_TMP+=("$pack_path")
            if ! FW_FILE="$fw_file" yq -n '.firewall = load(strenv(FW_FILE))' > "$pack_path"; then
                log_error "Could not parse $fw_file as a firewall fragment."
                return 1
            fi
        fi
        policy_validate "$pack_path" || { log_error "$fw_file does not contain a valid firewall."; return 1; }
    fi
    if [[ -n "$config_file" && ! -f "$config_file" ]]; then
        log_error "Config file not found: $config_file"; return 1
    fi

    # Validate relay addresses before touching the remote host (the workspace
    # check is only a warning: the peer may belong to a different store).
    if [[ -n "$relay_csv" ]]; then
        local -a rraw=() rlist=()
        local rr
        IFS=',' read -ra rraw <<<"$relay_csv"
        for rr in "${rraw[@]}"; do
            rr="$(relay_normalize "$rr")"
            [[ -n "$rr" ]] || continue
            if ! relay_valid_ip "$rr"; then
                log_error "Not an IP address: '$rr' (--relay takes relay overlay IPs)"
                return 2
            fi
            rlist+=("$rr")
        done
        if (( ${#rlist[@]} == 0 )); then
            log_error "--relay needs at least one address."; return 2
        fi
        relay_csv="$(IFS=','; printf '%s' "${rlist[*]}")"
        for rr in "${rlist[@]}"; do
            if [[ -z "$(relay_owner "$rr" "${cert_dir:-$(resolve_cert_dir)}" || true)" ]]; then
                log_warn "Relay $rr is not a certificate in the local workspace; pushing it anyway."
            fi
        done
    fi

    local -a probe_args=(--port "$port")
    [[ -n "$cert_dir" ]] && probe_args+=(--cert-dir "$cert_dir")
    local h u d
    for h in "${extra_hosts[@]}"; do probe_args+=(--host "$h"); done
    for d in "${extra_domains[@]}"; do probe_args+=(--domain "$d"); done
    for u in "${extra_users[@]}"; do probe_args+=(--user "$u"); done
    FLEET_INTERACTIVE_MODE="$interact"
    FLEET_SUDO_PASSWORD=0
    if _fleet_want_interactive; then
        FLEET_AUTH_INTERACTIVE=1
    else
        FLEET_AUTH_INTERACTIVE=0
    fi
    FLEET_SUDO_TTY=0
    fleet_probe "$target" "${probe_args[@]}" || return 1

    # Resolve the local firewall fragment before touching the remote host.
    if [[ -n "$policy" ]]; then
        pack_path="$(policy_resolve "$policy")" || { log_error "Policy pack not found: $policy"; return 1; }
    elif [[ -n "$fw_mode" ]]; then
        case "$fw_mode" in
            host|skip) : ;;
            permissive|default)
                fw_tmp="$(node_fw_render_policy "$fw_mode")" || return 1
                FLEET_SSH_TMP+=("$fw_tmp")
                pack_path="$fw_tmp" ;;
            pack:*)
                pack_path="$(policy_resolve "${fw_mode#pack:}")" || { log_error "Policy pack not found: ${fw_mode#pack:}"; return 1; } ;;
            *) log_error "Invalid --firewall mode: $fw_mode"; return 2 ;;
        esac
    fi

    local oldcfg newcfg tmpd
    tmpd="$(mktemp -d)" || return 1
    FLEET_SSH_TMP+=("$tmpd")
    oldcfg="$tmpd/remote.yml"; newcfg="$tmpd/new.yml"

    log_info "Fetching $remote_cfg from $FLEET_USER@$FLEET_HOST..."
    if (( FLEET_SUDO_PASSWORD )); then
        # With a TTY session sudo's prompt is part of the session *stdout*, so
        # `sudo cat > file` would write the prompt into the file and wait for a
        # password nobody can see. Stage a user-readable copy in one TTY session
        # (prompt visible), then read that copy with plain ssh.
        local staged
        staged="$(_fleet_ssh "$FLEET_USER" "$FLEET_HOST" "$FLEET_PORT" \
            'mktemp "${TMPDIR:-/tmp}/nm-read.XXXXXX"' 2>/dev/null | tail -n1)"
        [[ "$staged" == /* ]] || staged="/tmp/nm-read.$$"
        if ! _fleet_ssh_tty "$FLEET_USER" "$FLEET_HOST" "$FLEET_PORT" \
                "${FLEET_SUDO:+$FLEET_SUDO }cp -p '$remote_cfg' '$staged' && ${FLEET_SUDO:+$FLEET_SUDO }chown \$(id -u):\$(id -g) '$staged'"; then
            log_error "Could not read $remote_cfg on $FLEET_HOST"
            log_info "If sudo asked for a password, it was refused; otherwise the file may not exist."
            log_info "Log in as root, or grant passwordless sudo, if this host needs no password."
            return 1
        fi
        if ! _fleet_ssh "$FLEET_USER" "$FLEET_HOST" "$FLEET_PORT" \
                "cat '$staged'; rm -f '$staged'" > "$oldcfg"; then
            log_error "Could not read the staged copy $staged on $FLEET_HOST"
            return 1
        fi
    elif ! _fleet_run_priv "${FLEET_SUDO:+$FLEET_SUDO }cat '$remote_cfg'" > "$oldcfg"; then
        log_error "Could not read $remote_cfg on $FLEET_HOST"
        return 1
    fi
    [[ -s "$oldcfg" ]] || { log_error "Remote config is empty: $remote_cfg"; return 1; }

    if [[ -n "$config_file" ]]; then
        cp "$config_file" "$newcfg"
    else
        cp "$oldcfg" "$newcfg"
        if [[ -n "$pack_path" ]]; then
            policy_apply_to_config "$newcfg" "$pack_path" || return 1
        fi
        if [[ "$relay_off" == 1 ]]; then
            relay_apply_to_config "$newcfg" off || return 1
        elif [[ -n "$relay_csv" ]]; then
            relay_apply_to_config "$newcfg" use "$relay_csv" || return 1
        fi
    fi

    local diffout
    diffout="$(diff -u "$oldcfg" "$newcfg" 2>/dev/null || true)"
    if [[ -z "$diffout" ]]; then
        log_info "No changes needed on $FLEET_HOST."
        return 0
    fi
    printf '%s\n' "$diffout"
    if (( ! assume_yes )) && (( ! dry )); then
        if [[ ! -t 0 ]]; then
            log_error "Refusing to change $FLEET_HOST without a terminal or --yes."
            return 1
        fi
        local answer
        read -rp "$(show_status 'question') Apply this config to $FLEET_USER@$FLEET_HOST? [y/N]: " answer
        [[ "$answer" =~ ^[Yy]$ ]] || { log_info "Canceled - nothing changed."; return 0; }
    fi

    local remote_tmp="/tmp/nebula-manager-config.$$.yml" stamp
    stamp="$(date +%Y%m%d-%H%M%S)"
    local apply_cmd="${FLEET_SUDO:+$FLEET_SUDO }cp -p '$remote_cfg' '$remote_cfg.bak.$stamp' && "
    apply_cmd+="${FLEET_SUDO:+$FLEET_SUDO }cp '$remote_tmp' '$remote_cfg' && "
    apply_cmd+="${FLEET_SUDO:+$FLEET_SUDO }chmod 644 '$remote_cfg' && "
    apply_cmd+="${FLEET_SUDO:+$FLEET_SUDO }rm -f '$remote_tmp'"

    if (( dry )); then
        log_info "Dry run: would upload $(stat -c %s "$newcfg" 2>/dev/null || echo '?') bytes to $remote_tmp"
        log_info "Then run: $apply_cmd"
        [[ "$no_restart" == 1 ]] || log_info "Then restart: ${FLEET_SUDO:+$FLEET_SUDO }systemctl restart $service"
        return 0
    fi

    # With a sudo *password*, everything privileged happens inside ONE TTY
    # session (combined backup + install + test + restart) and the config is
    # shipped base64-encoded: sudo's timestamp is per-TTY, so separate ssh
    # calls would ask for the password again every time.
    if (( FLEET_SUDO_PASSWORD )); then
        _fleet_apply_tty_session "$newcfg" "$remote_cfg" "$service" "$no_restart" "$stamp" "$remote_tmp"
        return $?
    fi

    log_info "Uploading the new config..."
    if ! _fleet_run_priv "${FLEET_SUDO:+$FLEET_SUDO }tee '$remote_tmp' >/dev/null" < "$newcfg"; then
        log_error "Upload failed."
        return 1
    fi
    if ! _fleet_run_priv "$apply_cmd"; then
        log_error "Could not install the config (backup: $remote_cfg.bak.$stamp)."
        return 1
    fi
    log_success "Installed config on $FLEET_HOST (backup: $remote_cfg.bak.$stamp)"

    local nebula_bin
    nebula_bin="$(_fleet_ssh "$FLEET_USER" "$FLEET_HOST" "$FLEET_PORT" "command -v nebula 2>/dev/null || echo /usr/local/bin/nebula" 2>/dev/null | tr -d '\r' | tail -n1)"
    if [[ -n "$nebula_bin" ]] && ! _fleet_path_valid "$nebula_bin"; then
        log_warn "Ignoring unexpected nebula path on $FLEET_HOST: $nebula_bin"
        nebula_bin=""
    fi
    if [[ -n "$nebula_bin" ]] && _fleet_run_priv "${FLEET_SUDO:+$FLEET_SUDO }'$nebula_bin' -test -config '$remote_cfg'" >/dev/null 2>&1; then
        log_success "nebula -test passed on $FLEET_HOST"
    else
        log_warn "Could not validate on $FLEET_HOST (nebula binary not found or test failed)."
    fi

    if (( no_restart )); then
        log_info "Service restart skipped (--no-restart)."
    elif _fleet_run_priv "${FLEET_SUDO:+$FLEET_SUDO }systemctl restart '$service'"; then
        log_success "Restarted $service on $FLEET_HOST"
        _fleet_reapply_dns
    else
        log_warn "Could not restart $service on $FLEET_HOST; run it manually."
    fi
    return 0
}

###################################################################
########## serial: update one or many nodes over SSH ##############
###################################################################

fleet_update_usage() {
    cat <<'EOF'
Usage: nebula-manager fleet update [--select SPEC]... [--exclude SPEC]...
                                   <what to change> [options]

Push a config/firewall/relay change to the selected certificates, one host after
the other. Each host is resolved like `fleet ssh`: the certificate name is the
default target (node.pod.mesh), `--short` uses just the first label and lets
your local DNS or /etc/hosts resolve it, and `--host` overrides it (useful when
you deploy a single node).

What to change (same flags as `fleet ssh`):
  --policy PACK | --firewall MODE | --firewall-file FILE
  --relay IP[,IP] | --no-relay
  --from-store                  push each node's own <cert-dir>/<name>.yml
  --config FILE                 push the same complete config.yml to every node

Selection (default: all certificates with a local key):
  --select SPEC                 group:G, without:G, name:GLOB, ip:CIDR, cert:NAME, all
  --exclude SPEC                subtract from the selection
  --cert-dir DIR                Certificate workspace

Hosts and login:
  --short                       use <first-label> instead of the full cert name
  --host HOST                   force one host/user@host for every node
  --user USER                   login candidate (repeatable)
  --port N                      SSH port (default: 22)
  --interactive                 force password logins and a remote sudo password
                                (one shared SSH session, prompts once per host)
  --no-interactive              never prompt (keys only; default in scripts)

Safety:
  --yes            do not ask per node (required for a fully unattended run)
  --dry-run        fetch and diff, change nothing
  --no-restart     validate but do not restart the service
  --service NAME   systemd unit (default: nebula.service)

Examples:
  nebula-manager fleet update --select group:lab01 --relay 10.100.0.1 --interactive
  nebula-manager fleet update --select cert:ulno-ge75.ulno.mesh --policy lab01 --dry-run
  nebula-manager fleet update --select name:router* --short --no-relay --yes
EOF
}

# _fleet_host_for <cert-name> <style> ; style 0 = full cert name, 1 = first label.
_fleet_host_for() {
    local name="$1" style="${2:-0}"
    if (( style )); then printf '%s' "${name%%.*}"; else printf '%s' "$name"; fi
}

fleet_update_cli() {
    local cert_dir="" style=0 host_override="" dry=0 yes=0
    local -a selects=() excludes=() fwd=()
    local from_store=0
    while (( $# )); do
        case "$1" in
            --cert-dir)      shift; cert_dir="${1:-}"; if (( $# )); then shift; fi; continue ;;
            --cert-dir=*)    cert_dir="${1#*=}" ;;
            --select)        shift; selects+=("${1:-}"); if (( $# )); then shift; fi; continue ;;
            --select=*)      selects+=("${1#*=}") ;;
            --exclude)       shift; excludes+=("${1:-}"); if (( $# )); then shift; fi; continue ;;
            --exclude=*)     excludes+=("${1#*=}") ;;
            --short)         style=1 ;;
            --host)          shift; host_override="${1:-}"; if (( $# )); then shift; fi; continue ;;
            --host=*)        host_override="${1#*=}" ;;
            --user|--port|--policy|--firewall|--firewall-file|--config|--relay|--service|--remote-config)
                fwd+=("$1")
                if (( $# >= 2 )); then fwd+=("$2"); shift; fi
                shift; continue ;;
            --user=*|--port=*|--policy=*|--firewall=*|--firewall-file=*|--config=*|--relay=*|--service=*|--remote-config=*)
                fwd+=("$1") ;;
            --interactive|--ask-auth|--ask-password) fwd+=(--interactive) ;;
            --no-interactive|--batch) fwd+=(--no-interactive) ;;
            --yes|-y)        yes=1; fwd+=(--yes) ;;
            --dry-run|-n)    dry=1; fwd+=(--dry-run) ;;
            --no-restart)    fwd+=(--no-restart) ;;
            --no-relay)      fwd+=(--no-relay) ;;
            --from-store|--from-store=*) from_store=1 ;;
            -h|--help)       fleet_update_usage; return 0 ;;
            -*) log_error "Unknown option for 'fleet update': $1"; fleet_update_usage; return 2 ;;
            *)  log_error "Unexpected argument for 'fleet update': $1 (use --host for one host)"; return 2 ;;
        esac
        shift
    done
    (( ${#fwd[@]} )) || (( from_store )) || {
        log_error "Nothing to change: pass --policy, --firewall, --firewall-file, --relay, --no-relay, --from-store or --config."
        return 2
    }
    cert_dir="${cert_dir:-$(resolve_cert_dir)}"
    local -a selargs=() s
    for s in "${selects[@]}"; do selargs+=(--select "$s"); done
    for s in "${excludes[@]}"; do selargs+=(--exclude "$s"); done
    if ! cert_select "$cert_dir" "${selargs[@]}"; then
        log_warn "No certificate matched the selection in $cert_dir."
        return 1
    fi

    local i name host total="${#SEL_NAMES[@]}" ok=0 bad=0 skip=0
    local -a labels=() states=()
    for i in "${!SEL_NAMES[@]}"; do
        name="${SEL_NAMES[i]}"
        [[ -n "$name" ]] || continue
        if [[ ! -f "$cert_dir/$name.key" ]]; then
            log_info "Skipping $name: no local private key (device certificate)."
            labels+=("$name"); states+=("skipped"); skip=$((skip + 1))
            continue
        fi
        host="$(_fleet_host_for "$name" "$style")"
        [[ -n "$host_override" ]] && host="$host_override"
        printf '\n=== %d/%d  %s  ->  %s ===\n' "$((i + 1))" "$total" "$name" "$host"
        local -a call_args=("${fwd[@]}")
        # --from-store is per node: hand the certificate name to this call.
        (( from_store )) && call_args+=("--from-store=$name")
        if fleet_ssh_cli "$host" --cert-dir "$cert_dir" "${call_args[@]}"; then
            labels+=("$name"); states+=("updated"); ok=$((ok + 1))
        else
            labels+=("$name"); states+=("failed"); bad=$((bad + 1))
        fi
    done

    printf '\n%s\n' "Fleet update summary:"
    printf '  %-40s %s\n' "Node" "Result"
    for i in "${!labels[@]}"; do
        printf '  %-40s %s\n' "${labels[i]}" "${states[i]}"
    done
    printf '\n%d updated, %d failed, %d skipped\n' "$ok" "$bad" "$skip"
    if (( bad )); then
        log_info "Re-run a single node with: nebula-manager fleet ssh ${labels[0]} <same options> --interactive"
    fi
    (( bad == 0 ))
}

# TUI: walk through "which node(s), which host, which login, what to change".
# _fleet_ask_config_file <title> [default-path]
# Ask for a local config.yml, expand `~`, and verify it exists - re-asking is
# cheaper than failing after the SSH work has already started.
_fleet_ask_config_file() {
    local title="$1" def="${2:-}" path tries=0
    while (( tries < 3 )); do
        path="$(ui_input "$title" "Local config.yml to push:" "$def")" || return 1
        [[ -n "$path" ]] || return 1
        path="${path/#\~/$HOME}"
        if [[ -f "$path" ]]; then printf '%s' "$path"; return 0; fi
        log_error "No such file: $path"
        def=""
        tries=$(( tries + 1 ))
    done
    return 1
}

fleet_update_tui() {
    local cert_dir; cert_dir="$(resolve_cert_dir)"
    cert_select_tui "$cert_dir" || return 0
    (( ${#SEL_NAMES[@]} )) || return 0

    local -a args=( --cert-dir "$cert_dir" )
    if (( ${#SEL_NAMES[@]} == 1 )); then
        local full="${SEL_NAMES[0]}" host
        host="$(ui_input "Deploy to one node" \
            "Host for $full (Enter = the full mesh name; a short name or user@host also works):" "$full")" || return 0
        [[ -z "$host" ]] && host="$full"
        args+=( --host "$host" )
    else
        local style
        style="$(ui_menu "Deploy to ${#SEL_NAMES[@]} nodes" "Which host name per node?" \
            full  "The full certificate name (node.pod.mesh)" \
            short "Only the first label (node), resolved locally")" || return 0
        [[ "$style" == "short" ]] && args+=( --short )
    fi

    local login
    login="$(ui_menu "Deploy" "Log in as:" \
        me    "Current user ($(id -un 2>/dev/null || echo "${USER:-user}"))" \
        root  "root" \
        user  "user" \
        other "Another user (type it)")" || return 0
    case "$login" in
        root)  args+=( --user root ) ;;
        user)  args+=( --user user ) ;;
        other)
            local u; u="$(ui_input "Deploy" "Login user:")" || return 0
            [[ -n "$u" ]] || return 0
            args+=( --user "$u" ) ;;
    esac

    local auth
    auth="$(ui_menu "Deploy" "Authentication:" \
        auto        "Automatic: prompt only if keys are not enough" \
        keys        "Keys only (requires passwordless sudo)" \
        interactive "Always allow password prompts (ssh password + remote sudo)")" || return 0
    case "$auth" in
        keys)        args+=( --no-interactive ) ;;
        interactive) args+=( --interactive ) ;;
    esac

    local what
    what="$(ui_menu "Deploy" "What should change on the remote node(s)?" \
        pack       "Firewall: a policy pack" \
        mode       "Firewall: a built-in mode (default / permissive)" \
        relay      "Relay: use the default relay" \
        relay_pack "Both: relay + firewall pack" \
        store      "Everything from the stored config of each node (<name>.yml)" \
        config     "A complete config.yml file that I name") " || return 0

    local pack="" addr="" mode="" cfg=""
    case "$what" in
        pack|relay_pack) pack="$(policy_name_pick)" || return 0 ;;
    esac
    case "$what" in
        relay|relay_pack)
            addr="$(relay_default_get 2>/dev/null || true)"
            addr="$(ui_input "Deploy" "Relay overlay IP for these nodes:" "$addr")" || return 0
            [[ -n "$addr" ]] || return 0
            args+=( --relay "$addr" ) ;;
    esac
    case "$what" in
        mode)
            mode="$(ui_menu "Deploy" "Which built-in firewall?" \
                default    "Nebula defaults + ICMP (outbound allow, inbound drop)" \
                permissive "Permissive (bootstrap only)")" || return 0
            args+=( --firewall "$mode" ) ;;
        pack|relay_pack) args+=( --policy "$pack" ) ;;
        store)
            # The per-node configs in the workspace: firewall, relay, everything.
            local n missing=()
            for n in "${SEL_NAMES[@]}"; do
                [[ -f "$cert_dir/$n.yml" ]] || missing+=("$n")
            done
            if (( ${#missing[@]} )); then
                log_error "No stored node config for: ${missing[*]}"
                log_info "Create them with: nebula-manager cert config generate --all --force"
                log_info "Then pick this option again (or choose another entry)."
                return 0
            fi
            args+=( --from-store ) ;;
        config)
            local def=""
            if (( ${#SEL_NAMES[@]} == 1 )) && [[ -f "$cert_dir/${SEL_NAMES[0]}.yml" ]]; then
                def="$cert_dir/${SEL_NAMES[0]}.yml"
            fi
            cfg="$(_fleet_ask_config_file "Deploy" "$def")" || return 0
            args+=( --config "$cfg" ) ;;
    esac

    fleet_update_cli "${args[@]}"
}

# _fleet_reapply_dns ; after a restart the new tun device has no per-link DNS
# settings (mesh names stop resolving). Newer hosts carry
# nebula-manager-resolved.service with PartOf=nebula.service, so systemd already
# restarted it; hosts installed earlier need this explicit nudge. Silent: a
# missing unit is the normal case on hosts that never used mesh DNS.
_fleet_reapply_dns() {
    if _fleet_run_priv "${FLEET_SUDO:+$FLEET_SUDO }systemctl restart nebula-manager-resolved.service" >/dev/null 2>&1; then
        log_info "Reapplied mesh DNS (nebula-manager-resolved.service)."
    fi
    return 0
}

# _fleet_apply_tty_session <newcfg> <remote_cfg> <service> <no_restart> <stamp> <remote_tmp>
# Install the config with ONE privileged TTY session: the config travels as
# base64 inside the script, so `sudo` (and its per-TTY timestamp) is only
# involved for this single connection. Reports like the passwordless path.
_fleet_apply_tty_session() {
    local newcfg="$1" remote_cfg="$2" service="$3" no_restart="$4"
    local stamp="$5" remote_tmp="$6" b64 script
    b64="$(base64 -w0 < "$newcfg" 2>/dev/null)"
    [[ -n "$b64" ]] || b64="$(base64 < "$newcfg" | tr -d '\n')"
    [[ -n "$b64" ]] || { log_error "Could not encode $newcfg"; return 1; }

    script=$(cat <<EOF
set -e
trap 'echo "[apply] command failed (line \$LINENO)" >&2' ERR
tmp='$remote_tmp'
printf '%s' '$b64' | { base64 -d 2>/dev/null || base64 -D; } > "\$tmp"
sudo test -e '$remote_cfg.bak.$stamp' || sudo cp -p '$remote_cfg' '$remote_cfg.bak.$stamp'
sudo cp "\$tmp" '$remote_cfg'
sudo chmod 644 '$remote_cfg'
rm -f "\$tmp"
echo '[apply] config installed (backup: $remote_cfg.bak.$stamp)'
nebula_bin=\$(command -v nebula 2>/dev/null || echo /usr/local/bin/nebula)
if ! sudo "\$nebula_bin" -test -config '$remote_cfg'; then
    echo '[apply] nebula -test FAILED - the new config is in place, nothing was restarted.' >&2
    echo "[apply] roll back with: sudo cp -p '$remote_cfg.bak.$stamp' '$remote_cfg'" >&2
    exit 1
fi
echo '[apply] nebula -test passed'
EOF
)
    if [[ "$no_restart" != 1 ]]; then
        script+=$'\n'"if ! sudo systemctl restart '$service'; then"
        script+=$'\n'"    echo '[apply] service restart FAILED - check: systemctl status $service' >&2"
        script+=$'\n'"    exit 1"
        script+=$'\n'"fi"
        script+=$'\n'"echo '[apply] restarted $service'"
        # The new tun device starts without per-link DNS settings.
        script+=$'\n'"if sudo systemctl restart nebula-manager-resolved.service >/dev/null 2>&1; then"
        script+=$'\n'"    echo '[apply] reapplied mesh DNS (nebula-manager-resolved.service)'"
        script+=$'\n'"fi"
    fi
    script+=$'\n'"echo 'nebula-manager: done'"

    log_info "Applying in one privileged session (sudo asks once)..."
    # The script travels as a base64 *argument*, never through our stdin: with
    # `ssh -tt` the remote sudo prompt reads the remote tty, whose input is
    # whatever we feed ssh's stdin. A piped script would make that pipe the
    # answer to "[sudo] password" (so the prompt could never be answered).
    local body_b64
    body_b64="$(printf '%s\n' "$script" | base64 -w0 2>/dev/null)"
    [[ -n "$body_b64" ]] || body_b64="$(printf '%s\n' "$script" | base64 | tr -d '\n')"
    [[ -n "$body_b64" ]] || { log_error "Could not encode the apply script"; return 1; }
    if ! _fleet_ssh_tty "$FLEET_USER" "$FLEET_HOST" "$FLEET_PORT" \
            "printf %s '$body_b64' | { base64 -d 2>/dev/null || base64 -D; } | bash"; then
        log_error "Could not install the config on $FLEET_HOST (backup: $remote_cfg.bak.$stamp)."
        log_info "Read the [apply] lines above for the step that failed."
        log_info "Roll back on $FLEET_HOST with:"
        log_info "  sudo cp -p $remote_cfg.bak.$stamp $remote_cfg && sudo systemctl restart $service"
        return 1
    fi
    log_success "Installed config on $FLEET_HOST (backup: $remote_cfg.bak.$stamp)"
    log_success "nebula -test passed on $FLEET_HOST"
    if [[ "$no_restart" == 1 ]]; then
        log_info "Service restart skipped (--no-restart)."
    else
        log_success "Restarted $service on $FLEET_HOST"
    fi
    return 0
}

fleet_probe_cli() {
    local target="" opt
    local -a passthrough=()
    while (( $# )); do
        case "$1" in
            -h|--help)
                echo "Usage: nebula-manager fleet probe TARGET [--port N] [--host H] [--domain D] [--user U] [--cert-dir DIR]" >&2
                return 0 ;;
            --port|--host|--user|--domain|--cert-dir)
                opt="$1"
                passthrough+=("$1")
                shift
                [[ $# -gt 0 ]] || { log_error "$opt needs a value"; return 2; }
                passthrough+=("${1:-}") ;;
            --port=*|--host=*|--user=*|--domain=*|--cert-dir=*) passthrough+=("$1") ;;
            -*) log_error "Unknown option for 'fleet probe': $1"; return 2 ;;
            *)  if [[ -z "$target" ]]; then target="$1"; else log_error "Unexpected argument: $1"; return 2; fi ;;
        esac
        shift
    done
    [[ -n "$target" ]] || { echo "Usage: nebula-manager fleet probe TARGET" >&2; return 2; }
    fleet_probe "$target" "${passthrough[@]}"
}

fleet_usage() {
    cat <<'EOF'
Usage: nebula-manager fleet <command> [options]

Commands:
  bundle [options]    Render self-contained bundles; transfer nothing.
  serve [--dir DIR]   Publish a bundle directory over HTTP (password-protected
                      with copyparty) - the way to hand out a whole class.
  croc [options]      Share bundles with croc, one receiver at a time (croc
                      picks and prints the code).
  update [options]    Push firewall/relay/config changes to the selected nodes
                      over SSH, one host after the other (--interactive allows
                      password/sudo prompts).
  ssh TARGET [...]    Push a config/firewall change to one reachable node.
  probe TARGET [...]  Test SSH reachability and discover a login user.
  help                This help

Examples:
  nebula-manager fleet bundle --select group:students --policy students
  nebula-manager fleet serve --dir fleet-bundles-20261025-101500 --user class
  nebula-manager fleet croc --select cert:alice.mesh
  nebula-manager fleet croc --bundle fleet-bundles-*/alice.mesh-nebula-bundle.zip
  nebula-manager fleet probe node4
  nebula-manager fleet update --select group:lab01 --relay 10.100.0.1 --interactive
  nebula-manager fleet ssh node4 --policy home --yes
  nebula-manager fleet ssh node4 --config ./config.yml --dry-run
EOF
}

fleet_cli() {
    local sub="${1:-help}"; shift || true
    case "$sub" in
        bundle|prepare) fleet_bundle_cli "$@" ;;
        serve|http)     fleet_serve_cli "$@" ;;
        croc|share)     fleet_croc_cli "$@" ;;
        update|deploy|push-all) fleet_update_cli "$@" ;;
        ssh|push)       fleet_ssh_cli "$@" ;;
        probe)          fleet_probe_cli "$@" ;;
        -h|--help|help|"") fleet_usage ;;
        *) log_error "Unknown 'fleet' subcommand: $sub"; fleet_usage >&2; return 2 ;;
    esac
}

###################################################################
############################ TUI ##################################
###################################################################

# _fleet_bundle_selection_tui <title> ; sets FB_ARGS and FB_OUT.
# Shared by 'prepare bundles' and 'share via croc': pick certificates, the
# firewall for the generated configs and the output directory.
_fleet_bundle_selection_tui() {
    local title="$1" cert_dir pchoice out
    cert_dir="$(resolve_cert_dir)"
    cert_select_tui "$cert_dir" || return 1
    (( ${#SEL_NAMES[@]} > 0 )) || return 1

    local -a policy_opts=( __saved__ "Use each node's saved firewall choice" )
    if declare -F policy_pairs >/dev/null && policy_pairs; then
        local i
        for (( i=0; i<${#POLICY_PAIRS[@]}; i+=2 )); do
            policy_opts+=( "pack:${POLICY_PAIRS[i]}" "Policy pack: ${POLICY_PAIRS[i+1]}" )
        done
    fi
    pchoice="$(ui_menu "$title" "Firewall for these bundles:" "${policy_opts[@]}")" || return 1

    out="$(ui_input "$title" "Output directory:" "$(_fleet_bundle_dir_new)")" || return 1
    [[ -n "$out" ]] || out="$(_fleet_bundle_dir_new)"

    FB_ARGS=( --cert-dir "$cert_dir" --out "$out" )
    local n
    for n in "${SEL_NAMES[@]}"; do FB_ARGS+=( --select "cert:$n" ); done
    [[ "$pchoice" == __saved__ ]] || FB_ARGS+=( --firewall "$pchoice" )
    FB_OUT="$out"
    return 0
}

fleet_bundle_tui() {
    _fleet_bundle_selection_tui "Fleet bundles" || return 0
    fleet_bundle_cli "${FB_ARGS[@]}"
}

fleet_serve_tui() {
    local default_dir
    default_dir="$(_fleet_latest_bundle_dir 2>/dev/null)" || default_dir="$PWD"
    local dir
    dir="$(ui_input "Serve bundles" "Bundle directory:" "$default_dir")" || return 0
    [[ -z "$dir" ]] && dir="$default_dir"
    local port
    port="$(ui_input "Serve bundles" "Port:" "8000")" || return 0
    [[ -n "$port" ]] || port=8000
    local user
    user="$(ui_input "Serve bundles" "Login name (empty = no password, copyparty only):" "class")" || return 0
    local -a args=( --dir "$dir" --port "$port" )
    [[ -n "$user" ]] && args+=( --user "$user" )
    fleet_serve_cli "${args[@]}"
}

fleet_croc_tui() {
    _fleet_bundle_selection_tui "Share via croc" || return 0
    local mode
    mode="$(ui_menu "Share via croc" "Connection (one receiver at a time):" \
        __public__ "croc's public relay (default)" \
        __local__ "LAN only - same network, no internet" \
        __relay__ "This croc relay (host:port)")" || return 0
    case "$mode" in
        __local__) FB_ARGS+=( --local ) ;;
        __relay__)
            local r
            r="$(ui_input "Share via croc" "Relay (host[:port]):" "${CROC_RELAY:-}")" || return 0
            [[ -n "$r" ]] || return 0
            FB_ARGS+=( --relay "$r" ) ;;
    esac
    fleet_croc_cli "${FB_ARGS[@]}"
}

fleet_ssh_tui() {
    local target; target="$(ui_input "Fleet SSH" "Target (node4, FQDN, or user@host):")" || return 0
    [[ -z "$target" ]] && return 0
    local -a popts=( __none__ "Push no config change" )
    if declare -F policy_pairs >/dev/null && policy_pairs; then
        local i
        for (( i=0; i<${#POLICY_PAIRS[@]}; i+=2 )); do
            popts+=( "${POLICY_PAIRS[i]}" "Policy pack: ${POLICY_PAIRS[i+1]}" )
        done
    fi
    popts+=( __relay__ "Set relay settings (use_relays + relays)" )
    popts+=( __store__ "Push the node's stored config (<name>.yml in the workspace)" )
    popts+=( __file__ "Push a complete config.yml file" )
    local choice
    choice="$(ui_menu "Fleet SSH" "What should be applied on $target?" "${popts[@]}")" || return 0
    local -a args=( "$target" )
    case "$choice" in
        __none__) log_info "Canceled."; return 0 ;;
        __relay__)
            local addr
            addr="$(ui_input "Fleet SSH" "Relay IP(s), comma-separated (a certificate in your workspace):")" || return 0
            [[ -n "$addr" ]] || return 0
            args+=( --relay "$addr" ) ;;
        __file__)
            local f def="" cdir
            cdir="$(resolve_cert_dir)"
            [[ -f "$cdir/${target##*@}.yml" ]] && def="$cdir/${target##*@}.yml"
            f="$(_fleet_ask_config_file "Fleet SSH" "$def")" || return 0
            args+=( --config "$f" ) ;;
        __store__) args+=( --from-store ) ;;
        *) args+=( --policy "$choice" ) ;;
    esac
    fleet_ssh_cli "${args[@]}"
}

fleet_probe_tui() {
    local target; target="$(ui_input "Fleet probe" "Target (node4, FQDN, or user@host):")" || return 0
    [[ -z "$target" ]] && return 0
    fleet_probe "$target"
}

fleet_menu() {
    # shellcheck disable=SC2034  # passed to dynamic_menu by name
    dynamic_menu_title=("$MENU_PATH" "Fleet")
    # shellcheck disable=SC2034  # passed to dynamic_menu by name
    dynamic_menu_options=(
        "$(get_icon 'download')Prepare bundles (no transfer)"
        "$(get_icon 'link')Serve bundles over HTTP (class)"
        "$(get_icon 'upload')Share one bundle via croc"
        "$(get_icon 'update')Update node(s) over SSH (firewall, relay, config)"
        "$(get_icon 'connectivity')Push config/firewall over SSH (one host)"
        "$(get_icon 'scan')Probe SSH reachability"
    )
    # shellcheck disable=SC2034
    dynamic_menu_functions=( "fleet_bundle_tui" "fleet_serve_tui" "fleet_croc_tui" \
                             "fleet_update_tui" "fleet_ssh_tui" "fleet_probe_tui" )
    dynamic_menu dynamic_menu_title dynamic_menu_options dynamic_menu_functions 1 "" \
        "Hand out client bundles: HTTP for a whole class, croc for one receiver at a time, SSH to update nodes."
}
