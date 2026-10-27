#!/usr/bin/env bash
# Test: per-node client configs stored in the certificate workspace.
#   * signing a certificate writes <cert-dir>/<name>.yml (user-owned)
#   * legacy configs/<name>.yml files are migrated next to the certificate
#   * the config carries the detected network settings (lighthouse, port, punchy)
#   * hand edits survive re-signs; --force/regenerate replaces them
#   * `cert bundle` reuses the stored config unless a policy override is given
#   * an explicit firewall choice refreshes the stored config
#   * mobile certificates (no local key) get no client config
#   * CLI: cert config list/show/path/generate, no sudo anywhere
set -uo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/helpers.sh"

TEST_LABEL="node client configs"
harness_init
require_cmd nebula-cert
require_cmd jq

keys="$SANDBOX/keys"
mkdir -p "$keys"
export CERT_DIR_OVERRIDE="$keys"

# --- fixture ----------------------------------------------------------------
CA_NAME="cfg-ca" CERT_DIR="$keys" pki_ca_create >/dev/null 2>&1 \
    || { echo "SKIP: cannot create a CA with the installed nebula-cert"; exit 77; }
SIGN_NAME="node1.mesh" SIGN_IP="10.100.0.5/24" SIGN_GROUPS="home" \
    CERT_DIR="$keys" pki_sign >/dev/null 2>&1
SIGN_NAME="vps.mesh" SIGN_IP="10.100.0.1/24" SIGN_GROUPS="lighthouse,servers" \
    CERT_DIR="$keys" pki_sign >/dev/null 2>&1
mkdir -p "$SANDBOX/device"
nebula-cert keygen -out-key "$SANDBOX/device/phone.key" -out-pub "$SANDBOX/device/phone.pub" >/dev/null 2>&1
SIGN_NAME="phone.mesh" SIGN_IP="10.100.0.9/24" SIGN_GROUPS="mobile" \
    SIGN_IN_PUB="$SANDBOX/device/phone.pub" CERT_DIR="$keys" pki_sign >/dev/null 2>&1

# A realistic local config: the generated node config must inherit these values.
LOCAL="$SANDBOX/local/config.yml"
mkdir -p "$(dirname "$LOCAL")"
cat > "$LOCAL" <<'YAML'
static_host_map:
  "10.100.0.1": ["vps.mesh:4545"]

lighthouse:
  am_lighthouse: false
  interval: 5
  hosts:
    - "10.100.0.1"

punchy:
    punch: true
    respond: true
    delay: 1s

listen:
  host: 0.0.0.0
  port: 0

firewall:
  outbound:
    - port: any
      proto: any
      host: any
  inbound:
    - port: any
      proto: any
      host: any

tun:
    dev: nebula1
YAML
export NEBULA_LOCAL_CONFIG="$LOCAL"

cfg_path="$(pki_node_config_path node1.mesh "$keys")"
assert_eq "config sits next to the certificate" "$cfg_path" "$keys/node1.mesh.yml"

# --- generate at signing time / on demand -----------------------------------
pki_node_config_write_for_fw node1.mesh "$keys" 0 >/dev/null 2>&1
assert_file "node config written" "$cfg_path"
assert_eq "node config is mode 600" "$(stat -c '%a' "$cfg_path")" "600"

cfg="$(cat "$cfg_path")"
assert_contains "pki cert points at the deployed filename" "$cfg" "cert: /etc/nebula/node1.mesh.crt"
assert_contains "pki key points at the deployed filename" "$cfg" "key: /etc/nebula/node1.mesh.key"
assert_contains "static_host_map uses the real endpoint and port" "$cfg" '"10.100.0.1": ["vps.mesh:4545"]'
assert_contains "lighthouse hosts use the overlay IP" "$cfg" '    - "10.100.0.1"'
assert_contains "lighthouse interval is kept" "$cfg" "interval: 5"
assert_contains "punchy respond is kept" "$cfg" "respond: true"
assert_contains "punchy delay is kept" "$cfg" "delay: 1s"
assert_contains "tun device is kept" "$cfg" "dev: nebula1"
assert_eq "no sudo for a user-owned store" "$(sudo_count)" "0"

# --- hand edits survive; force refreshes ------------------------------------
printf '# CUSTOM-EDIT-MARKER\n' >> "$cfg_path"
pki_node_config_write_for_fw node1.mesh "$keys" 0 >/dev/null 2>&1
assert_contains "existing config is kept by default" "$(cat "$cfg_path")" "CUSTOM-EDIT-MARKER"
pki_node_config_write_for_fw node1.mesh "$keys" 1 >/dev/null 2>&1
assert_not_contains "force regenerates the config" "$(cat "$cfg_path")" "CUSTOM-EDIT-MARKER"
latest_backup="$(find "$keys/backups" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort | tail -n1)"
assert_file "overwriting a config leaves a snapshot" "$latest_backup/ACTION.txt"
assert_contains "the snapshot names the node-config action" \
    "$(cat "$latest_backup/ACTION.txt" 2>/dev/null)" "node-config node1.mesh"

# --- legacy configs/<name>.yml is migrated automatically --------------------
rm -f "$cfg_path"
mkdir -p "$keys/configs"
printf '# LEGACY-CONFIG\n' > "$keys/configs/node1.mesh.yml"
pki_node_config_write_for_fw node1.mesh "$keys" 0 >/dev/null 2>&1
assert_file "legacy config moved next to the certificate" "$cfg_path"
assert_no_file "legacy config removed after migration" "$keys/configs/node1.mesh.yml"
assert_contains "migration preserved the stored content" "$(cat "$cfg_path")" "LEGACY-CONFIG"

# --- bundle reuses the stored config ---------------------------------------
printf '# CUSTOM-EDIT-MARKER\n' >> "$cfg_path"
mkdir -p "$SANDBOX/out"
pki_bundle_client_zip node1.mesh "$SANDBOX/out" "$keys" >/dev/null 2>&1
bundle="$SANDBOX/out/node1.mesh-nebula-bundle.zip"
assert_file "bundle created" "$bundle"
if command -v unzip >/dev/null 2>&1; then
    unzip -p "$bundle" config.yml.template > "$SANDBOX/fromzip.yml"
    assert_contains "bundle ships the stored (edited) config" \
        "$(cat "$SANDBOX/fromzip.yml")" "CUSTOM-EDIT-MARKER"
else
    _ok "unzip unavailable - skipping bundle content check"
fi

# An explicit firewall override wins and refreshes the stored copy.
pol="$(node_fw_render_policy permissive)"
mkdir -p "$SANDBOX/out2"
pki_bundle_client_zip node1.mesh "$SANDBOX/out2" "$keys" "$pol" >/dev/null 2>&1
rm -f "$pol"
assert_not_contains "an explicit policy overrides the stored edit" "$(cat "$cfg_path")" "CUSTOM-EDIT-MARKER"
if command -v unzip >/dev/null 2>&1; then
    unzip -p "$SANDBOX/out2/node1.mesh-nebula-bundle.zip" config.yml.template > "$SANDBOX/fromzip2.yml"
    if command -v yq >/dev/null 2>&1; then
        assert_eq "override bundle carries the permissive firewall" \
            "$(yq -r '.firewall.inbound_action' "$SANDBOX/fromzip2.yml" 2>/dev/null)" "accept"
    fi
fi

# --- all/refresh skips mobile certificates ----------------------------------
rm -f "$keys/node1.mesh.yml" "$keys/vps.mesh.yml"
pki_node_config_refresh_all "$keys" 0 >/dev/null 2>&1
assert_file "refresh-all writes the node config" "$keys/node1.mesh.yml"
assert_file "refresh-all writes the lighthouse config" "$keys/vps.mesh.yml"
assert_contains "the lighthouse listens on the advertised port" \
    "$(cat "$keys/vps.mesh.yml")" "port: 4545"
assert_no_file "mobile certificates have no client config" "$keys/phone.mesh.yml"
assert_eq "all rendering stayed unprivileged" "$(sudo_count)" "0"

# --- signing writes a config automatically ----------------------------------
node_fw_set auto.mesh default >/dev/null 2>&1
node_fw_choose_tui() { return 0; }   # keep the fixture from driving that menu
printf 'auto.mesh\nn\n10.100.0.20/24\nlab\nn\n\n' | generate_nebula_cert >/dev/null 2>&1
assert_file "signing a node writes its config" "$keys/auto.mesh.yml"
auto_cfg="$(cat "$keys/auto.mesh.yml")"
assert_contains "the saved firewall choice is embedded" "$auto_cfg" "firewall: {}"

# --- CLI --------------------------------------------------------------------
NM="$REPO_ROOT/nebula-manager"
out="$("$NM" --cert-dir "$keys" cert config list 2>&1)"
assert_contains "config list has a header" "$out" "Node config"
assert_contains "config list shows node1" "$out" "node1.mesh"
assert_contains "config list shows the config path" "$out" "$keys/node1.mesh.yml"
assert_not_contains "config list omits mobile certs" "$out" "phone.mesh"

path="$("$NM" --cert-dir "$keys" cert config path node1 2>/dev/null)"
assert_eq "config path resolves a substring" "$path" "$keys/node1.mesh.yml"

out="$("$NM" --cert-dir "$keys" cert config show node1 2>/dev/null)"
assert_contains "config show prints the YAML" "$out" "pki:"
assert_contains "config show includes the lighthouse" "$out" "vps.mesh:4545"

rm -f "$keys/node1.mesh.yml"
out="$("$NM" --cert-dir "$keys" cert config generate node1 2>&1)"
assert_eq "config generate exits successfully" "$?" "0"
assert_file "config generate recreated the file" "$keys/node1.mesh.yml"

out="$("$NM" --cert-dir "$keys" cert config generate --all --force 2>&1)"
assert_eq "config generate --all exits successfully" "$?" "0"
assert_contains "config generate --all reports its work" "$out" "Node configs:"

if "$NM" --cert-dir "$keys" cert config generate does-not-exist >/dev/null 2>&1; then
    _bad "unknown certificate is rejected"
else
    _ok "unknown certificate is rejected"
fi

out="$("$NM" cert config --help 2>&1)"
assert_contains "CLI help documents list" "$out" "list"
assert_contains "CLI help documents --all" "$out" "--all"
assert_eq "no sudo used anywhere" "$(sudo_count)" "0"

# --- a privileged workspace routes the write through elevate() --------------
priv="$SANDBOX/privkeys"
mkdir -p "$priv"
cp -a "$keys/ca.crt" "$keys/ca.key" "$keys/node1.mesh.crt" "$keys/node1.mesh.key" "$priv/"
elevate_log="$SANDBOX/elevate.log"
: > "$elevate_log"
elevate() { printf 'elevate %s\n' "$*" >> "$elevate_log"; "$@"; }
path_requires_root() { return 0; }   # pretend an /etc/nebula-like workspace
pki_node_config_write_for_fw node1.mesh "$priv" 0 >/dev/null 2>&1
assert_file "privileged workspace gets its config" "$priv/node1.mesh.yml"
assert_contains "privileged write creates the directory via elevate" "$(cat "$elevate_log")" "mkdir -p"
assert_contains "privileged write installs the config via elevate" "$(cat "$elevate_log")" "node1.mesh.yml"
assert_eq "never invoked mocked sudo directly" "$(sudo_count)" "0"

harness_summary
