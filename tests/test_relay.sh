#!/usr/bin/env bash
# Test: Nebula relay settings (`relay:` block).
#   * node configs render the documented block only when a setting exists
#   * cert relay: selection, --relay/--no-relay/--am-relay/--show, idempotent
#   * an address that is not a certificate in the workspace is refused
#   * bundles carry the block (also when the stored config predates it)
#   * sign --relay puts the block in a fresh certificate's config
#   * fleet ssh --relay merges into a remote config (mocked ssh, --dry-run)
#   * relay local: --show, --am-relay, backup, validation, restart (mocked)
#   * firewall explain prints the relay state and flags unknown relays
set -uo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/helpers.sh"

TEST_LABEL="relay settings"
harness_init
require_cmd nebula-cert
require_cmd jq
require_cmd yq
require_cmd unzip

keys="$SANDBOX/keys"
export CERT_DIR_OVERRIDE="$keys"
CA_NAME="test-ca" CERT_DIR="$keys" pki_ca_create >/dev/null 2>&1 || {
    echo "SKIP: cannot create a CA with the installed nebula-cert"; exit 77; }
CERT_DIR="$keys" SIGN_NAME="lh.mesh"     SIGN_IP="10.91.0.1/16" SIGN_GROUPS="infra"    pki_sign >/dev/null 2>&1
CERT_DIR="$keys" SIGN_NAME="alice.mesh"  SIGN_IP="10.91.0.2/16" SIGN_GROUPS="students" pki_sign >/dev/null 2>&1
CERT_DIR="$keys" SIGN_NAME="bob.mesh"    SIGN_IP="10.91.0.3/16" SIGN_GROUPS="students" pki_sign >/dev/null 2>&1
CERT_DIR="$keys" SIGN_NAME="phone.mesh"  SIGN_IP="10.91.0.4/16" SIGN_GROUPS="students" pki_sign >/dev/null 2>&1
rm -f "$keys/phone.mesh.key"      # mobile-style cert: no local key, no node config

relay_block() { awk '/^relay:/ { f = 1 } f' "$1"; }

# --- 1) rendering without and with a setting --------------------------------
pki_node_config_write_for_fw alice.mesh "$keys" 1 >/dev/null 2>&1
alice_cfg="$keys/alice.mesh.yml"
assert_file "node config is written" "$alice_cfg"
assert_not_contains "no relay block by default" "$(cat "$alice_cfg")" "relay:"
assert_contains "config keeps the pki section" "$(cat "$alice_cfg")" "pki:"
assert_contains "config keeps the tun section" "$(cat "$alice_cfg")" "tun:"

node_relay_set alice.mesh use "10.91.0.1"
pki_node_config_write_for_fw alice.mesh "$keys" 1 >/dev/null 2>&1
assert_eq "client relay block matches the documented shape" \
    "$(relay_block "$alice_cfg")" $'relay:\n  am_relay: false\n  use_relays: true\n  relays:\n    - 10.91.0.1'
assert_contains "the rest of the config still renders" "$(cat "$alice_cfg")" "lighthouse:"

# The lighthouse shape, verbatim.
node_relay_set bob.mesh am ""
pki_node_config_write_for_fw bob.mesh "$keys" 1 >/dev/null 2>&1
assert_eq "lighthouse relay block matches the documented shape" \
    "$(relay_block "$keys/bob.mesh.yml")" $'relay:\n  am_relay: true'

# Several addresses render as a list.
node_relay_set bob.mesh use "10.91.0.1,10.91.0.2"
pki_node_config_write_for_fw bob.mesh "$keys" 1 >/dev/null 2>&1
assert_contains "first relay address is listed" "$(relay_block "$keys/bob.mesh.yml")" "    - 10.91.0.1"
assert_contains "second relay address is listed" "$(relay_block "$keys/bob.mesh.yml")" "    - 10.91.0.2"

# --- 2) batch: selection, idempotency, --show -------------------------------
out="$(relay_batch_cli --cert-dir "$keys" --select group:students --relay 10.91.0.1 --yes 2>&1)"
assert_eq "batch exits 0" "$?" "0"
assert_contains "batch reports alice" "$out" "Relay for alice.mesh"
assert_contains "batch reports bob" "$out" "Relay for bob.mesh"
assert_contains "batch skips the keyless cert" "$out" "no local private key"
assert_eq "alice uses the relay" "$(node_relay_get alice.mesh)" $'use\t10.91.0.1'
assert_eq "bob uses the relay" "$(node_relay_get bob.mesh)" $'use\t10.91.0.1'
assert_no_file "the keyless cert gets no node config" "$keys/phone.mesh.yml"

out="$(relay_batch_cli --cert-dir "$keys" --select cert:alice.mesh --relay 10.91.0.1 --dry-run 2>&1)"
assert_contains "second run is idempotent" "$out" "(no change)"

out="$(relay_batch_cli --cert-dir "$keys" --select all --show 2>&1)"
assert_contains "show lists every certificate" "$out" "lh.mesh"
assert_contains "show lists alice" "$out" "alice.mesh"
assert_contains "show lists bob" "$out" "bob.mesh"
assert_contains "show lists the keyless cert" "$out" "phone.mesh"
assert_contains "show marks the keyless cert" "$out" "no local key"
assert_contains "show reports the relay setting" "$out" "use_relays: on, relays: 10.91.0.1"
assert_contains "show reports an unset certificate" "$out" "not set (no relay: block)"

# The same state in one line per certificate (`cert list`).
out="$(list_certs 2>&1)"
assert_contains "cert list has a relay column" "$out" "groups,subnets,relay,from,to"
assert_contains "cert list shows the relay setting" "$out" "alice.mesh,Cert,10.91.0.2/16,students,None,use:10.91.0.1,"
assert_contains "cert list shows an unset certificate" "$out" "lh.mesh,Cert,10.91.0.1/16,infra,None,no,"

# --- 3) an address that is not a certificate is refused ---------------------
out="$(relay_batch_cli --cert-dir "$keys" --select cert:alice.mesh \
    --relay 10.91.9.9 --yes 2>&1)"; rc=$?
assert_eq "unknown relay is refused" "$rc" "1"
assert_contains "unknown relay is named" "$out" "not a certificate in"
assert_contains "closest match is offered" "$out" "10.91.0.1 (lh.mesh)"
assert_eq "refusal changed nothing" "$(node_relay_get alice.mesh)" $'use\t10.91.0.1'

out="$(relay_batch_cli --cert-dir "$keys" --select cert:alice.mesh --relay 10.91.0.1,teleport.local --yes 2>&1)"; rc=$?
assert_eq "a host name is refused" "$rc" "2"
assert_contains "the host name is named" "$out" "Not an IP address"

# --- 4) --dry-run prints the exact diff ------------------------------------
out="$(relay_batch_cli --cert-dir "$keys" --select cert:lh.mesh --relay 10.91.0.2 --dry-run 2>&1)"
assert_contains "dry run shows the added block" "$out" "+relay:"
assert_contains "dry run shows use_relays" "$out" "+  use_relays: true"
assert_contains "dry run shows the relay list" "$out" "+    - 10.91.0.2"
assert_eq "dry run stores no setting" "$(node_relay_get lh.mesh)" ""

# --- 5) --no-relay removes the block ---------------------------------------
out="$(relay_batch_cli --cert-dir "$keys" --select cert:alice.mesh --no-relay --yes 2>&1)"
assert_eq "--no-relay exits 0" "$?" "0"
assert_not_contains "relay block removed" "$(cat "$keys/alice.mesh.yml")" "relay:"
assert_eq "--no-relay is remembered" "$(node_relay_get alice.mesh)" $'off\t'

# --- 6) sign --relay --------------------------------------------------------
out="$(pki_sign_cli --name dave.mesh --ip 10.91.0.5/16 --groups students \
        --relay 10.91.0.1 --cert-dir "$keys" 2>&1)"
assert_eq "sign --relay exits 0" "$?" "0"
assert_file "sign --relay writes the node config" "$keys/dave.mesh.yml"
assert_contains "signed config has use_relays" "$(cat "$keys/dave.mesh.yml")" "use_relays: true"
assert_contains "signed config lists the relay" "$(cat "$keys/dave.mesh.yml")" "    - 10.91.0.1"

out="$(pki_sign_cli --name eve.mesh --ip 10.91.0.6/16 --relay 10.91.9.9 --cert-dir "$keys" 2>&1)"; rc=$?
assert_eq "sign --relay refuses an unknown relay" "$rc" "1"
assert_contains "sign explains the refusal" "$out" "not a certificate in"
assert_no_file "the refused certificate was not signed" "$keys/eve.mesh.crt"

# --- 7) bundles carry the block --------------------------------------------
outdir="$SANDBOX/bundles"
pki_bundle_client_zip dave.mesh "$outdir" "$keys" "" "" "" >/dev/null 2>&1
tmpl="$(unzip -p "$outdir/dave.mesh-nebula-bundle.zip" config.yml.template)"
assert_contains "bundle template has am_relay" "$tmpl" "am_relay: false"
assert_contains "bundle template has use_relays" "$tmpl" "use_relays: true"
assert_contains "bundle template has the relay list" "$tmpl" "relays:"
assert_contains "bundle template has the relay address" "$tmpl" "- 10.91.0.1"

# A stored config that predates the setting must not win: change the relay and
# bundle again without regenerating the stored config by hand.
node_relay_set dave.mesh use "10.91.0.3"
pki_bundle_client_zip dave.mesh "$outdir" "$keys" "" "" "" >/dev/null 2>&1
tmpl="$(unzip -p "$outdir/dave.mesh-nebula-bundle.zip" config.yml.template)"
assert_contains "a newer setting reaches an older stored config" "$tmpl" "- 10.91.0.3"

# --- 8) fleet ssh --relay (mocked ssh) -------------------------------------
cat > "$SANDBOX/remote.yml" <<'YAML'
pki:
  ca: /etc/nebula/ca.crt
firewall:
  inbound_action: drop
  inbound: []
YAML
printf 'relay:\n  am_relay: false\n  use_relays: true\n  relays:\n    - 10.91.0.1\n' >> "$SANDBOX/remote.yml"
export FAKE_REMOTE_CFG="$SANDBOX/remote.yml"
export SSH_LOG="$SANDBOX/ssh.log" NC_LOG="$SANDBOX/nc.log"
: > "$SSH_LOG"; : > "$NC_LOG"
cat > "$SANDBOX/bin/nc" <<'MOCK'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${NC_LOG:?}"
for a in "$@"; do [[ "$a" == "node4.mesh" ]] && exit 0; done
exit 1
MOCK
chmod +x "$SANDBOX/bin/nc"
cat > "$SANDBOX/bin/ssh" <<'MOCK'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${SSH_LOG:?}"
cmd=""
for a in "$@"; do cmd="$a"; done
case "$cmd" in
    *cat*) cat "${FAKE_REMOTE_CFG:?}"; exit 0 ;;
    *"command -v nebula"*) echo /usr/bin/nebula; exit 0 ;;
    *) exit 0 ;;
esac
MOCK
chmod +x "$SANDBOX/bin/ssh"

out="$(fleet_ssh_cli node4 --relay 10.91.0.2 --dry-run 2>&1)"
assert_eq "fleet ssh relay dry-run exits 0" "$?" "0"
assert_contains "fleet ssh shows the new relay" "$out" "+    - 10.91.0.2"
assert_contains "fleet ssh shows the old relay being removed" "$out" "-    - 10.91.0.1"
assert_contains "fleet ssh announces the upload" "$out" "would upload"
assert_eq "fleet ssh dry-run uploaded nothing" "$(grep -c 'tee' "$SSH_LOG")" "0"

out="$(fleet_ssh_cli node4 --no-relay --dry-run 2>&1)"
assert_contains "fleet ssh --no-relay removes the block" "$out" "-relay:"
out="$(fleet_ssh_cli node4 --relay 1.2.3 --dry-run 2>&1)"; rc=$?
assert_eq "fleet ssh validates the address" "$rc" "2"
assert_contains "fleet ssh names the bad address" "$out" "Not an IP address"
out="$(fleet_ssh_cli node4 2>&1)"; rc=$?
assert_eq "fleet ssh still needs a change" "$rc" "2"
assert_contains "fleet ssh lists the relay options" "$out" "--relay IP"

# --- 9) relay local (this host) --------------------------------------------
cat > "$SANDBOX/local-lh.yml" <<'YAML'
pki:
  ca: /etc/nebula/ca.crt
  cert: /etc/nebula/lh.mesh.crt
lighthouse:
  am_lighthouse: true
  hosts: []
YAML
cat > "$SANDBOX/local-peer.yml" <<'YAML'
pki:
  ca: /etc/nebula/ca.crt
lighthouse:
  am_lighthouse: false
  hosts:
    - "10.91.0.1"
YAML
cat > "$SANDBOX/bin/nebula" <<'MOCK'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${NEBULA_LOG:?}"
exit 0
MOCK
chmod +x "$SANDBOX/bin/nebula"
export NEBULA_LOG="$SANDBOX/nebula.log"; : > "$NEBULA_LOG"
export NEBULA_BIN_PATH="$SANDBOX/bin"
cat > "$SANDBOX/bin/systemctl" <<'MOCK'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${SYSTEMCTL_LOG:?}"
exit 0
MOCK
chmod +x "$SANDBOX/bin/systemctl"
export SYSTEMCTL_LOG="$SANDBOX/systemctl.log"; : > "$SYSTEMCTL_LOG"

out="$(relay_local_cli --nebula-config "$SANDBOX/local-peer.yml" --am-relay on --no-restart 2>&1)"; rc=$?
assert_eq "am_relay is refused on a non-lighthouse" "$rc" "1"
assert_contains "the refusal explains why" "$out" "not a lighthouse"
assert_contains "the refusal names the setting" "$out" "lighthouse.am_lighthouse"
assert_not_contains "the peer config was not changed" "$(cat "$SANDBOX/local-peer.yml")" "am_relay"

out="$(relay_local_cli --nebula-config "$SANDBOX/local-lh.yml" --am-relay on --no-restart 2>&1)"
assert_eq "am_relay on the lighthouse exits 0" "$?" "0"
assert_contains "the diff shows am_relay" "$out" "+  am_relay: true"
assert_contains "the config now has am_relay" "$(cat "$SANDBOX/local-lh.yml")" "am_relay: true"
assert_eq "a backup was written" "$(ls -1 "$SANDBOX"/local-lh.yml.bak.* 2>/dev/null | wc -l | tr -d ' ')" "1"
assert_contains "the config was validated" "$out" "Nebula config is valid"
assert_contains "validation ran nebula -test" "$(cat "$NEBULA_LOG")" "-test"

out="$(relay_local_cli --nebula-config "$SANDBOX/local-lh.yml" --show 2>&1)"
assert_contains "show reports am_relay on" "$out" "am_relay: on"
assert_contains "show reports whether use_relays is set" "$out" "use_relays:"
assert_contains "show reports the lighthouse role" "$out" "am_lighthouse: true"

out="$(relay_local_cli --nebula-config "$SANDBOX/local-lh.yml" --relay 10.91.0.2 2>&1)"
assert_eq "relay local --relay exits 0" "$?" "0"
assert_contains "the relay list is written" "$(cat "$SANDBOX/local-lh.yml")" "- 10.91.0.2"
assert_contains "use_relays is turned on" "$(cat "$SANDBOX/local-lh.yml")" "use_relays: true"
assert_contains "the service restart needed root" "$(cat "$SUDO_LOG")" "systemctl restart nebula.service"

out="$(relay_local_cli --nebula-config "$SANDBOX/local-lh.yml" --use-relays off --no-restart 2>&1)"
assert_contains "use_relays can be turned off" "$(cat "$SANDBOX/local-lh.yml")" "use_relays: false"
assert_not_contains "turning it off drops the relay list" "$(cat "$SANDBOX/local-lh.yml")" "10.91.0.2"

out="$(relay_local_cli --nebula-config "$SANDBOX/local-lh.yml" --relay 10.91.0.2 --dry-run 2>&1)"
assert_contains "relay local --dry-run prints the diff" "$out" "+  use_relays: true"
assert_contains "relay local --dry-run says nothing changed" "$out" "Dry run"
assert_contains "dry run left use_relays off" "$(cat "$SANDBOX/local-lh.yml")" "use_relays: false"

# --- 10) inspection --------------------------------------------------------
out="$(relay_check_config "$SANDBOX/remote.yml" "$keys" 2>&1)"
assert_contains "a known relay is not flagged" "$out" ""

printf 'relay:\n  am_relay: false\n  use_relays: true\n  relays:\n    - 10.99.9.9\n' > "$SANDBOX/unknown.yml"
out="$(relay_check_config "$SANDBOX/unknown.yml" "$keys" 2>&1)"
assert_contains "an unknown relay is flagged" "$out" "not a certificate in"

out="$(firewall_explain "$SANDBOX/remote.yml" 2>&1)"
assert_contains "firewall explain prints the relay state" "$out" "Relay:"
assert_contains "firewall explain shows use_relays" "$out" "use_relays: on"
assert_contains "firewall explain shows the relay address" "$out" "10.91.0.1"

out="$(relay_config_line "$SANDBOX/local-peer.yml")"
assert_contains "a config without the block is reported as such" "$out" "none (no relay: block)"

assert_eq "only the service restart needed root" "$(sudo_count)" "1"

harness_summary
