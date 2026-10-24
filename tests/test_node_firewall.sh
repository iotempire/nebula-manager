#!/usr/bin/env bash
# Test: per-node firewall preference used by the client-config template.
#   * state is stored user-side (no sudo)
#   * suggested policy packs come from the certificate's groups
#   * the saved/last choice is reused when Enter is pressed
#   * permissive / Nebula-default profiles render valid firewall fragments
set -uo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/helpers.sh"

TEST_LABEL="node firewall preference"
harness_init
require_cmd nebula-cert
require_cmd jq
require_cmd yq

keys="$SANDBOX/keys"
export CERT_DIR_OVERRIDE="$keys"

CA_NAME="test-ca" CERT_DIR="$keys" pki_ca_create >/dev/null 2>&1 || {
    echo "SKIP: cannot create a CA with the installed nebula-cert"; exit 77; }
SIGN_NAME="alpha.mesh" SIGN_IP="10.70.0.2/24" SIGN_GROUPS="laptops" \
    CERT_DIR="$keys" pki_sign >/dev/null 2>&1
SIGN_NAME="beta.mesh" SIGN_IP="10.70.0.3/24" SIGN_GROUPS="laptops" \
    CERT_DIR="$keys" pki_sign >/dev/null 2>&1

# A policy pack whose groups intersect the certificates.
mkdir -p "$(policy_dir)"
cat > "$(policy_dir)/home.yml" <<'YAML'
name: home
groups: [laptops]
firewall:
  inbound_action: drop
  inbound:
    - port: any
      proto: any
      groups: [laptops]
YAML

state="$(node_fw_state_file)"
assert_contains "state lives under the user config dir" "$state" "$XDG_CONFIG_HOME"

# --- direct state helpers ---------------------------------------------------
node_fw_set alpha.mesh pack home
assert_eq "state stores the pack" "$(node_fw_get alpha.mesh)" $'pack\thome'
node_fw_set alpha.mesh skip
assert_eq "skip removes the preference" "$(node_fw_get alpha.mesh; echo "rc=$?")" "rc=1"
node_fw_set last host
assert_eq "last choice is stored separately" "$(node_fw_get last)" $'host\t'
rm -f "$state"

# --- rendered profiles ------------------------------------------------------
p="$(node_fw_render_policy permissive)"
assert_contains "permissive allows inbound"  "$(cat "$p")" "inbound_action: accept"
assert_contains "permissive allows outbound" "$(cat "$p")" "outbound_action: accept"
rm -f "$p"
p="$(node_fw_render_policy default)"
assert_contains "default is an empty firewall block" "$(cat "$p")" "firewall: {}"
rm -f "$p"

# The rendered profile is what the generated client template embeds.
p="$(node_fw_render_policy permissive)"
pki_write_client_config "$SANDBOX/client.yml" alpha.mesh "$keys" "$p" >/dev/null 2>&1
assert_contains "client template carries the rendered firewall" \
    "$(cat "$SANDBOX/client.yml")" "inbound_action: accept"
rm -f "$p"

# A rendered profile can be embedded in a full bundle.
p="$(node_fw_render_policy permissive)"
mkdir -p "$SANDBOX/fwout"
pki_bundle_client_zip alpha.mesh "$SANDBOX/fwout" "$keys" "$p" >/dev/null 2>&1
assert_file "permissive policy bundles successfully" "$SANDBOX/fwout/alpha.mesh-nebula-bundle.zip"
rm -f "$p"

# --- chooser: suggested pack is the first/default option --------------------
out="$(printf '1\n' | node_fw_choose_tui alpha.mesh "$keys" node 2>/dev/null)"
assert_eq "chooser picks the suggested pack" "$out" $'pack\thome'
assert_eq "choice is saved per node" "$(node_fw_get alpha.mesh)" $'pack\thome'
assert_eq "choice is saved as last" "$(node_fw_get last)" $'pack\thome'

# Enter reuses the last choice for a different (new) node.
out="$(printf '\n' | node_fw_choose_tui beta.mesh "$keys" node 2>/dev/null)"
assert_eq "Enter reuses the last choice" "$out" $'pack\thome'

# --- skip -------------------------------------------------------------------
rm -f "$state"
out="$(printf '5\n' | node_fw_choose_tui alpha.mesh "$keys" node 2>/dev/null)"
assert_eq "skip is reported to the caller" "$out" $'skip\t'
assert_eq "skip stores nothing" "$(node_fw_get alpha.mesh; echo "rc=$?")" "rc=1"

# --- creating a node asks for its client firewall --------------------------
# Stub the chooser so we can assert the wiring without driving that menu too.
choose_log="$SANDBOX/choose.log"
node_fw_choose_tui() { printf '%s\n' "$1" > "$choose_log"; return 0; }
printf 'gamma.mesh\nn\n\nguest\nn\n\n' | generate_nebula_cert >/dev/null 2>&1
assert_file "node creation asks for a firewall" "$choose_log"
assert_contains "the firewall prompt is for the new node" "$(cat "$choose_log")" "gamma.mesh"
assert_file "the new certificate was signed" "$keys/gamma.mesh.crt"

assert_eq "no sudo used" "$(sudo_count)" "0"

harness_summary
