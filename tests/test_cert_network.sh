#!/usr/bin/env bash
# Test: a certificate signed into a different overlay network is flagged.
#   Nebula routes at layer 3 and the tun route only covers the certificate's own
#   network, so a client in 10.100.1.0/24 is unreachable from 10.100.0.0/24
#   hosts without extra routes on every peer.
set -uo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/helpers.sh"

TEST_LABEL="certificate overlay network guard"
harness_init
require_cmd nebula-cert
require_cmd jq

keys="$SANDBOX/keys"
export CERT_DIR_OVERRIDE="$keys"

CA_NAME="NetCA" CERT_DIR="$keys" pki_ca_create >/dev/null 2>&1 || {
    echo "SKIP: cannot create a CA with the installed nebula-cert"; exit 77; }
SIGN_NAME="vps.mesh.demo" SIGN_IP="10.100.0.1/24" CERT_DIR="$keys" pki_sign >/dev/null 2>&1

# --- same network: no warning ------------------------------------------------
out="$(SIGN_NAME="same.mesh.demo" SIGN_IP="10.100.0.2/24" CERT_DIR="$keys" pki_sign 2>&1)"; rc=$?
assert_eq "same-network sign succeeds" "$rc" "0"
assert_not_contains "same network is not flagged" "$out" "outside the overlay network"

# --- foreign network: warning, certificate still issued ----------------------
out="$(SIGN_NAME="far.mesh.demo" SIGN_IP="10.100.1.11/24" CERT_DIR="$keys" pki_sign 2>&1)"; rc=$?
assert_eq "foreign-network sign still succeeds" "$rc" "0"
assert_contains "foreign network is flagged" "$out" "outside the overlay network"
assert_contains "warning names the existing network" "$out" "10.100.0.0/24"
assert_contains "warning explains the routing impact" "$out" "will not reach this one over L3"
assert_file "certificate is still written" "$keys/far.mesh.demo.crt"

# --- once both networks exist, either is accepted silently -------------------
out="$(SIGN_NAME="far2.mesh.demo" SIGN_IP="10.100.1.12/24" CERT_DIR="$keys" pki_sign 2>&1)"
assert_not_contains "known network is not flagged again" "$out" "outside the overlay network"

# --- helpers -----------------------------------------------------------------
assert_contains "network list includes the foreign network" "$(cert_network_list "$keys")" "10.100.1.0/24"
assert_eq "helper accepts a known network" "$(pki_foreign_networks 10.100.0.9/24 "$keys")" ""
assert_contains "helper reports an unknown network" \
    "$(pki_foreign_networks 10.200.0.9/24 "$keys")" "10.100.0.0/24"

harness_summary
