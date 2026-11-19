#!/usr/bin/env bash
# shellcheck shell=bash
#
# lib/policy.sh - named firewall policy packs
# ===========================================
# A policy pack is a user-owned YAML file under
#   ${XDG_CONFIG_HOME:-~/.config}/nebula-manager/policies/<name>.yml
# with optional targeting metadata and a `firewall:` fragment:
#
#   name: home
#   description: Home machines
#   groups: [home]          # used to suggest the pack for matching certs
#   firewall:
#     inbound_action: drop
#     inbound:
#       - port: any
#         proto: any
#         groups: [home]
#     outbound:
#       - port: any
#         proto: any
#         host: any
#
# Packs are embedded into generated client `config.yml` files and can
# be exported per host for an existing fleet. Nothing here needs root; applying
# a pack to the local /etc/nebula config uses the usual working-copy/elevation
# helpers.

policy_dir() {
    printf '%s' "${XDG_CONFIG_HOME:-$HOME/.config}/nebula-manager/policies"
}

policy_name_valid() {
    [[ -n "$1" && "$1" =~ ^[A-Za-z0-9._-]+$ ]]
}

# policy_path <name> ; prints the managed path (validates the name).
policy_path() {
    local name="${1:-}"
    policy_name_valid "$name" || {
        log_error "Invalid policy name: '$name' (letters, digits, '.', '_' and '-' only)"
        return 2
    }
    printf '%s/%s.yml' "$(policy_dir)" "$name"
}

# policy_resolve <name|path> ; prints an existing pack path.
policy_resolve() {
    local ref="${1:-}" p
    if [[ -f "$ref" ]]; then printf '%s\n' "$ref"; return 0; fi
    p="$(policy_path "$ref")" || return 2
    if [[ -f "$p" ]]; then printf '%s\n' "$p"; return 0; fi
    log_error "Policy pack not found: $ref"
    log_info "Looked at $p (create one with: nebula-manager policy new $ref)"
    return 1
}

policy_ensure_dir() {
    local d; d="$(policy_dir)"
    mkdir -p "$d" 2>/dev/null || { log_error "Cannot create policy directory: $d"; return 1; }
    [[ -d "$d" ]]
}

# policy_validate <file> ; structural checks (firewall map, rule lists).
policy_validate() {
    local file="${1:-}" json
    [[ -f "$file" ]] || { log_error "Policy file not found: $file"; return 1; }
    json="$(yq -o=json '.firewall' "$file" 2>/dev/null)" || {
        log_error "Cannot parse $file (yq failed)."; return 1; }
    if [[ -z "$json" || "$json" == "null" ]]; then
        log_error "$file has no 'firewall:' section."
        return 1
    fi
    if ! jq -e 'type == "object"' <<<"$json" >/dev/null 2>&1; then
        log_error "$file: 'firewall' must be a mapping."
        return 1
    fi
    if ! jq -e '(.inbound  // []) | type == "array"' <<<"$json" >/dev/null 2>&1; then
        log_error "$file: 'firewall.inbound' must be a list."
        return 1
    fi
    if ! jq -e '(.outbound // []) | type == "array"' <<<"$json" >/dev/null 2>&1; then
        log_error "$file: 'firewall.outbound' must be a list."
        return 1
    fi
    # Nebula rejects anything but 'drop'/'reject' (and logs a warning, then
    # silently defaults to drop), so catch it before it ships.
    local act
    for act in inbound_action outbound_action; do
        if ! jq -e --arg k "$act" '(.[$k] // "drop") as $v | ($v == "drop" or $v == "reject")' \
            <<<"$json" >/dev/null 2>&1; then
            log_error "$file: firewall.$act must be 'drop' or 'reject' (got: $(jq -r --arg k "$act" '.[$k] // "-"' <<<"$json"))."
            return 1
        fi
    done
    return 0
}

_policy_rule_count() {
    yq -r '((.firewall.inbound // []) | length) + ((.firewall.outbound // []) | length)' "$1" 2>/dev/null
}

# policy_summary <pack-or-config> ; one line describing what the firewall allows.
#   inbound: group home any, icmp · outbound: any
policy_summary() {
    local f="${1:-}" json
    [[ -f "$f" ]] || return 1
    json="$(yq -o=json '.firewall // {}' "$f" 2>/dev/null)" || return 1
    [[ -n "$json" && "$json" != "null" ]] || return 1
    jq -r '
      def tgt:
        if .group then "group " + (.group | tostring)
        elif .groups then "groups " + (.groups | join("+"))
        elif .host then (if ((.host | tostring) == "any") then "any" else "host " + (.host | tostring) end)
        elif .cidr then "cidr " + (.cidr | tostring)
        else "any" end;
      def svc:
        [ (if ((.proto // "any") | tostring) != "any" then (.proto | tostring) else empty end),
          (if ((.port  // "any") | tostring) != "any" then "port " + (.port | tostring) else empty end) ]
        | join(" ");
      def one: (tgt) as $t | (svc) as $s |
        if $t == "any" then (if $s == "" then "any" else $s + " from any" end)
        elif $s == "" then $t
        else $t + " " + $s end;
      def dir($k): ((.[$k] // []) | if length == 0 then "none" else map(one) | join(", ") end);
      "inbound: " + dir("inbound") + " · outbound: " + dir("outbound")
    ' <<<"$json" 2>/dev/null
}

# policy_summary_short <pack-or-config> ; compact form for menu labels.
#   in: group home, icmp · out: any
policy_summary_short() {
    local s
    s="$(policy_summary "${1:-}")" || return 1
    s="${s//inbound: /in: }"
    s="${s// · outbound: / · out: }"
    printf '%s' "$s"
}

# policy_list ; one line per pack: name, suggested groups, what it allows.
policy_list() {
    local d; d="$(policy_dir)"
    local -a lines=()
    local f name groups gdisp summary
    if [[ -d "$d" ]]; then
        for f in "$d"/*.yml; do
            [[ -f "$f" ]] || continue
            name="$(yq -r '.name // ""' "$f" 2>/dev/null)"
            [[ -n "$name" ]] || name="$(basename "$f" .yml)"
            groups="$(yq -r '.groups // [] | join(",")' "$f" 2>/dev/null)"
            gdisp="${groups//,/:}"
            summary="$(policy_summary "$f" 2>/dev/null)" || summary="(cannot read)"
            lines+=("$(printf '  %-18s %-16s %s' "$name" "${gdisp:--}" "$summary")")
        done
    fi
    if (( ${#lines[@]} )); then
        printf 'Policy packs in %s\n' "$d"
        printf '%s\n' "${lines[@]}" | sort
        printf '\nWhat a pack does in detail: nebula-manager policy explain <name>\n'
    else
        printf 'No policy packs in %s\n' "$d"
        printf 'Create one from a config: nebula-manager policy new <name> --from-config FILE\n'
    fi
}

# policy_explain_cli ; explain a pack, a built-in mode, or a group policy.
#   policy explain home
#   policy explain --mode default|permissive
#   policy explain --group lab01,instructor [--no-icmp]
policy_explain_cli() {
    local ref="" mode="" groups="" icmp=1 file="" tmp=""
    while (( $# )); do
        case "$1" in
            --mode)       shift; mode="${1:-}" ;;
            --mode=*)     mode="${1#*=}" ;;
            --group|--from-group) shift; groups="${1:-}" ;;
            --group=*|--from-group=*) groups="${1#*=}" ;;
            --no-icmp)    icmp=0 ;;
            -h|--help)
                cat >&2 <<'EOF'
Usage: nebula-manager policy explain <pack>
       nebula-manager policy explain --mode default|permissive
       nebula-manager policy explain --group G1[,G2] [--no-icmp]

Print what a firewall choice actually allows (inbound/outbound rules and the
unmatched-traffic action), so a pack can be reviewed before it is deployed.
EOF
                return 0 ;;
            -*) log_error "Unknown option for 'policy explain': $1"; return 2 ;;
            *)  ref="${ref:-$1}" ;;
        esac
        shift
    done

    if [[ -n "$groups" ]]; then
        tmp="$(node_fw_render_group_policy "$groups" "$icmp")" || return 1
        file="$tmp"
        if (( icmp )); then
            printf 'Group policy for %s (+ ICMP for diagnostics)\n' "$groups"
        else
            printf 'Group policy for %s (no ICMP)\n' "$groups"
        fi
    elif [[ -n "$mode" ]]; then
        case "$mode" in
            permissive|default) tmp="$(node_fw_render_policy "$mode")" || return 1; file="$tmp" ;;
            *) log_error "--mode takes permissive or default."; return 2 ;;
        esac
        printf 'Built-in mode: %s\n' "$mode"
    elif [[ -n "$ref" ]]; then
        file="$(policy_resolve "$ref")" || return 1
        printf 'Policy pack: %s\n  file: %s\n' "$(basename "$file" .yml)" "$file"
        local g d
        g="$(yq -r '.groups // [] | join(", ")' "$file" 2>/dev/null)"
        d="$(yq -r '.description // ""' "$file" 2>/dev/null)"
        [[ -n "$g" ]] && printf '  suggested groups: %s\n' "$g"
        [[ -n "$d" ]] && printf '  %s\n' "$d"
    else
        log_error "Give a pack name, --mode or --group (see --help)."
        return 2
    fi

    printf '  %s\n' "$(policy_summary "$file")"
    printf '  unmatched: inbound %s · outbound %s\n' \
        "$(yq -r '.firewall.inbound_action // "drop"' "$file" 2>/dev/null)" \
        "$(yq -r '.firewall.outbound_action // "drop"' "$file" 2>/dev/null)"
    [[ -n "$tmp" ]] && rm -f "$tmp"
    return 0
}

policy_show() {
    local p; p="$(policy_resolve "${1:-}")" || return
    cat "$p"
}

# policy_create_from_config <name> <config_file> [groups_csv] [description] [force]
policy_create_from_config() {
    local name="$1" config="$2" groups="${3:-}" desc="${4:-}" force="${5:-0}"
    local path fw meta norm
    policy_name_valid "$name" || { log_error "Invalid policy name: '$name'"; return 2; }
    [[ -f "$config" ]] || { log_error "Config not found: $config"; return 1; }
    policy_ensure_dir || return 1
    path="$(policy_path "$name")" || return 2
    if [[ -f "$path" && "$force" != "1" ]]; then
        log_error "Policy pack already exists: $path (use --force to overwrite)"
        return 1
    fi
    declare -F _pki_groups_normalize >/dev/null && norm="$(_pki_groups_normalize "$groups")" || norm="$groups"
    fw="$(yq '.firewall // {}' "$config" 2>/dev/null)" || {
        log_error "Cannot read the firewall section from $config"; return 1; }
    meta="$(PK_NAME="$name" PK_DESC="$desc" PK_GROUPS="$norm" yq -n \
        '.name = strenv(PK_NAME) | .description = strenv(PK_DESC) | .groups = (strenv(PK_GROUPS) | split(",") | map(select(length > 0)))')" || return 1

    {
        printf '# Policy pack: %s\n' "$name"
        [[ -n "$desc" ]] && printf '# %s\n' "$desc"
        printf '%s\n' "$meta"
        if [[ -z "$fw" || "$fw" == "{}" ]]; then
            printf 'firewall: {}\n'
        else
            printf 'firewall:\n'
            printf '%s\n' "$fw" | sed 's/^/  /'
        fi
    } > "$path" || { log_error "Could not write $path"; return 1; }

    if ! policy_validate "$path"; then
        rm -f "$path"
        log_error "Generated pack was invalid and has been removed."
        return 1
    fi
    chmod 600 "$path" 2>/dev/null || true
    log_success "Policy pack written: $path"
    printf '%s\n' "$path"
}

# policy_apply_to_config <config_file> <pack_path>
# Replace the config's firewall section with the pack's firewall section.
policy_apply_to_config() {
    local config="$1" pack="$2"
    [[ -f "$config" ]] || { log_error "Config not found: $config"; return 1; }
    policy_validate "$pack" || return 1
    debug_explain "Replacing only the firewall section of $config with policy pack '$(basename "$pack" .yml)'; certificates and other settings stay unchanged."
    if ! FW_FILE="$pack" yq -i '.firewall = (load(strenv(FW_FILE)) | .firewall)' "$config"; then
        log_error "Could not apply $pack to $config"
        return 1
    fi
    return 0
}

# policy_suggest_for_cert <cert_name> <cert_dir>
# Print the packs whose target groups intersect the certificate's groups.
policy_suggest_for_cert() {
    local name="${1:-}" cert_dir="${2:-$(resolve_cert_dir)}"
    local crt="$cert_dir/$name.crt" bin_path json groups f d g pack_groups hit
    [[ -f "$crt" ]] || return 1
    bin_path="$(dirname "$(pki_cert_bin)")" || return 1
    json="$(nebula_cert_json "$bin_path" "$crt")" || return 1
    groups="$(jq -r '(.details.groups // []) | join(",")' <<<"$json" 2>/dev/null)"
    [[ -n "$groups" ]] || return 1
    d="$(policy_dir)"
    [[ -d "$d" ]] || return 1
    for f in "$d"/*.yml; do
        [[ -f "$f" ]] || continue
        hit=0
        while IFS= read -r g; do
            [[ -z "$g" ]] && continue
            if declare -F _pki_groups_have >/dev/null; then
                _pki_groups_have "$groups" "$g" && { hit=1; break; }
            else
                [[ ",$groups," == *",$g,"* ]] && { hit=1; break; }
            fi
        done < <(yq -r '.groups // [] | .[]' "$f" 2>/dev/null)
        (( hit )) && basename "$f" .yml
    done | sort
}

# --- per-node firewall preference -------------------------------------------
# When a node is created we ask which firewall its client config should use.
# The choice is remembered per certificate (and as "last") so `cert bundle` can
# preselect it. Everything lives under the user config dir; no root needed.
node_fw_state_file() { printf '%s/node-firewall.tsv' "$(dirname "$(policy_dir)")"; }

# node_fw_get <cert|last> ; prints "mode<TAB>pack" for the saved preference.
node_fw_get() {
    local key="${1:-}" f k mode pack
    [[ -n "$key" ]] || return 1
    f="$(node_fw_state_file)"
    [[ -f "$f" ]] || return 1
    while IFS=$'\t' read -r k mode pack; do
        [[ -z "$k" || "$k" == \#* ]] && continue
        [[ "$k" == "$key" ]] || continue
        printf '%s\t%s' "$mode" "${pack:-}"
        return 0
    done < "$f"
    return 1
}

# node_fw_set <cert|last> <mode> [pack] ; mode=skip removes the preference.
node_fw_set() {
    local key="$1" mode="$2" pack="${3:-}" f tmp
    [[ -n "$key" && -n "$mode" ]] || return 2
    f="$(node_fw_state_file)"
    mkdir -p "$(dirname "$f")" || return 1
    tmp="$(mktemp)" || return 1
    if [[ -f "$f" ]]; then
        awk -v k="$key" 'BEGIN { FS=OFS="\t" } $1 != k { print }' "$f" > "$tmp"
    fi
    [[ "$mode" == "skip" ]] || printf '%s\t%s\t%s\n' "$key" "$mode" "$pack" >> "$tmp"
    mv "$tmp" "$f"
}

node_fw_describe() {
    case "${1:-}" in
        pack)       printf 'policy pack %s' "${2:-?}" ;;
        host)       printf "copy this host's firewall (detected)" ;;
        permissive) printf 'permissive (allow all in/out)' ;;
        default)    printf 'Nebula defaults + ICMP (outbound allow, inbound drop)' ;;
        *)          printf 'decide later' ;;
    esac
}

# node_fw_render_group_policy <groups_csv> [with_icmp]
# Inbound: allow the listed certificate group(s). Outbound: allow all.
# ICMP from any host is allowed by default (diagnostics: a mesh you cannot ping
# is a mesh you cannot debug); pass with_icmp=0 to leave it out.
# Nebula AND-s a `groups:` list (the peer must carry every group), so multiple
# groups are emitted as one rule each (OR semantics).
# This is the "only <group> may connect in" policy used by `cert firewall`.
node_fw_render_group_policy() {
    local csv="${1:-}" with_icmp="${2:-1}" f g
    [[ -n "$csv" ]] || return 1
    local -a gs=()
    IFS=',' read -ra gs <<< "$csv"
    for g in "${gs[@]}"; do
        g="${g#"${g%%[![:space:]]*}"}"
        g="${g%"${g##*[![:space:]]}"}"
        [[ -n "$g" ]] || return 1
    done
    f="$(mktemp)" || return 1
    {
        printf 'firewall:\n  inbound:\n'
        for g in "${gs[@]}"; do
            g="${g#"${g%%[![:space:]]*}"}"
            g="${g%"${g##*[![:space:]]}"}"
            printf '    - port: any\n      proto: any\n      group: "%s"\n' "$g"
        done
        if [[ "$with_icmp" != "0" ]]; then
            printf '    # ICMP for diagnostics: any peer in the mesh may ping this node.\n'
            # No `port:` here: Nebula ignores it for ICMP and logs a warning.
            printf '    - proto: icmp\n      host: any\n'
        fi
        printf '  outbound:\n    - port: any\n      proto: any\n      host: any\n'
    } > "$f"
    printf '%s' "$f"
}

# node_fw_group_policy_pack <groups_csv> [with_icmp] ; prints a reusable pack
# named group-<g1>-<g2>. The file is auto-generated (see its header), so a
# changed renderer (e.g. the ICMP rule) converges the next time it is used.
node_fw_group_policy_pack() {
    local csv="${1:-}" with_icmp="${2:-1}" name path render g new
    [[ -n "$csv" ]] || return 1
    name="group-$(printf '%s' "$csv" | tr ',' '-')"
    name="$(printf '%s' "$name" | tr -c 'A-Za-z0-9._-' '-')"
    policy_name_valid "$name" || { log_error "Cannot derive a policy name from '$csv'"; return 2; }
    path="$(policy_path "$name")" || return 2
    policy_ensure_dir || return 1
    render="$(node_fw_render_group_policy "$csv" "$with_icmp")" || return 1
    local -a gs=()
    IFS=',' read -ra gs <<< "$csv"
    new="$(mktemp)"
    {
        printf '# Auto-generated by nebula-manager: inbound from group(s) %s\n' "$csv"
        if [[ "$with_icmp" != "0" ]]; then
            printf '# Inbound also allows ICMP from any peer (diagnostics); regenerate with\n# "cert firewall --from-group %s --no-icmp" to drop it.\n' "$csv"
        else
            printf '# ICMP inbound is NOT allowed (--no-icmp).\n'
        fi
        printf 'name: %s\n' "$name"
        printf 'description: Inbound only from group(s) %s\n' "$csv"
        printf 'groups:\n'
        for g in "${gs[@]}"; do
            g="${g#"${g%%[![:space:]]*}"}"; g="${g%"${g##*[![:space:]]}"}"
            [[ -n "$g" ]] && printf '  - "%s"\n' "$g"
        done
        cat "$render"
    } > "$new" || { rm -f "$render" "$new"; return 1; }
    rm -f "$render"
    chmod 600 "$new" 2>/dev/null || true
    if ! policy_validate "$new"; then
        rm -f "$new"; return 1
    fi
    if [[ -f "$path" ]] && cmp -s "$new" "$path" 2>/dev/null; then
        rm -f "$new"
        printf '%s\n' "$path"
        return 0
    fi
    # No log line here: this function's stdout is captured by the caller (the
    # path is the return value). The CLI already names the pack it will use.
    mv -f "$new" "$path" || { rm -f "$new"; return 1; }
    printf '%s\n' "$path"
}

# node_fw_render_policy <permissive|default> ; prints a temp policy file path.
node_fw_render_policy() {
    local mode="$1" f
    f="$(mktemp)" || return 1
    case "$mode" in
        permissive)
            # Nebula only accepts 'drop' and 'reject' as actions; the explicit
            # allow-all rules below do the permissive part.
            cat > "$f" <<'EOF'
firewall:
  inbound_action: drop
  outbound_action: drop
  inbound:
    - port: any
      proto: any
      host: any
  outbound:
    - port: any
      proto: any
      host: any
EOF
            ;;
        default)
            # Nebula's defaults are "outbound allow, inbound drop". ICMP from any
            # peer is allowed on top, so a class can always ping for diagnostics.
            # No `port:` on the ICMP rule: Nebula ignores it and logs a warning.
            cat > "$f" <<'EOF'
firewall:
  inbound:
    # ICMP for diagnostics: any peer in the mesh may ping this node.
    - proto: icmp
      host: any
  outbound:
    - port: any
      proto: any
      host: any
EOF
            ;;
        *) rm -f "$f"; return 1 ;;
    esac
    printf '%s' "$f"
}

# node_fw_choose_tui <cert> [cert_dir] [node|bundle]
# Menu of meaningful firewall choices for one node. The saved per-node choice
# (or the last used one) is offered first, so pressing Enter reuses it.
# Suggested policy packs are derived from the certificate's groups. Prints
# "mode<TAB>pack" and remembers the choice.
node_fw_choose_tui() {
    local cert="${1:?certificate name required}"
    local cert_dir="${2:-$(resolve_cert_dir)}" context="${3:-node}"
    local saved="" last="" mode="" pack="" p pg
    saved="$(node_fw_get "$cert" 2>/dev/null || true)"
    last="$(node_fw_get last 2>/dev/null || true)"

    local -a pairs=()
    if [[ -n "$saved" ]]; then
        IFS=$'\t' read -r mode pack <<< "$saved"
        pairs+=( "__saved__" "Keep saved choice: $(node_fw_describe "$mode" "$pack")" )
    elif [[ -n "$last" ]]; then
        IFS=$'\t' read -r mode pack <<< "$last"
        pairs+=( "__saved__" "Use last choice: $(node_fw_describe "$mode" "$pack")" )
    fi
    if declare -F policy_suggest_for_cert >/dev/null; then
        while IFS= read -r p; do
            [[ -n "$p" ]] || continue
            pg="$(yq -r '.groups // [] | join(":")' "$(policy_dir)/$p.yml" 2>/dev/null)"
            pairs+=( "pack:$p" "Policy pack: $p${pg:+ (groups $pg)}" )
        done < <(policy_suggest_for_cert "$cert" "$cert_dir" 2>/dev/null || true)
    fi
    pairs+=( "host" "Copy this host's firewall (detected)"
             "permissive" "Permissive: allow all inbound/outbound"
             "default" "Nebula defaults + ICMP: outbound allow, inbound drop" )
    # At bundle time there is nothing to defer; the host profile is the fallback.
    [[ "$context" != bundle ]] && pairs+=( "skip" "Decide later (at bundle time)" )

    local title prompt
    if [[ "$context" == bundle ]]; then
        title="Bundle firewall"
        prompt="Which firewall should config.yml carry for $cert?"
    else
        title="Node firewall"
        prompt="Which firewall should the client config for $cert use?"
    fi

    local choice
    choice="$(ui_menu "$title" "$prompt" "${pairs[@]}")" || {
        # Plain mode: Enter/Ctrl-D accepts the first (saved/last) choice.
        if [[ "$(ui_backend)" == plain ]]; then choice="__first__"; else return 1; fi
    }
    [[ "$choice" == "__first__" ]] && choice="${pairs[0]}"

    if [[ "$choice" == "__saved__" ]]; then
        if [[ -n "$saved" ]]; then IFS=$'\t' read -r mode pack <<< "$saved"
        else IFS=$'\t' read -r mode pack <<< "$last"; fi
    else
        case "$choice" in
            pack:*) mode="pack"; pack="${choice#pack:}" ;;
            host|permissive|default|skip) mode="$choice"; pack="" ;;
            *) return 1 ;;
        esac
    fi

    if [[ "$mode" != "skip" ]]; then
        node_fw_set "$cert" "$mode" "$pack" || true
        node_fw_set last "$mode" "$pack" || true
    fi
    printf '%s\t%s' "$mode" "${pack:-}"
}

# policy_export <pack> <out_dir> <cert_dir> [--select SPEC]... [--exclude SPEC]...
# Write <out>/<cert-name>/firewall.yml (+ README.txt) for the selected certs.
policy_export() {
    local pack="${1:?policy pack required}" out_dir="${2:-}" cert_dir="${3:-$(resolve_cert_dir)}"
    shift 3 || true
    local -a selects=() excludes=()
    while (( $# )); do
        case "$1" in
            --select)    shift; selects+=("${1:-}") ;;
            --select=*)  selects+=("${1#*=}") ;;
            --exclude)   shift; excludes+=("${1:-}") ;;
            --exclude=*) excludes+=("${1#*=}") ;;
            *) log_error "Unexpected argument for policy export: $1"; return 2 ;;
        esac
        shift
    done
    (( ${#selects[@]} )) || {
        log_error "policy export requires --select <spec> (e.g. --select group:example-group; use 'all' explicitly)."
        return 2
    }
    local pack_path; pack_path="$(policy_resolve "$pack")" || return
    policy_validate "$pack_path" || return 1

    local -a selargs=()
    local s
    for s in "${selects[@]}"; do selargs+=(--select "$s"); done
    for s in "${excludes[@]}"; do selargs+=(--exclude "$s"); done
    cert_select "$cert_dir" "${selargs[@]}" || {
        log_warn "No certificate matched the selection in $cert_dir."
        return 1
    }

    [[ -n "$out_dir" ]] || out_dir="${PWD:-$HOME}/policies"
    out_dir="${out_dir/#\~/$HOME}"
    mkdir -p "$out_dir" || { log_error "Cannot create $out_dir"; return 1; }
    debug_explain "Rendering policy '$pack' per host under $out_dir; no remote host is contacted."

    local i name dir count=0
    for i in "${!SEL_FILES[@]}"; do
        name="${SEL_NAMES[i]}"
        [[ -n "$name" ]] || continue
        name="${name//\//_}"          # never allow a path escape
        dir="$out_dir/$name"
        mkdir -p "$dir" || { log_error "Cannot create $dir"; continue; }
        {
            printf '# Policy pack: %s\n' "$pack"
            printf '# Generated by nebula-manager for %s\n' "$name"
            yq '.firewall // {}' "$pack_path"
        } > "$dir/firewall.yml" || { log_error "Cannot write $dir/firewall.yml"; continue; }
        chmod 644 "$dir/firewall.yml" 2>/dev/null || true

        cat > "$dir/README.txt" <<EOF
Policy pack : $pack
Target host : $name
Source      : $pack_path

Apply on that host (keep a backup first):

  sudo cp /etc/nebula/config.yml /etc/nebula/config.yml.bak.\$(date +%Y%m%d-%H%M%S)
  sudo cp firewall.yml /tmp/nebula-firewall.yml
  sudo yq -i '.firewall = load("/tmp/nebula-firewall.yml")' /etc/nebula/config.yml
  sudo nebula -test -config /etc/nebula/config.yml
  sudo systemctl restart nebula

The file contains only the firewall policy; certificates and keys are unchanged.
EOF
        printf '%s\n' "$dir/firewall.yml"
        count=$((count + 1))
    done
    log_success "Exported policy '$pack' for ${count} host(s) to $out_dir"
    return 0
}

# --- TUI --------------------------------------------------------------------

# policy_pairs ; fill POLICY_PAIRS with <name> <description> pairs.
policy_pairs() {
    POLICY_PAIRS=()
    local d; d="$(policy_dir)"
    [[ -d "$d" ]] || return 1
    local f name groups desc short
    while IFS= read -r f; do
        [[ -f "$f" ]] || continue
        name="$(basename "$f" .yml)"
        groups="$(yq -r '.groups // [] | join(",")' "$f" 2>/dev/null)"
        desc="$name"
        [[ -n "$groups" ]] && desc+=" [$groups]"
        # Show what the pack allows, so the menu is a decision aid, not a name quiz.
        short="$(policy_summary_short "$f" 2>/dev/null)" && desc+=" — $short"
        POLICY_PAIRS+=( "$name" "$desc" )
    done < <(find "$d" -maxdepth 1 -name '*.yml' -type f | sort)
    (( ${#POLICY_PAIRS[@]} > 0 ))
}

# policy_name_pick ; choose a pack from the existing ones (prints its name).
policy_name_pick() {
    local d; d="$(policy_dir)"
    local -a pairs=()
    local f name groups short
    if [[ -d "$d" ]]; then
        while IFS= read -r f; do
            [[ -f "$f" ]] || continue
            name="$(basename "$f" .yml)"
            groups="$(yq -r '.groups // [] | join(",")' "$f" 2>/dev/null)"
            short="$(policy_summary_short "$f" 2>/dev/null)" || short="?"
            pairs+=( "$name" "${groups:+[$groups] }$short" )
        done < <(find "$d" -maxdepth 1 -name '*.yml' -type f | sort)
    fi
    (( ${#pairs[@]} )) || { log_warn "No policy packs in $d yet."; return 1; }
    ui_menu "Policy packs" "Select a pack (what it allows):" "${pairs[@]}"
}

# TUI: the pack library - list, explain, edit, create, delete.
policy_menu_tui() {
    while true; do
        local choice name
        choice="$(ui_menu "Policy packs" \
            "Reusable firewall fragments (embeddable in bundles, applicable to this host). Store: $(policy_dir)" \
            list    "List packs: one line of rules each" \
            explain "Explain a pack / a built-in mode" \
            edit    "Edit a pack" \
            new     "Create a pack from a config" \
            delete  "Delete a pack") " || return 0
        case "$choice" in
            list)    policy_list ;;
            explain) name="$(policy_name_pick)" || continue; policy_explain_cli "$name" ;;
            edit)    name="$(policy_name_pick)" || continue
                     "${EDITOR:-${VISUAL:-vi}}" "$(policy_resolve "$name")"
                     log_info "Saved policy pack: $(policy_resolve "$name")" ;;
            new)     policy_create_tui ;;
            delete)  name="$(policy_name_pick)" || continue; policy_cli delete "$name" ;;
            *)       return 0 ;;
        esac
    done
}

policy_create_tui() {
    local name desc groups config="${NEBULA_LOCAL_CONFIG:-${NEBULA_DIR:-/etc/nebula}/config.yml}"
    if ! command -v yq >/dev/null 2>&1; then
        log_error "yq is required."; return 1
    fi
    name="$(ui_input "New policy pack" "Pack name (e.g. policy1):")" || return 0
    [[ -z "$name" ]] && { log_info "Canceled."; return 0; }
    policy_name_valid "$name" || { log_error "Invalid policy name: '$name'"; return 1; }
    desc="$(ui_input "New policy pack" "Description (optional):")" || return 0
    groups="$(ui_input "New policy pack" "Suggested groups, comma-separated (optional):")" || return 0

    local readable tmp=""
    readable="$(readable_nebula_config "$config")" || readable=""
    if [[ -z "$readable" ]]; then
        log_error "Cannot read the local Nebula config at $config."
        return 1
    fi
    [[ "$readable" != "$config" ]] && tmp="$readable"
    local force=0
    if [[ -f "$(policy_dir)/$name.yml" ]]; then
        ui_yesno "New policy pack" "Pack '$name' already exists. Overwrite it?" || { rm -f "$tmp"; return 0; }
        force=1
    fi
    policy_create_from_config "$name" "$readable" "$groups" "$desc" "$force"
    local rc=$?
    [[ -n "$tmp" ]] && rm -f "$tmp"
    return $rc
}

policy_export_tui() {
    if ! policy_pairs; then
        log_warn "No policy packs in $(policy_dir)."
        return 1
    fi
    local pack
    pack="$(ui_menu "Export policy" "Policy pack to export:" "${POLICY_PAIRS[@]}")" || return 0

    local cert_dir; cert_dir="$(resolve_cert_dir)"
    cert_select_tui "$cert_dir" || return 0

    local default_out out
    default_out="${PWD:-$HOME}/policies"
    out="$(ui_dselect "Export policy" "Output directory [${default_out}]:" "$default_out")" || return 0
    out="${out/#\~/$HOME}"
    [[ -z "$out" ]] && out="$default_out"

    local -a selargs=()
    local n
    for n in "${SEL_NAMES[@]}"; do selargs+=(--select "cert:$n"); done
    policy_export "$pack" "$out" "$cert_dir" "${selargs[@]}"
}

policy_apply_tui() {
    local config="$1" pack pack_path
    if ! policy_pairs; then
        log_warn "No policy packs in $(policy_dir)."
        return 1
    fi
    pack="$(ui_menu "Apply policy" "Replace this config's firewall with:" "${POLICY_PAIRS[@]}")" || return 0
    pack_path="$(policy_resolve "$pack")" || return 1
    if policy_apply_to_config "$config" "$pack_path"; then
        log_success "Applied policy pack '$pack' to the working config (review the diff when you leave the menu)."
    else
        log_error "Could not apply policy pack '$pack'."
        return 1
    fi
}

policy_manage_tui() {
    local config="${1:-}" choice
    while true; do
        local -a options=( list "List policy packs" new "New pack from this host's firewall"
            show "Show a pack" edit "Edit a pack" delete "Delete a pack"
            export "Export a pack for a set of certificates" )
        if [[ -n "$config" ]]; then
            options+=( apply "Apply a pack to the config being edited" )
        fi
        choice="$(ui_menu "Policy packs" "Firewall policy packs ($(policy_dir)):" "${options[@]}")" || return 0
        case "$choice" in
            list)   policy_list ;;
            new)    policy_create_tui ;;
            show)   policy_show_tui ;;
            edit)   policy_edit_tui ;;
            delete) policy_delete_tui ;;
            export) policy_export_tui ;;
            apply)  policy_apply_tui "$config" ;;
        esac
        ui_yesno "Policy packs" "Keep managing policy packs?" || break
    done
}

policy_pick() {
    policy_pairs || { log_warn "No policy packs in $(policy_dir)."; return 1; }
    ui_menu "Policy packs" "Choose a pack:" "${POLICY_PAIRS[@]}"
}

policy_show_tui() {
    local pack; pack="$(policy_pick)" || return 0
    local path; path="$(policy_resolve "$pack")" || return 1
    ui_textbox "Policy pack: $pack" "$(cat "$path")"
}

policy_edit_tui() {
    local pack; pack="$(policy_pick)" || return 0
    local path; path="$(policy_resolve "$pack")" || return 1
    "${EDITOR:-vi}" "$path"
}

policy_delete_tui() {
    local pack; pack="$(policy_pick)" || return 0
    local path; path="$(policy_resolve "$pack")" || return 1
    ui_yesno "Delete policy" "Delete policy pack '$pack'? ($path)" || return 0
    rm -f "$path" && log_success "Deleted $path"
}

# --- CLI --------------------------------------------------------------------

policy_usage() {
    cat <<'EOF'
Usage: nebula-manager policy <command> [options]

Commands:
  list                          List packs with what they allow (one line each)
  explain <name>|--mode M|--group G
                                What does this choice actually allow?
  show <name>                   Print a pack
  new <name> [options]          Create a pack from a Nebula config
       --from-config FILE       Source config (default: this host's config.yml)
       --groups g1,g2           Groups this pack is meant for (suggestion metadata)
       --description TEXT
       --force                  Overwrite an existing pack
  edit <name>                   Open the pack in $EDITOR
  delete <name> [--yes]         Delete a pack
  validate <name|--file FILE>   Structural validation
  apply --pack <name> [--nebula-config FILE] [--yes]
                                Replace this host's firewall with the pack
                                (working copy + backup + diff confirmation)
  export --pack <name> --select SPEC [--out DIR] [--cert-dir DIR]
                                Write <out>/<cert>/firewall.yml + README.txt
                                for every selected certificate
  dir                           Print the policy directory

Selector specs for export: all | group:G | without:G | name:GLOB | ip:CIDR | cert:NAME
EOF
}

policy_new_cli() {
    local name="${1:-}"; shift || true
    local config="" groups="" desc="" force=0
    while (( $# )); do
        case "$1" in
            --from-config)   shift; config="${1:-}" ;;
            --from-config=*) config="${1#*=}" ;;
            --groups|-g)     shift; groups="${1:-}" ;;
            --groups=*)      groups="${1#*=}" ;;
            --description|-d) shift; desc="${1:-}" ;;
            --description=*) desc="${1#*=}" ;;
            --force|-f)      force=1 ;;
            *) log_error "Unknown option for 'policy new': $1"; return 2 ;;
        esac
        shift
    done
    [[ -n "$name" ]] || { echo "Usage: nebula-manager policy new <name> [--from-config FILE] [--groups g1,g2] [--description TEXT] [--force]" >&2; return 2; }
    local tmp=""
    if [[ -z "$config" ]]; then
        config="${NEBULA_LOCAL_CONFIG:-${NEBULA_DIR:-/etc/nebula}/config.yml}"
        local readable
        readable="$(readable_nebula_config "$config")" || readable=""
        if [[ -z "$readable" ]]; then
            log_error "Cannot read the local Nebula config at $config."
            log_info "Pass --from-config with a readable copy, or approve the temporary sudo read."
            return 1
        fi
        [[ "$readable" != "$config" ]] && tmp="$readable"
        config="$readable"
    fi
    policy_create_from_config "$name" "$config" "$groups" "$desc" "$force"
    local rc=$?
    [[ -n "$tmp" ]] && rm -f "$tmp"
    return $rc
}

policy_apply_cli() {
    local pack="" config="" assume_yes=0
    while (( $# )); do
        case "$1" in
            --pack|-p)       shift; pack="${1:-}" ;;
            --pack=*)        pack="${1#*=}" ;;
            --nebula-config) shift; config="${1:-}" ;;
            --nebula-config=*) config="${1#*=}" ;;
            --config)        shift; config="${1:-}" ;;
            --config=*)      config="${1#*=}" ;;
            --yes|-y)        assume_yes=1 ;;
            *) log_error "Unknown option for 'policy apply': $1"; return 2 ;;
        esac
        shift
    done
    [[ -n "$pack" ]] || { echo "Usage: nebula-manager policy apply --pack NAME [--nebula-config FILE] [--yes]" >&2; return 2; }
    local pack_path; pack_path="$(policy_resolve "$pack")" || return 1
    config="${config:-${NEBULA_DIR:-/etc/nebula}/config.yml}"

    config_edit_begin "$config" || return 1
    local work="$CONFIG_EDIT_WORK" before
    before="$(mktemp)" || { config_edit_cancel; return 1; }
    cp "$work" "$before" || { rm -f "$before"; config_edit_cancel; return 1; }

    if ! policy_apply_to_config "$work" "$pack_path"; then
        if [[ "$work" == "$config" ]]; then cp "$before" "$config" 2>/dev/null || true; fi
        rm -f "$before"; config_edit_cancel
        return 1
    fi

    if (( ! assume_yes )); then
        if ! firewall_commit_with_preview "$before" "$work" "$config"; then
            if [[ "$work" == "$config" ]]; then cp "$before" "$config" 2>/dev/null || true; fi
            rm -f "$before"; config_edit_cancel
            log_info "Canceled - the config was not changed."
            return 0
        fi
    fi
    rm -f "$before"
    config_edit_commit || return 1
    log_success "Applied policy pack '$pack' to $config"
    check_nebula_config "$config" "error"
}

policy_cli() {
    if [[ "${1:-}" == "-h" || "${1:-}" == "--help" || "${1:-}" == "help" ]]; then
        policy_usage; return 0
    fi
    local sub="${1:-list}"; shift || true
    case "$sub" in
        dir)       policy_dir; printf '\n' ;;
        list|ls)   policy_list ;;
        explain|describe) policy_explain_cli "$@" ;;
        show)      policy_show "${1:-}" ;;
        new|create) policy_new_cli "$@" ;;
        edit)
            local p; p="$(policy_resolve "${1:-}")" || return
            "${EDITOR:-vi}" "$p" ;;
        delete|rm)
            local name="${1:-}" assume=0
            shift || true
            [[ "${1:-}" == "--yes" || "${1:-}" == "-y" ]] && assume=1
            local p; p="$(policy_resolve "$name")" || return
            if (( ! assume )); then
                if [[ -t 0 ]]; then
                    local a; read -rp "$(show_status 'question') Delete policy pack '$name'? [y/N]: " a
                    [[ "$a" =~ ^[Yy]$ ]] || { log_info "Canceled."; return 0; }
                else
                    log_error "Refusing to delete without confirmation; re-run with --yes."
                    return 2
                fi
            fi
            rm -f "$p" && log_success "Deleted $p" ;;
        validate)
            local ref="${1:-}"
            if [[ "$ref" == "--file" ]]; then shift; ref="${1:-}"; fi
            local p; p="$(policy_resolve "$ref")" || return
            if policy_validate "$p"; then
                log_success "Policy pack is valid: $p"
            else
                return 1
            fi ;;
        apply)     policy_apply_cli "$@" ;;
        export)
            local pack="" out="" cert_dir=""
            local -a sels=() exc=()
            while (( $# )); do
                case "$1" in
                    --pack|-p)       shift; pack="${1:-}" ;;
                    --pack=*)        pack="${1#*=}" ;;
                    --out|-o)        shift; out="${1:-}" ;;
                    --out=*)         out="${1#*=}" ;;
                    --cert-dir)      shift; cert_dir="${1:-}" ;;
                    --cert-dir=*)    cert_dir="${1#*=}" ;;
                    --select)        shift; sels+=("${1:-}") ;;
                    --select=*)      sels+=("${1#*=}") ;;
                    --exclude)       shift; exc+=("${1:-}") ;;
                    --exclude=*)     exc+=("${1#*=}") ;;
                    -h|--help)       policy_usage; return 0 ;;
                    *) log_error "Unknown option for 'policy export': $1"; return 2 ;;
                esac
                shift
            done
            [[ -n "$pack" ]] || { log_error "policy export requires --pack NAME"; return 2; }
            local -a args=()
            local s
            for s in "${sels[@]}"; do args+=(--select "$s"); done
            for s in "${exc[@]}";  do args+=(--exclude "$s"); done
            policy_export "$pack" "$out" "${cert_dir:-$(resolve_cert_dir)}" "${args[@]}" ;;
        *) log_error "Unknown 'policy' subcommand: $sub"; policy_usage >&2; return 2 ;;
    esac
}
