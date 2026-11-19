#!/usr/bin/env bash
# shellcheck shell=bash
#
# lib/relay.sh - Nebula relay settings (the top-level `relay:` block)
# ===================================================================
# A relay forwards the encrypted peer-to-peer traffic of nodes that cannot reach
# each other directly (both behind one NAT, CGNAT, no IPv6). The relay never
# decrypts anything, but it carries the traffic volume, so it is a fallback, not
# a default. See docs/relay.md.
#
# Two shapes, exactly as Nebula expects them:
#
#   # client / peer
#   relay:
#     am_relay: false
#     use_relays: true
#     relays:
#       - 10.100.0.1
#
#   # lighthouse
#   relay:
#     am_relay: true
#
# Per-node settings live in one TSV file (user config dir), so node configs and
# bundles are rendered from a single source of truth:
#   <cert> <TAB> <mode> <TAB> <relays csv>
# with mode = off | use | am | am+use.
# "off" keeps the row (explicit intent) but emits no block; a missing row means
# "never configured", which also emits no block - today's behaviour.

[[ -n "${NEBULA_MANAGER_RELAY_SOURCED:-}" ]] && return 0
NEBULA_MANAGER_RELAY_SOURCED=1

###################################################################
###################### per-node setting store #####################
###################################################################

node_relay_state_file() { printf '%s/node-relay.tsv' "$(dirname "$(policy_dir)")"; }

# node_relay_get <cert> ; prints "mode<TAB>relays" (no output when unset).
node_relay_get() {
    local key="${1:-}" f k mode relays
    [[ -n "$key" ]] || return 1
    f="$(node_relay_state_file)"
    [[ -f "$f" ]] || return 1
    while IFS=$'\t' read -r k mode relays; do
        [[ -z "$k" || "$k" == \#* ]] && continue
        [[ "$k" == "$key" ]] || continue
        printf '%s\t%s' "$mode" "${relays:-}"
        return 0
    done < "$f"
    return 1
}

# node_relay_set <cert> <mode> [relays csv] ; mode=off keeps an explicit "no relay".
node_relay_set() {
    local key="$1" mode="$2" relays="${3:-}" f tmp
    [[ -n "$key" && -n "$mode" ]] || return 2
    f="$(node_relay_state_file)"
    mkdir -p "$(dirname "$f")" || return 1
    tmp="$(mktemp)" || return 1
    if [[ -f "$f" ]]; then
        awk -v k="$key" 'BEGIN { FS=OFS="\t" } $1 != k { print }' "$f" > "$tmp"
    fi
    printf '%s\t%s\t%s\n' "$key" "$mode" "$relays" >> "$tmp"
    mv "$tmp" "$f"
}

###################################################################
########################### YAML shapes ###########################
###################################################################

# relay_onoff <true|false> ; the "on"/"off" spelling used in summaries.
relay_onoff() {
    case "${1:-false}" in
        true|True|on|yes|1) printf 'on' ;;
        *)                  printf 'off' ;;
    esac
}

# relay_render_lines <mode> [relays csv] ; the YAML block (nothing for off).
relay_render_lines() {
    local mode="${1:-off}" relays="${2:-}" ip
    case "$mode" in
        ""|off) return 0 ;;
        use|am|am+use) : ;;
        *) log_error "Invalid relay mode: $mode"; return 2 ;;
    esac
    printf 'relay:\n'
    case "$mode" in
        am)     printf '  am_relay: true\n' ;;
        am+use) printf '  am_relay: true\n  use_relays: true\n' ;;
        use)    printf '  am_relay: false\n  use_relays: true\n' ;;
    esac
    if [[ "$mode" == *use* && -n "$relays" ]]; then
        printf '  relays:\n'
        local IFS=','
        for ip in $relays; do
            ip="${ip//[[:space:]]/}"
            [[ -n "$ip" ]] && printf '    - %s\n' "$ip"
        done
    fi
    return 0
}

# _relay_csv_to_yq_list <relays csv> ; prints  "10.0.0.1", "10.0.0.2"
_relay_csv_to_yq_list() {
    local csv="${1:-}" ip list="" sep="" IFS=','
    for ip in $csv; do
        ip="${ip//[[:space:]]/}"
        [[ -n "$ip" ]] || continue
        list+="${sep}\"${ip}\""; sep=", "
    done
    printf '%s' "$list"
}

# relay_apply_to_config <config.yml> <mode> [relays csv]
# Idempotent rewrite of the top-level relay: block in an existing file (yq v4).
relay_apply_to_config() {
    local cfg="$1" mode="$2" relays="${3:-}"
    [[ -f "$cfg" ]] || { log_error "Config not found: $cfg"; return 1; }
    require_yq_v4 >/dev/null 2>&1 || { log_error "yq v4 is required to change relay settings."; return 1; }
    case "$mode" in
        ""|off)
            yq -i 'del(.relay)' "$cfg" || return 1 ;;
        am)
            yq -i '.relay.am_relay = true | del(.relay.use_relays) | del(.relay.relays)' "$cfg" || return 1 ;;
        use|am+use)
            local am="false"
            [[ "$mode" == "am+use" ]] && am="true"
            yq -i ".relay.am_relay = ${am} | .relay.use_relays = true | .relay.relays = [$( _relay_csv_to_yq_list "$relays" )]" "$cfg" || return 1 ;;
        *)
            log_error "Invalid relay mode: $mode"; return 2 ;;
    esac
    return 0
}

# relay_append_to_config <file> <cert> ; append the stored block to a new config.
# PKI_RELAY_OVERRIDE ("<mode>TAB<csv>") renders a *hypothetical* setting, which is
# how `cert relay --dry-run` produces exactly the diff a real run would write.
relay_append_to_config() {
    local file="$1" name="$2" saved mode relays
    [[ -f "$file" ]] || return 0
    if [[ -n "${PKI_RELAY_OVERRIDE+x}" ]]; then
        saved="$PKI_RELAY_OVERRIDE"
    else
        saved="$(node_relay_get "$name" 2>/dev/null || true)"
    fi
    [[ -n "$saved" ]] || return 0
    IFS=$'\t' read -r mode relays <<<"$saved"
    [[ -z "$mode" || "$mode" == "off" ]] && return 0
    { printf '\n'; relay_render_lines "$mode" "$relays"; } >> "$file"
    return 0
}

# relay_sync_config <file> <cert> ; force the stored setting into an existing file.
relay_sync_config() {
    local file="$1" name="$2" saved mode relays
    [[ -f "$file" ]] || return 0
    saved="$(node_relay_get "$name" 2>/dev/null || true)"
    [[ -n "$saved" ]] || return 0
    IFS=$'\t' read -r mode relays <<<"$saved"
    if [[ -z "$mode" || "$mode" == "off" ]]; then
        relay_apply_to_config "$file" off || log_warn "Could not remove the relay block from $file."
        return 0
    fi
    relay_apply_to_config "$file" "$mode" "$relays" \
        || log_warn "Could not set the relay block in $file (yq v4 missing?); the file keeps its previous relay settings."
    return 0
}

###################################################################
##################### address validation ##########################
###################################################################

# relay_valid_ip <addr> ; IPv4/IPv6 literal (Nebula relays are IPs, not names).
relay_valid_ip() {
    local a="${1:-}" o
    if [[ "$a" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]]; then
        for o in "${BASH_REMATCH[@]:1}"; do
            (( 10#$o <= 255 )) || return 1
        done
        return 0
    fi
    [[ "$a" == *:* && "$a" =~ ^[0-9A-Fa-f:.]+$ ]]
}

# relay_normalize <addr> ; strip a /prefix and surrounding spaces.
relay_normalize() {
    local a="${1:-}"
    a="${a//[[:space:]]/}"
    a="${a%%/*}"
    printf '%s' "$a"
}

# relay_cert_index [cert_dir] ; "ip<TAB>name<TAB>crt" for every non-CA cert.
relay_cert_index() {
    local cert_dir="${1:-$(resolve_cert_dir)}" cert json name ip isca bin_path
    bin_path="$(dirname "$(pki_cert_bin)")" || return 1
    for cert in "$cert_dir"/*.crt; do
        [[ -f "$cert" ]] || continue
        json="$(nebula_cert_json "$bin_path" "$cert" 2>/dev/null)" || continue
        [[ -n "$json" ]] || continue
        isca="$(jq -r '.details.isCa // false' <<<"$json" 2>/dev/null)"
        [[ "$isca" == "true" ]] && continue
        name="$(jq -r '.details.name // empty' <<<"$json" 2>/dev/null)"
        while IFS= read -r ip; do
            [[ -n "$ip" ]] || continue
            printf '%s\t%s\t%s\n' "${ip%%/*}" "$name" "$cert"
        done < <(jq -r '(.details.ips // [])[]?' <<<"$json" 2>/dev/null)
    done
}

# _relay_index_for <addr> [cert_dir] ; "name<TAB>crt" for the cert carrying addr.
_relay_index_for() {
    local addr="$1" cert_dir="${2:-$(resolve_cert_dir)}" ip name crt
    while IFS=$'\t' read -r ip name crt; do
        [[ "$ip" == "$addr" ]] && { printf '%s\t%s' "$name" "$crt"; return 0; }
    done < <(relay_cert_index "$cert_dir")
    return 1
}

# relay_owner <addr> [cert_dir] ; the certificate name that carries the address.
relay_owner() {
    local hit
    hit="$(_relay_index_for "$1" "${2:-$(resolve_cert_dir)}")" || return 1
    printf '%s' "${hit%%$'\t'*}"
}

# relay_closest <addr> [cert_dir] ; up to three "  ip (name)" candidates.
relay_closest() {
    local addr="$1" cert_dir="${2:-$(resolve_cert_dir)}" prefix ip name _c n=0
    prefix="${addr%.*}."
    while IFS=$'\t' read -r ip name _c; do
        [[ "$ip" == "$prefix"* ]] || continue
        printf '  %s (%s)\n' "$ip" "$name"; n=$((n + 1))
        (( n >= 3 )) && return 0
    done < <(relay_cert_index "$cert_dir")
    (( n )) && return 0
    n=0
    while IFS=$'\t' read -r ip name _c; do
        printf '  %s (%s)\n' "$ip" "$name"; n=$((n + 1))
        (( n >= 3 )) && return 0
    done < <(relay_cert_index "$cert_dir")
    return 0
}

# relay_require_known <addr> <cert_dir> ; refuse an address that is not a cert.
relay_require_known() {
    local addr="$1" cert_dir="$2" owner closest
    owner="$(relay_owner "$addr" "$cert_dir" || true)"
    if [[ -n "$owner" ]]; then
        debug_info "relay $addr is $owner"
        return 0
    fi
    log_error "Relay $addr is not a certificate in $cert_dir."
    closest="$(relay_closest "$addr" "$cert_dir")"
    if [[ -n "$closest" ]]; then
        log_info "Closest matches in the workspace:"
        printf '%s\n' "$closest" >&2
    else
        log_info "The workspace has no certificates with an overlay IP yet."
    fi
    return 1
}

###################################################################
########################## inspection #############################
###################################################################

# relay_config_line <config_file> ; "am_relay: off, use_relays: on, relays: ..."
relay_config_line() {
    local cfg="$1" have am use relays
    if ! require_yq_v4 >/dev/null 2>&1; then
        printf '(yq v4 missing, cannot inspect)\n'
        return 0
    fi
    have="$(yq -r 'has("relay")' "$cfg" 2>/dev/null)"
    if [[ "$have" != "true" ]]; then
        printf 'none (no relay: block)\n'
        return 0
    fi
    am="$(relay_onoff "$(yq -r '.relay.am_relay // false' "$cfg" 2>/dev/null)")"
    use="$(yq -r 'if .relay.use_relays == null then "unset" else (.relay.use_relays | tostring) end' "$cfg" 2>/dev/null)"
    if [[ "$use" == "true" || "$use" == "false" ]]; then
        use="$(relay_onoff "$use")"
    elif [[ "$use" == "unset" ]]; then
        # Nebula defaults use_relays to true when the key is absent.
        use="unset (default: on)"
    fi
    relays="$(yq -r '(.relay.relays // []) | join(", ")' "$cfg" 2>/dev/null)"
    printf 'am_relay: %s, use_relays: %s' "$am" "$use"
    [[ -n "$relays" ]] && printf ', relays: %s' "$relays"
    printf '\n'
}

# relay_check_config <config_file> [cert_dir]
# Warns about relay addresses that are unknown to the workspace or expired.
relay_check_config() {
    local cfg="$1" cert_dir="${2:-$(resolve_cert_dir)}" ip hit name crt days
    [[ -f "$cfg" ]] || return 0
    require_yq_v4 >/dev/null 2>&1 || return 0
    while IFS= read -r ip; do
        [[ -n "$ip" ]] || continue
        hit="$(_relay_index_for "$ip" "$cert_dir" || true)"
        if [[ -z "$hit" ]]; then
            log_warn "Relay $ip is not a certificate in $cert_dir - is the address a typo?"
            local closest; closest="$(relay_closest "$ip" "$cert_dir")"
            [[ -n "$closest" ]] && printf '%s\n' "$closest" >&2
            continue
        fi
        IFS=$'\t' read -r name crt <<<"$hit"
        days="$(pki_cert_days_left "$crt" 2>/dev/null || true)"
        if [[ "$days" =~ ^-?[0-9]+$ ]] && (( days < 0 )); then
            log_warn "Relay $ip ($name) has an expired certificate (${days#-} day(s) ago)."
        elif [[ "$days" =~ ^[0-9]+$ ]] && (( days <= 30 )); then
            log_warn "Relay $ip ($name) expires in $days day(s)."
        fi
    done < <(yq -r '(.relay.relays // [])[]?' "$cfg" 2>/dev/null)
    return 0
}

# relay_show_cert <name> ; one line describing the stored per-node setting.
relay_show_cert() {
    local name="$1" saved mode relays
    saved="$(node_relay_get "$name" 2>/dev/null || true)"
    if [[ -z "$saved" ]]; then
        printf 'not set (no relay: block)'
        return 0
    fi
    IFS=$'\t' read -r mode relays <<<"$saved"
    case "$mode" in
        off)    printf 'off (no relay: block)' ;;
        am)     printf 'am_relay: on' ;;
        am+use) printf 'am_relay: on, use_relays: on, relays: %s' "${relays//,/, }" ;;
        use)    printf 'am_relay: off, use_relays: on, relays: %s' "${relays//,/, }" ;;
        *)      printf 'unknown mode %s' "$mode" ;;
    esac
}

###################################################################
###################### batch: cert relay ##########################
###################################################################

relay_cert_usage() {
    cat >&2 <<'EOF'
Usage: nebula-manager cert relay <change> [--select SPEC]... [--exclude SPEC]...

Write the Nebula `relay:` block into the stored per-node configs (<name>.yml).
Without a setting there is no block; the setting is remembered for bundles and
re-signs, so a later `cert bundle` carries it automatically.

Change (pick one):
  --relay IP[,IP]      peers use these relay(s): am_relay false, use_relays true
  --am-relay           this certificate is a relay: am_relay true
  --no-relay           remove the relay block again
  --show               print the current setting per selected certificate

Selection (default: all certificates):
  --select SPEC        group:G, without:G, name:GLOB, ip:CIDR, cert:NAME, all
  --exclude SPEC       subtract from the selection

Options:
  --cert-dir DIR       Certificate workspace
  --rebundle[=DIR]     refresh each changed bundle (default: ./fleet-bundles-<ts>)
  --dry-run, -n        print the exact diffs; write nothing
  --yes, -y            do not ask (required when stdin is not a TTY)

Examples:
  nebula-manager cert relay --select group:students --relay 10.100.0.1
  nebula-manager cert relay --select name:router* --no-relay
  nebula-manager cert relay --select all --show
  nebula-manager cert relay --relay 10.100.0.1 --rebundle
EOF
}

# _relay_render_with <name> <cert_dir> <policy> <out> <mode> <csv>
# Render a node config with the *requested* relay block (preview path).
_relay_render_with() {
    local name="$1" cert_dir="$2" policy="$3" out="$4" mode="$5" csv="$6"
    PKI_RELAY_OVERRIDE="${mode}"$'\t'"${csv}" \
        pki_write_client_config "$out" "$name" "$cert_dir" "$policy" "$name.yml"
}

# relay_batch_preview <name> <cert_dir> <mode> <csv> ; exact diff, writes nothing.
relay_batch_preview() {
    local name="$1" cert_dir="$2" mode="$3" csv="$4"
    local path policy="" tmpdir old new
    path="$(pki_node_config_find "$name" "$cert_dir")"
    pki_node_config_policy "$name"
    policy="$PKI_NODE_CONFIG_POLICY"
    tmpdir="$(mktemp -d)" || return 1
    old="$tmpdir/old.yml"; new="$tmpdir/new.yml"
    if [[ -s "$path" ]]; then
        cp "$path" "$old"
    else
        printf '# (no node config yet - it would be created)\n' > "$old"
    fi
    if ! _relay_render_with "$name" "$cert_dir" "$policy" "$new" "$mode" "$csv"; then
        log_error "Could not render the config for $name"
    elif diff -u "$old" "$new" > "$tmpdir/d" 2>/dev/null; then
        printf '  %-34s (no change)\n' "$name"
    else
        printf '  %s\n' "$name"
        sed 's/^/    /' "$tmpdir/d"
    fi
    [[ "$PKI_NODE_CONFIG_TMP" == 1 && -n "$policy" ]] && rm -f "$policy"
    rm -rf "$tmpdir"
    return 0
}

# relay_rebundle <cert_dir> <out_dir> <name...> ; refresh bundles for the names.
relay_rebundle() {
    local cert_dir="$1" out="$2"; shift 2
    local name policy tmp rc=0 bundle
    ensure_dir "$out" || return 1
    for name in "$@"; do
        pki_node_config_policy "$name"
        policy="$PKI_NODE_CONFIG_POLICY"; tmp=""
        [[ "$PKI_NODE_CONFIG_TMP" == 1 ]] && tmp="$policy"
        bundle="$(pki_bundle_client_zip "$name" "$out" "$cert_dir" "$policy" "" "" 2>/dev/null | tail -n1)"
        if [[ -n "$bundle" && -f "$bundle" ]]; then
            log_success "Bundle refreshed: $bundle"
        else
            log_error "Could not refresh the bundle for $name"
            rc=1
        fi
        [[ -n "$tmp" ]] && rm -f "$tmp"
    done
    return $rc
}

# relay_batch_cli ; `nebula-manager cert relay ...`
relay_batch_cli() {
    local cert_dir="" action="" relay_csv="" rebundle=0 rebundle_dir=""
    local dry=0 yes=0 show=0
    local -a selects=() excludes=()
    while (( $# )); do
        case "$1" in
            --cert-dir)     shift; cert_dir="${1:-}" ;;
            --cert-dir=*)   cert_dir="${1#*=}" ;;
            --select)       shift; selects+=("${1:-}") ;;
            --select=*)     selects+=("${1#*=}") ;;
            --exclude)      shift; excludes+=("${1:-}") ;;
            --exclude=*)    excludes+=("${1#*=}") ;;
            --relay)        shift; relay_csv="${1:-}" ;;
            --relay=*)      relay_csv="${1#*=}" ;;
            --am-relay)     action="am" ;;
            --am-relay=*)   case "${1#*=}" in
                                on|true|yes|1)  action="am" ;;
                                off|false|no|0) action="off" ;;
                                *) log_error "--am-relay takes on or off."; return 2 ;;
                            esac ;;
            --no-relay|--off) action="off" ;;
            --show)         show=1 ;;
            --rebundle)     rebundle=1 ;;
            --rebundle=*)   rebundle=1; rebundle_dir="${1#*=}" ;;
            --dry-run|-n)   dry=1 ;;
            --yes|-y)       yes=1 ;;
            -h|--help)      relay_cert_usage; return 0 ;;
            -*) log_error "Unknown option for 'cert relay': $1"; relay_cert_usage; return 2 ;;
            *)  log_error "Unexpected argument for 'cert relay': $1"; relay_cert_usage; return 2 ;;
        esac
        shift
    done
    cert_dir="${cert_dir:-$(resolve_cert_dir)}"

    local -a selargs=()
    local s
    for s in "${selects[@]}"; do selargs+=(--select "$s"); done
    for s in "${excludes[@]}"; do selargs+=(--exclude "$s"); done

    # --- --show -------------------------------------------------------------
    if (( show )); then
        cert_select "$cert_dir" "${selargs[@]}" || { log_warn "No certificate matched the selection in $cert_dir."; return 1; }
        printf '\nRelay settings for %d selected certificate(s) in %s:\n' "${#SEL_NAMES[@]}" "$cert_dir"
        local i name
        for i in "${!SEL_NAMES[@]}"; do
            name="${SEL_NAMES[i]}"
            [[ -n "$name" ]] || continue
            local state
            if [[ -f "$cert_dir/$name.key" ]]; then
                state="$(relay_show_cert "$name")"
            else
                state="n/a (no local key: mobile/device certificate)"
            fi
            printf '  %-34s %-18s [%s]  %s\n' "$name" "${SEL_IPS[i]:-N/A}" \
                "${SEL_GROUPS[i]//,/:}" "$state"
        done
        return 0
    fi

    # --- resolve the requested change --------------------------------------
    local mode=""
    local count=0
    [[ -n "$relay_csv" ]] && count=$((count + 1))
    [[ -n "$action" ]] && count=$((count + 1))
    if (( count != 1 )); then
        log_error "Choose exactly one of --relay, --am-relay or --no-relay (see --help)."
        return 2
    fi

    local -a relay_list=()
    local ip norm csv=""
    if [[ -n "$relay_csv" ]]; then
        local -a raw=()
        IFS=',' read -ra raw <<<"$relay_csv"
        for ip in "${raw[@]}"; do
            norm="$(relay_normalize "$ip")"
            [[ -n "$norm" ]] || continue
            if ! relay_valid_ip "$norm"; then
                log_error "Not an IP address: '$norm' (Nebula relays are addresses, not host names)."
                return 2
            fi
            relay_list+=("$norm")
        done
        if (( ${#relay_list[@]} == 0 )); then
            log_error "--relay needs at least one address (e.g. --relay 10.100.0.1)."
            return 2
        fi
        for ip in "${relay_list[@]}"; do
            relay_require_known "$ip" "$cert_dir" || return 1
        done
        csv="$(printf '%s,' "${relay_list[@]}")"
        csv="${csv%,}"
        mode="use"
    elif [[ "$action" == "am" ]]; then
        mode="am"
    else
        mode="off"
    fi

    if ! cert_select "$cert_dir" "${selargs[@]}"; then
        log_warn "No certificate matched the selection in $cert_dir."
        return 1
    fi

    local desc
    case "$mode" in
        off) desc="no relay block" ;;
        am)  desc="am_relay: true (relay for peers)" ;;
        use) desc="use_relays: true, relays: ${csv//,/, }" ;;
    esac

    printf '\nRelay for %d selected certificate(s) in %s:\n' "${#SEL_NAMES[@]}" "$cert_dir"
    printf '  Change: %s\n\n' "$desc"

    local changed=0 failed=0 skipped=0
    local -a changed_names=() pending=()
    local i name
    for i in "${!SEL_NAMES[@]}"; do
        name="${SEL_NAMES[i]}"
        [[ -n "$name" ]] || continue
        if [[ ! -f "$cert_dir/$name.key" ]]; then
            log_info "Skipping $name: no local private key (no node config)."
            skipped=$((skipped + 1))
            continue
        fi
        if (( dry )); then
            relay_batch_preview "$name" "$cert_dir" "$mode" "$csv"
        else
            pending+=("$name")
        fi
    done

    if (( dry )); then
        log_info "Dry run: no config was changed."
        return 0
    fi
    if (( ${#pending[@]} == 0 )); then
        log_warn "Nothing to change."
        return 0
    fi
    if (( ! yes )); then
        if [[ ! -t 0 ]]; then
            log_error "Refusing to change relay settings without --yes on a non-interactive shell."
            return 2
        fi
        local ans=""
        read -rp "$(show_status 'question') Apply this relay setting? [y/N]: " ans || return 1
        [[ "$ans" =~ ^[Yy]$ ]] || { log_info "Canceled."; return 0; }
    fi

    for name in "${pending[@]}"; do
        node_relay_set "$name" "$mode" "$csv" 2>/dev/null || true
        if pki_node_config_write_for_fw "$name" "$cert_dir" 1 >/dev/null; then
            log_success "Relay for $name: $desc"
            changed=$((changed + 1))
            changed_names+=("$name")
        else
            log_error "Could not update the config for $name"
            failed=$((failed + 1))
        fi
    done
    if (( skipped )); then
        log_info "Skipped $skipped certificate(s) without a local key."
    fi
    log_info "Relay updated for $changed certificate(s); $failed failed."

    if (( rebundle )) && (( ${#changed_names[@]} > 0 )); then
        local out="${rebundle_dir:-$PWD/fleet-bundles-$(date +%Y%m%d-%H%M%S)}"
        relay_rebundle "$cert_dir" "$out" "${changed_names[@]}" || failed=$((failed + 1))
    fi
    (( failed == 0 ))
}

# TUI: pick certificates, then a relay change.
relay_batch_tui() {
    local cert_dir; cert_dir="$(resolve_cert_dir)"
    ensure_cert_dir >/dev/null || return 1
    cert_select_tui "$cert_dir" || return 0
    (( ${#SEL_NAMES[@]} )) || return 0

    local choice
    choice="$(ui_menu "Relay for nodes" \
        "Apply to ${#SEL_NAMES[@]} selected certificate(s). A relay forwards traffic that cannot go peer-to-peer." \
        use "Peers use a relay (use_relays: true)" \
        am "This node is a relay too (am_relay: true)" \
        off "No relay block" \
        show "Show the current setting per certificate")" || return 0
    [[ -n "$choice" ]] || return 0

    local -a args=( --cert-dir "$cert_dir" )
    local n
    for n in "${SEL_NAMES[@]}"; do args+=( --select "cert:$n" ); done
    case "$choice" in
        show) args+=( --show ) ;;
        off)  args+=( --no-relay ) ;;
        am)   args+=( --am-relay ) ;;
        use)
            local addr
            addr="$(ui_input "Relay for nodes" "Relay overlay IP (must be a certificate here):")" || return 0
            [[ -n "$addr" ]] || return 0
            args+=( --relay "$addr" )
            local rb
            rb="$(ui_menu "Relay for nodes" "Refresh the bundles too?" \
                no "Only the stored configs" \
                yes "Also refresh each bundle")" || return 0
            [[ "$rb" == "yes" ]] && args+=( --rebundle )
            ;;
    esac
    relay_batch_cli "${args[@]}"
}

###################################################################
################# this host: relay local (lighthouse) #############
###################################################################

relay_local_usage() {
    cat >&2 <<'EOF'
Usage: nebula-manager relay local [--show]
       nebula-manager relay local --am-relay on|off [options]

Show or change the relay settings in this host's Nebula config
(/etc/nebula/config.yml). A relay forwards traffic between peers that cannot
reach each other directly; it never decrypts anything.

  --show               print the current relay state and stop
  --am-relay on|off    make this host a relay for peers (refused unless
                       lighthouse.am_lighthouse is true) or stop being one
  --relay IP[,IP]      peers use these relay(s): use_relays true + the list
  --use-relays on|off  turn use_relays on/off (off also drops the relay list)

Options:
  --nebula-config FILE Nebula config to edit (default: /etc/nebula/config.yml)
  --service NAME       Service to restart (default: nebula.service)
  --no-restart         validate but do not restart
  --dry-run, -n        print the diff; change nothing

A timestamped backup (<config>.bak.<timestamp>) is written before the change; if
`nebula -test` rejects the result, the backup is restored automatically.
EOF
}

# relay_local_cli ; `nebula-manager relay local [options]`
relay_local_cli() {
    local cfg="${NEBULA_DIR:-/etc/nebula}/config.yml" svc="${NEBULA_SERVICE:-nebula.service}"
    local am="" use="" relay_csv="" show=0 dry=0 restart=1
    while (( $# )); do
        case "$1" in
            --show)          show=1 ;;
            --am-relay)      shift; am="${1:-}" ;;
            --am-relay=*)    am="${1#*=}" ;;
            --use-relays)    shift; use="${1:-}" ;;
            --use-relays=*)  use="${1#*=}" ;;
            --relay)         shift; relay_csv="${1:-}" ;;
            --relay=*)       relay_csv="${1#*=}" ;;
            --config)        shift; cfg="${1:-}" ;;
            --config=*)      cfg="${1#*=}" ;;
            --nebula-config)   shift; cfg="${1:-}" ;;
            --nebula-config=*) cfg="${1#*=}" ;;
            --service)       shift; svc="${1:-}" ;;
            --service=*)     svc="${1#*=}" ;;
            --no-restart)    restart=0 ;;
            --dry-run|-n)    dry=1 ;;
            -h|--help)       relay_local_usage; return 0 ;;
            *) log_error "Unknown option for 'relay local': $1"; relay_local_usage; return 2 ;;
        esac
        shift
    done
    [[ "$svc" =~ ^[A-Za-z0-9@._-]+$ ]] || { log_error "Invalid service name: $svc"; return 2; }

    local r
    r="$(readable_nebula_config "$cfg")" || r=""
    if [[ -z "$r" ]]; then
        log_error "Cannot read the Nebula config at $cfg (permission denied)."
        log_info "Approve the temporary sudo read when prompted, or pass --nebula-config with a readable copy."
        return 1
    fi
    if ! require_yq_v4; then
        [[ "$r" != "$cfg" ]] && rm -f "$r"
        return 1
    fi

    if (( show )) || [[ -z "$am" && -z "$use" && -z "$relay_csv" ]]; then
        printf 'Relay on this host (%s):\n' "$cfg"
        printf '  %s\n' "$(relay_config_line "$r")"
        printf '  lighthouse: am_lighthouse: %s\n' "$(yq -r '.lighthouse.am_lighthouse // false' "$r")"
        relay_check_config "$r" || true
        [[ "$r" != "$cfg" ]] && rm -f "$r"
        return 0
    fi

    # Refuse am_relay on a host that is not a lighthouse. Nebula allows a relay
    # on any node, but a relay has to be as reachable as a lighthouse (public
    # address, inbound UDP) and every peer must list it in relay.relays; the
    # class topology uses the lighthouse, so a silent enable here would only
    # produce a relay nobody can reach.
    if [[ -n "$am" ]]; then
        case "$am" in
            on|true|yes|1)
                if [[ "$(yq -r '.lighthouse.am_lighthouse // false' "$r")" != "true" ]]; then
                    log_error "Refusing to enable am_relay: this host is not a lighthouse."
                    log_info "A relay must be as reachable as a lighthouse (public address, inbound UDP) and every peer has to list it in relay.relays."
                    log_info "lighthouse.am_lighthouse is false in $cfg. Enable the relay on the lighthouse, or set relay.am_relay by hand if this host really is reachable that way."
                    [[ "$r" != "$cfg" ]] && rm -f "$r"
                    return 1
                fi
                am="on" ;;
            off|false|no|0) am="off" ;;
            *) log_error "--am-relay takes on or off."
               [[ "$r" != "$cfg" ]] && rm -f "$r"; return 2 ;;
        esac
    fi
    if [[ -n "$use" ]]; then
        case "$use" in
            on|true|yes|1)  use="on" ;;
            off|false|no|0) use="off" ;;
            *) log_error "--use-relays takes on or off."
               [[ "$r" != "$cfg" ]] && rm -f "$r"; return 2 ;;
        esac
    fi

    local work; work="$(mktemp)" || { [[ "$r" != "$cfg" ]] && rm -f "$r"; return 1; }
    if ! cp "$r" "$work"; then
        rm -f "$work"; [[ "$r" != "$cfg" ]] && rm -f "$r"; return 1
    fi
    [[ "$r" != "$cfg" ]] && rm -f "$r"

    if [[ -n "$relay_csv" ]]; then
        local norm
        local -a raw=() clean=()
        IFS=',' read -ra raw <<<"$relay_csv"
        for norm in "${raw[@]}"; do
            norm="$(relay_normalize "$norm")"
            [[ -n "$norm" ]] || continue
            if ! relay_valid_ip "$norm"; then
                log_error "Not an IP address: '$norm'"
                rm -f "$work"; return 2
            fi
            clean+=("$norm")
        done
        if (( ${#clean[@]} == 0 )); then
            log_error "--relay needs at least one address."
            rm -f "$work"; return 2
        fi
        local csv; csv="$(printf '%s,' "${clean[@]}")"; csv="${csv%,}"
        yq -i ".relay.use_relays = true | .relay.relays = [$( _relay_csv_to_yq_list "$csv" )]" "$work" \
            || { log_error "Could not edit the working copy"; rm -f "$work"; return 1; }
    fi
    if [[ -n "$am" ]]; then
        if [[ "$am" == "on" ]]; then
            yq -i '.relay.am_relay = true' "$work"
        else
            yq -i '.relay.am_relay = false' "$work"
        fi
    fi
    if [[ -n "$use" ]]; then
        if [[ "$use" == "on" ]]; then
            yq -i '.relay.use_relays = true' "$work"
        else
            yq -i '.relay.use_relays = false | del(.relay.relays)' "$work"
        fi
    fi

    local diffout
    diffout="$(diff -u "$cfg" "$work" 2>/dev/null || true)"
    if [[ -z "$diffout" ]]; then
        log_info "No changes needed: $cfg already matches."
        rm -f "$work"
        return 0
    fi
    printf '%s\n' "$diffout"
    if (( dry )); then
        log_info "Dry run: $cfg was not changed."
        rm -f "$work"
        return 0
    fi

    local bak
    bak="$cfg.bak.$(date +%Y%m%d-%H%M%S)"
    if path_requires_root "$cfg"; then
        if ! elevate_why "back up the Nebula config before changing relay settings" cp -p "$cfg" "$bak"; then
            log_error "Could not back up $cfg; nothing was changed."
            rm -f "$work"
            return 1
        fi
        if ! elevate_why "write the new relay settings to $cfg" cp "$work" "$cfg"; then
            log_error "Could not write $cfg (backup: $bak)."
            rm -f "$work"
            return 1
        fi
    else
        if ! cp -p "$cfg" "$bak"; then
            log_error "Could not back up $cfg; nothing was changed."
            rm -f "$work"
            return 1
        fi
        if ! cp "$work" "$cfg"; then
            log_error "Could not write $cfg (backup: $bak)."
            rm -f "$work"
            return 1
        fi
    fi
    rm -f "$work"
    _nebula_info_derive "$cfg" "$cfg" >/dev/null 2>&1 || true
    log_success "Updated relay settings in $cfg (backup: $bak)"

    if ! check_nebula_config "$cfg" error; then
        log_error "nebula -test rejected the new config - restoring $bak."
        local restored=0
        if path_requires_root "$cfg"; then
            elevate_why "restore the previous Nebula config" cp -p "$bak" "$cfg" && restored=1
        else
            cp -p "$bak" "$cfg" && restored=1
        fi
        if (( restored )); then
            log_info "Restored the previous config; nothing else changed."
        else
            log_error "Could not restore $bak automatically - do it by hand before restarting the service."
        fi
        return 1
    fi

    if (( ! restart )); then
        log_info "Service restart skipped (--no-restart)."
        return 0
    fi
    if elevate_why "restart the Nebula service ($svc)" systemctl restart "$svc"; then
        log_success "Restarted $svc"
    else
        log_warn "Could not restart $svc; run it manually."
    fi
    return 0
}

relay_local_tui() {
    local cfg="${NEBULA_DIR:-/etc/nebula}/config.yml"
    local choice
    choice="$(ui_menu "Local relay" \
        "Nebula relay settings for this host ($cfg). A relay forwards traffic that cannot go peer-to-peer." \
        show "Show the current relay state" \
        on "Make this host a relay (am_relay on; needs a lighthouse)" \
        off "Stop being a relay (am_relay off)")" || return 0
    case "$choice" in
        show) relay_local_cli --show ;;
        on)   relay_local_cli --am-relay on ;;
        off)  relay_local_cli --am-relay off ;;
    esac
}

###################################################################
########################## dispatch ###############################
###################################################################

relay_usage() {
    cat >&2 <<'EOF'
Usage: nebula-manager relay <command> [options]

Commands:
  local    Show or change the relay settings in this host's config.yml
           (--am-relay on|off, --relay IP, --show).

Per-node relay settings (client configs, bundles) live under:
  nebula-manager cert relay --select ... --relay IP
EOF
}

relay_cli() {
    local sub="${1:-local}"; shift || true
    case "$sub" in
        local|this-host|host) relay_local_cli "$@" ;;
        -h|--help|help)       relay_usage ;;
        *) log_error "Unknown 'relay' subcommand: $sub (expected: local)"; relay_usage; return 2 ;;
    esac
}
