#!/usr/bin/env bash
# Test: certificate workspace selection / "already known" detection.
set -uo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/helpers.sh"

TEST_LABEL="certificate workspace selection"
harness_init

# --- nothing configured -> not known (so the TUI will prompt) ---
if nebula_keys_known; then _bad "unknown by default"; else _ok "unknown by default"; fi

# --- explicit --cert-dir / env -> known (never prompt) ---
export CERT_DIR_OVERRIDE="$SANDBOX/x"
if nebula_keys_known; then _ok "--cert-dir -> known"; else _bad "--cert-dir -> known"; fi
unset CERT_DIR_OVERRIDE
export NEBULA_KEYS_DIR="$SANDBOX/y"
if nebula_keys_known; then _ok "NEBULA_KEYS_DIR -> known"; else _bad "NEBULA_KEYS_DIR -> known"; fi
unset NEBULA_KEYS_DIR

# --- saved interactive selection -> known ---
save_cert_dir_selection "$SANDBOX/saved"
if nebula_keys_known; then _ok "saved selection -> known"; else _bad "saved selection -> known"; fi
rm -f "$(nebula_keys_state_file)"

# --- an existing user store (~/keys/nebula) is offered as a candidate ---
mkdir -p "$HOME/keys/nebula"
: > "$HOME/keys/nebula/ca.crt"
assert_contains "candidate ~/keys/nebula detected" "$(workspace_candidates)" "$HOME/keys/nebula"

# --- populated legacy server cert dir -> known ---
export NEBULA_DIR="$SANDBOX/srv"
mkdir -p "$NEBULA_DIR/certs"
: > "$NEBULA_DIR/certs/node.crt"
if nebula_keys_known; then _ok "legacy server certs -> known"; else _bad "legacy server certs -> known"; fi
unset NEBULA_DIR

# --- [global] cert_dir in the manager config is honoured --------------------
conf="$SANDBOX/manager.conf"
mkdir -p "$SANDBOX/from-conf"
cat > "$conf" <<EOF
[global]
bin_path=/usr/bin
cert_dir=$SANDBOX/from-conf

[server.default]
dir=/etc/nebula
enabled=true
EOF
export CONF_OVERRIDE="$conf"
assert_eq "manager conf cert_dir is used" "$(resolve_cert_dir)" "$SANDBOX/from-conf"
if nebula_keys_known; then _ok "manager conf cert_dir -> known"; else _bad "manager conf cert_dir -> known"; fi

# A stale saved workspace must not shadow a populated manager-config store.
: > "$SANDBOX/from-conf/node.crt"
save_cert_dir_selection "$SANDBOX/stale-empty-keys"
assert_eq "stale empty selection falls back to manager conf" \
    "$(resolve_cert_dir)" "$SANDBOX/from-conf"
# A populated saved workspace still wins over the manager config.
mkdir -p "$SANDBOX/saved-populated"
: > "$SANDBOX/saved-populated/node.crt"
save_cert_dir_selection "$SANDBOX/saved-populated"
assert_eq "populated saved selection beats manager conf" \
    "$(resolve_cert_dir)" "$SANDBOX/saved-populated"
rm -f "$(nebula_keys_state_file)"

# Explicit sources still win over the saved manager config.
export NEBULA_KEYS_DIR="$SANDBOX/env-keys"
assert_eq "NEBULA_KEYS_DIR beats manager conf" "$(resolve_cert_dir)" "$SANDBOX/env-keys"
unset NEBULA_KEYS_DIR
export CERT_DIR_OVERRIDE="$SANDBOX/flag-keys"
assert_eq "--cert-dir beats manager conf" "$(resolve_cert_dir)" "$SANDBOX/flag-keys"
unset CERT_DIR_OVERRIDE

# Tilde is expanded in the manager config.
cat > "$conf" <<EOF
[global]
cert_dir=~/keys-from-conf
EOF
assert_eq "tilde in manager conf is expanded" "$(resolve_cert_dir)" "$HOME/keys-from-conf"
unset CONF_OVERRIDE

harness_summary
