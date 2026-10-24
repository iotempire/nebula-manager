#!/usr/bin/env bash
# shellcheck shell=bash
#
# lib/fleet.sh - deploy to a fleet of mesh nodes
# =============================================
# Two paths, in priority order:
#
#   1. croc (recommended for classes): render a self-contained bundle per node,
#      start one `croc send` process per bundle with a stable code, and print a
#      table of codes the students can redeem (`croc CODE`). No open ports, works
#      behind eduroam/NAT.
#
#   2. ssh: probe a target (name expansion, port 22, user candidates), fetch its
#      config, merge a firewall policy locally, show a diff, then upload with a
#      backup, `nebula -test` and a service restart. Passwordless sudo (or root)
#      is required for unattended changes.
#
# Everything here is user-space; privileged remote work is explicit and visible.

[[ -n "${NEBULA_MANAGER_FLEET_SOURCED:-}" ]] && return 0
NEBULA_MANAGER_FLEET_SOURCED=1

###################################################################
####################### croc mass deployment #####################
###################################################################

# fleet_make_code <name> ; a stable, unguessable code (>= 6 chars for croc).
fleet_make_code() {
    local name="$1" slug rand
    slug="$(printf '%s' "$name" | tr -cs 'A-Za-z0-9' '-' | sed 's/^-//;s/-$//' | cut -c1-24)"
    if command -v openssl >/dev/null 2>&1; then
        rand="$(openssl rand -hex 6 2>/dev/null)"
    fi
    [[ -n "${rand:-}" ]] || rand="$(printf '%04x%04x%04x' "$RANDOM" "$RANDOM" "$RANDOM")"
    printf '%s-%s' "${slug:-node}" "$rand"
}

# _fleet_pid_finished <pid> ; true when the process has exited (zombie or gone).
_fleet_pid_finished() {
    local p="$1"
    if [[ -r "/proc/$p/stat" ]]; then
        [[ "$(awk '{print $3}' "/proc/$p/stat" 2>/dev/null)" == "Z" ]]
    else
        ! ps -p "$p" >/dev/null 2>&1
    fi
}

_fleet_kill_pids() {
    local p
    for p in "${FLEET_PIDS[@]:-}"; do
        [[ -n "$p" ]] && kill "$p" 2>/dev/null
    done
}
FLEET_PIDS=()

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

fleet_croc_usage() {
    cat <<'EOF'
Usage: nebula-manager fleet croc [options]

Render a self-contained bundle per selected certificate and serve each one with
its own `croc send` process. Students run `croc CODE` to receive their bundle.

Selection:
  --select SPEC        all | group:G | without:G | name:GLOB | ip:CIDR | cert:NAME
                       (repeatable; default: all exportable certificates)
  --exclude SPEC       subtract a selection (repeatable)
  --cert-dir DIR       Certificate workspace

Firewall in the generated client config:
  --policy PACK        embed a policy pack for every bundle
  --firewall MODE      host | permissive | default | pack:NAME | skip
                       (default: each node's saved/last choice, else detected host)

Serving:
  --out DIR            Bundle directory (default: ./fleet-bundles-<timestamp>)
  --code-prefix TEXT   Prefix for croc codes (default: the certificate name)
  --timeout SECONDS    Stop waiting after N seconds (default: wait forever)
  --dry-run            Create the bundles and print codes/commands; start nothing

The bundles include install.sh / install.ps1 / README.txt, so students do not
need to clone nebula-manager.
EOF
}

fleet_croc_cli() {
    local cert_dir="" out_dir="" policy="" fw_mode="" code_prefix="" timeout=0 dry=0
    local -a selects=() excludes=()
    while (( $# )); do
        case "$1" in
            --cert-dir)    shift; cert_dir="${1:-}" ;;
            --cert-dir=*)  cert_dir="${1#*=}" ;;
            --select)      shift; selects+=("${1:-}") ;;
            --select=*)    selects+=("${1#*=}") ;;
            --exclude)     shift; excludes+=("${1:-}") ;;
            --exclude=*)   excludes+=("${1#*=}") ;;
            --policy|-P)   shift; policy="${1:-}" ;;
            --policy=*)    policy="${1#*=}" ;;
            --firewall)    shift; fw_mode="${1:-}" ;;
            --firewall=*)  fw_mode="${1#*=}" ;;
            --out|-o)      shift; out_dir="${1:-}" ;;
            --out=*)       out_dir="${1#*=}" ;;
            --code-prefix) shift; code_prefix="${1:-}" ;;
            --code-prefix=*) code_prefix="${1#*=}" ;;
            --timeout)     shift; timeout="${1:-0}" ;;
            --timeout=*)   timeout="${1#*=}" ;;
            --dry-run|-n)  dry=1 ;;
            -h|--help)     fleet_croc_usage; return 0 ;;
            *) log_error "Unknown option for 'fleet croc': $1"; fleet_croc_usage >&2; return 2 ;;
        esac
        shift
    done
    [[ "$timeout" =~ ^[0-9]+$ ]] || { log_error "--timeout must be a number of seconds"; return 2; }
    cert_dir="${cert_dir:-$(resolve_cert_dir)}"
    (( ${#selects[@]} )) || selects=(all)

    if ! command -v croc >/dev/null 2>&1 && (( ! dry )); then
        log_error "croc is not installed. Install it (https://github.com/schollz/croc) or use --dry-run."
        return 1
    fi

    # Explicit firewall choice (validated once).
    local fixed_policy="" fixed_tmp=""
    if [[ -n "$policy" ]]; then
        fixed_policy="$(policy_resolve "$policy")" || { log_error "Policy pack not found: $policy"; return 1; }
    elif [[ -n "$fw_mode" ]]; then
        case "$fw_mode" in
            host|skip) : ;;
            permissive|default)
                fixed_tmp="$(node_fw_render_policy "$fw_mode")" || return 1
                fixed_policy="$fixed_tmp" ;;
            pack:*)
                fixed_policy="$(policy_resolve "${fw_mode#pack:}")" || { log_error "Policy pack not found: ${fw_mode#pack:}"; return 1; } ;;
            *) log_error "Invalid --firewall mode: $fw_mode (host|permissive|default|pack:NAME|skip)"; return 2 ;;
        esac
    fi

    local -a selargs=()
    local s
    for s in "${selects[@]}"; do selargs+=(--select "$s"); done
    for s in "${excludes[@]}"; do selargs+=(--exclude "$s"); done
    if ! cert_select "$cert_dir" "${selargs[@]}"; then
        log_warn "No certificate matched the selection in $cert_dir."
        [[ -n "$fixed_tmp" ]] && rm -f "$fixed_tmp"
        return 1
    fi

    out_dir="${out_dir:-$PWD/fleet-bundles-$(date +%Y%m%d-%H%M%S)}"
    ensure_dir "$out_dir" || { [[ -n "$fixed_tmp" ]] && rm -f "$fixed_tmp"; return 1; }

    local -a names=() codes=() bundles=() live=() temp_files=()
    [[ -n "$fixed_tmp" ]] && temp_files+=("$fixed_tmp")
    local i name code bundle fw_path fw_temp logf
    for i in "${!SEL_NAMES[@]}"; do
        name="${SEL_NAMES[i]}"
        [[ -n "$name" ]] || continue
        if [[ ! -f "$cert_dir/$name.key" ]]; then
            log_warn "Skipping $name: no local private key (mobile certs cannot be bundled)."
            continue
        fi

        fw_path=""
        if [[ -n "$fixed_policy" ]]; then
            fw_path="$fixed_policy"
        elif [[ -n "$fw_mode" ]]; then
            fw_path=""
        else
            FLEET_FW_TEMP=""
            fw_path="$(_fleet_fw_path_for "$name" "$cert_dir")" || fw_path=""
            fw_temp="${FLEET_FW_TEMP:-}"
            [[ -n "$fw_temp" ]] && temp_files+=("$fw_temp")
        fi

        if [[ -n "$code_prefix" ]]; then
            code="$(fleet_make_code "${code_prefix}-${name}")"
        else
            code="$(fleet_make_code "$name")"
        fi
        logf="$out_dir/.bundle-$name.log"
        bundle="$(pki_bundle_client_zip "$name" "$out_dir" "$cert_dir" "$fw_path" "" "$code" 2>"$logf" | tail -n1)"
        if [[ -z "$bundle" || ! -f "$bundle" ]]; then
            log_error "Could not create a bundle for $name (see $logf)."
            continue
        fi
        names+=("$name"); codes+=("$code"); bundles+=("$bundle")
    done

    if (( ${#names[@]} == 0 )); then
        log_error "No bundle could be created."
        for f in "${temp_files[@]:-}"; do [[ -n "$f" ]] && rm -f "$f"; done
        return 1
    fi

    # Start one croc process per bundle. Codes are chosen by us, so no parsing.
    FLEET_PIDS=()
    local start=$SECONDS
    if (( ! dry )); then
        for i in "${!names[@]}"; do
            croc --yes send --code "${codes[i]}" "${bundles[i]}" \
                >"$out_dir/.croc-${names[i]}.log" 2>&1 &
            FLEET_PIDS+=($!)
            live+=("${names[i]}|${codes[i]}|${bundles[i]}|${FLEET_PIDS[${#FLEET_PIDS[@]}-1]}")
        done
        trap '_fleet_kill_pids' INT TERM
    fi

    printf '\n%s\n' "Bundles for your fleet ($out_dir):"
    printf '%-30s %-30s %s\n' "Node" "croc code" "Bundle"
    printf '%-30s %-30s %s\n' "----" "---------" "------"
    for i in "${!names[@]}"; do
        printf '%-30s %-30s %s\n' "${names[i]}" "${codes[i]}" "$(basename "${bundles[i]}")"
    done
    printf '\nStudents run:\n'
    for i in "${!names[@]}"; do
        printf '  croc %s    # %s\n' "${codes[i]}" "${names[i]}"
    done
    if (( dry )); then
        printf '\nDry run: bundles were created, no croc processes were started.\n'
        for f in "${temp_files[@]:-}"; do [[ -n "$f" ]] && rm -f "$f"; done
        return 0
    fi

    printf '\nWaiting for receivers (Ctrl-C to stop)...\n'
    local -a remaining=("${live[@]}")
    local entry rc n c p
    while (( ${#remaining[@]} > 0 )); do
        local -a next=()
        for entry in "${remaining[@]}"; do
            IFS='|' read -r n c _b p <<< "$entry"
            if _fleet_pid_finished "$p"; then
                if wait "$p"; then rc=0; else rc=$?; fi
                if (( rc == 0 )); then
                    log_success "Delivered $n (code $c)"
                else
                    log_error "Transfer failed for $n (code $c) - see $out_dir/.croc-$n.log"
                fi
            else
                next+=("$entry")
            fi
        done
        remaining=("${next[@]}")
        (( ${#remaining[@]} == 0 )) && break
        if (( timeout > 0 && SECONDS - start >= timeout )); then
            log_warn "Timeout after ${timeout}s; stopping ${#remaining[@]} transfer(s)."
            for entry in "${remaining[@]}"; do
                IFS='|' read -r n c _b p <<< "$entry"
                kill "$p" 2>/dev/null
            done
            break
        fi
        sleep 1
    done
    for f in "${temp_files[@]:-}"; do [[ -n "$f" ]] && rm -f "$f"; done
    trap - INT TERM
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
    printf '%s\n' -o BatchMode=yes -o ConnectTimeout=5 \
        -o StrictHostKeyChecking=accept-new -o PreferredAuthentications=publickey
}

# _fleet_ssh <user> <host> <port> <command...>
_fleet_ssh() {
    local user="$1" host="$2" port="$3"; shift 3
    ssh -o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new \
        -o PreferredAuthentications=publickey -p "$port" "$user@$host" "$@"
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

    local found_user="" found_host=""
    for h in "${open[@]}"; do
        for u in "${uuniq[@]}"; do
            log_info "Trying $u@$h (key auth)..."
            if _fleet_ssh_ok "$u" "$h" "$port"; then
                found_user="$u"; found_host="$h"; break 2
            fi
        done
    done
    if [[ -z "$found_user" ]]; then
        # Offer one interactive attempt (e.g. a personal account not in the
        # candidate list). Non-interactive callers use --user.
        if [[ -t 0 ]]; then
            local asked
            read -rp "$(show_status 'question') No key login worked. Try another user: " asked || asked=""
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
        log_error "Port $port is open, but no key-based login worked for: ${uuniq[*]}"
        log_info "Set up a key first: ssh-copy-id USER@${open[0]}"
        log_info "Then retry, or pass --user USER --host HOST."
        return 1
    fi

    local sudo_prefix=""
    if [[ "$found_user" != "root" ]]; then
        if ! _fleet_ssh "$found_user" "$found_host" "$port" "sudo -n true" >/dev/null 2>&1; then
            log_error "$found_user@$found_host requires a password for sudo."
            log_info "Unattended changes need passwordless sudo (sudoers) or root login."
            return 1
        fi
        sudo_prefix="sudo -n"
    fi

    FLEET_HOST="$found_host"
    FLEET_USER="$found_user"
    FLEET_PORT="$port"
    FLEET_SUDO="$sudo_prefix"
    log_success "Using $FLEET_USER@$FLEET_HOST:$FLEET_PORT${FLEET_SUDO:+ (passwordless sudo)}"
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
  --config FILE          push this complete config.yml instead of merging
  --remote-config PATH   Remote config path (default: /etc/nebula/config.yml)

Connection / safety:
  --host HOST            Extra candidate (repeatable)
  --domain DOMAIN        Also try <target>.DOMAIN (repeatable)
  --user USER            Extra login candidate (repeatable)
  --port N               SSH port (default: 22)
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
    return $rc
}

_fleet_ssh_cli_body() {
    local target="" port=22 policy="" fw_mode="" fw_file="" config_file="" remote_cfg="/etc/nebula/config.yml"
    local service="nebula.service" assume_yes=0 dry=0 no_restart=0 cert_dir=""
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
            --remote-config) shift; remote_cfg="${1:-}" ;;
            --remote-config=*) remote_cfg="${1#*=}" ;;
            --service)       shift; service="${1:-}" ;;
            --service=*)     service="${1#*=}" ;;
            --cert-dir)      shift; cert_dir="${1:-}" ;;
            --cert-dir=*)    cert_dir="${1#*=}" ;;
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

    local pack_path="" fw_tmp=""

    if [[ -z "$config_file" && -z "$policy" && -z "$fw_mode" && -z "$fw_file" ]]; then
        log_error "Nothing to change: pass --policy PACK, --firewall MODE, --firewall-file FILE or --config FILE."
        return 2
    fi
    if [[ -n "$config_file" && ( -n "$policy" || -n "$fw_mode" || -n "$fw_file" ) ]]; then
        log_warn "--config replaces the whole file; ignoring the policy/firewall merge."
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

    local -a probe_args=(--port "$port")
    [[ -n "$cert_dir" ]] && probe_args+=(--cert-dir "$cert_dir")
    local h u d
    for h in "${extra_hosts[@]}"; do probe_args+=(--host "$h"); done
    for d in "${extra_domains[@]}"; do probe_args+=(--domain "$d"); done
    for u in "${extra_users[@]}"; do probe_args+=(--user "$u"); done
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
    if ! _fleet_ssh "$FLEET_USER" "$FLEET_HOST" "$FLEET_PORT" "${FLEET_SUDO:+$FLEET_SUDO }cat '$remote_cfg'" > "$oldcfg"; then
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

    log_info "Uploading the new config..."
    if ! _fleet_ssh "$FLEET_USER" "$FLEET_HOST" "$FLEET_PORT" "${FLEET_SUDO:+$FLEET_SUDO }tee '$remote_tmp' >/dev/null" < "$newcfg"; then
        log_error "Upload failed."
        return 1
    fi
    if ! _fleet_ssh "$FLEET_USER" "$FLEET_HOST" "$FLEET_PORT" "$apply_cmd"; then
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
    if [[ -n "$nebula_bin" ]] && _fleet_ssh "$FLEET_USER" "$FLEET_HOST" "$FLEET_PORT" "${FLEET_SUDO:+$FLEET_SUDO }'$nebula_bin' -test -config '$remote_cfg'" >/dev/null 2>&1; then
        log_success "nebula -test passed on $FLEET_HOST"
    else
        log_warn "Could not validate on $FLEET_HOST (nebula binary not found or test failed)."
    fi

    if (( no_restart )); then
        log_info "Service restart skipped (--no-restart)."
    elif _fleet_ssh "$FLEET_USER" "$FLEET_HOST" "$FLEET_PORT" "${FLEET_SUDO:+$FLEET_SUDO }systemctl restart '$service'"; then
        log_success "Restarted $service on $FLEET_HOST"
    else
        log_warn "Could not restart $service on $FLEET_HOST; run it manually."
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
  croc [options]      Render bundles and serve each with croc (recommended for
                      classes: no open ports). Prints one code per student.
  ssh TARGET [...]    Push a config/firewall change to one reachable node.
  probe TARGET [...]  Test SSH reachability and discover a login user.
  help                This help

Examples:
  nebula-manager fleet croc --select group:students --policy students
  nebula-manager fleet croc --select all --dry-run
  nebula-manager fleet probe node4
  nebula-manager fleet ssh node4 --policy home --yes
  nebula-manager fleet ssh node4 --config ./config.yml --dry-run
EOF
}

fleet_cli() {
    local sub="${1:-help}"; shift || true
    case "$sub" in
        croc|share)   fleet_croc_cli "$@" ;;
        ssh|push)     fleet_ssh_cli "$@" ;;
        probe)        fleet_probe_cli "$@" ;;
        -h|--help|help|"") fleet_usage ;;
        *) log_error "Unknown 'fleet' subcommand: $sub"; fleet_usage >&2; return 2 ;;
    esac
}

###################################################################
############################ TUI ##################################
###################################################################

fleet_croc_tui() {
    local cert_dir; cert_dir="$(resolve_cert_dir)"
    cert_select_tui "$cert_dir" || return 0
    (( ${#SEL_NAMES[@]} > 0 )) || return 0

    local -a policy_opts=( __saved__ "Use each node's saved firewall choice" )
    if declare -F policy_pairs >/dev/null && policy_pairs; then
        local i
        for (( i=0; i<${#POLICY_PAIRS[@]}; i+=2 )); do
            policy_opts+=( "pack:${POLICY_PAIRS[i]}" "Policy pack: ${POLICY_PAIRS[i+1]}" )
        done
    fi
    local pchoice
    pchoice="$(ui_menu "Fleet croc" "Firewall for these bundles:" "${policy_opts[@]}")" || return 0

    local default_out; default_out="$PWD/fleet-bundles-$(date +%Y%m%d-%H%M%S)"
    local out; out="$(ui_input "Fleet croc" "Output directory:" "$default_out")" || return 0
    [[ -z "$out" ]] && out="$default_out"

    local -a args=( --cert-dir "$cert_dir" --out "$out" )
    local n
    for n in "${SEL_NAMES[@]}"; do args+=( --select "cert:$n" ); done
    [[ "$pchoice" == __saved__ ]] || args+=( --firewall "$pchoice" )
    fleet_croc_cli "${args[@]}"
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
    popts+=( __file__ "Push a complete config.yml file" )
    local choice
    choice="$(ui_menu "Fleet SSH" "What should be applied on $target?" "${popts[@]}")" || return 0
    local -a args=( "$target" )
    case "$choice" in
        __none__) log_info "Canceled."; return 0 ;;
        __file__)
            local f; f="$(ui_input "Fleet SSH" "Local config.yml to push:")" || return 0
            [[ -z "$f" ]] && return 0
            args+=( --config "$f" ) ;;
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
        "$(get_icon 'upload')Share student bundles via croc"
        "$(get_icon 'connectivity')Push config/firewall over SSH"
        "$(get_icon 'scan')Probe SSH reachability"
    )
    # shellcheck disable=SC2034
    dynamic_menu_functions=( "fleet_croc_tui" "fleet_ssh_tui" "fleet_probe_tui" )
    dynamic_menu dynamic_menu_title dynamic_menu_options dynamic_menu_functions 1 "" \
        "Deploy to mesh nodes: croc mass-sharing for classes, or an explicit SSH config/firewall push."
}
