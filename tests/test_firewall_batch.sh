#!/usr/bin/env bash
# Test: batch firewall for per-node client configs.
#   * `cert firewall --from-group ulno` allows inbound only from that group
#   * lighthouses are skipped by default; --include-lighthouse changes them
#   * a reusable policy pack group-<groups> is created and remembered per node
#   * the generated configs are real YAML with the expected rules
#   * bundles reuse the updated stored config
#   * --firewall permissive / --policy / --dry-run / non-tty refusal
#   * no sudo is used anywhere
set -uo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/helpers.sh"

TEST_LABEL="batch node firewall"
harness_init
require_cmd nebula-cert
require_cmd jq
require_cmd yq

keys="$SANDBOX/keys"
mkdir -p "$keys"
export CERT_DIR_OVERRIDE="$keys"

CA_NAME="fw-ca" CERT_DIR="$keys" pki_ca_create >/dev/null 2>&1 \
    || { echo "SKIP: cannot create a CA with the installed nebula-cert"; exit 77; }
SIGN_NAME="vps.mesh" SIGN_IP="10.90.0.1/24" SIGN_GROUPS="lighthouse,servers" \
    CERT_DIR="$keys" pki_sign >/dev/null 2>&1
SIGN_NAME="a1.mesh" SIGN_IP="10.90.0.2/24" SIGN_GROUPS="ulno" \
    CERT_DIR="$keys" pki_sign >/dev/null 2>&1
SIGN_NAME="a2.mesh" SIGN_IP="10.90.0.3/24" SIGN_GROUPS="ulno,admin" \
    CERT_DIR="$keys" pki_sign >/dev/null 2>&1
SIGN_NAME="b1.mesh" SIGN_IP="10.90.0.4/24" SIGN_GROUPS="students" \
    CERT_DIR="$keys" pki_sign >/dev/null 2>&1

# A readable local config so generated configs have the lighthouse/endpoint.
LOCAL="$SANDBOX/local.yml"
cat > "$LOCAL" <<'YAML'
static_host_map:
  "10.90.0.1": ["vps.example:4545"]
lighthouse:
  am_lighthouse: false
  interval: 5
  hosts:
    - "10.90.0.1"
punchy:
  punch: true
  respond: true
  delay: 1s
listen:
  host: 0.0.0.0
  port: 0
tun:
  dev: nebula1
YAML
export NEBULA_LOCAL_CONFIG="$LOCAL"

NM="$REPO_ROOT/nebula-manager"
sha() { sha256sum "$1" | cut -d' ' -f1; }

# Baseline per-node configs (also proves the lighthouse starts out untouched).
pki_node_config_refresh_all "$keys" 1 >/dev/null 2>&1
vps_before="$(sha "$keys/vps.mesh.yml")"
a1_before="$(sha "$keys/a1.mesh.yml")"

# --- allow inbound only from group ulno -------------------------------------
out="$("$NM" --cert-dir "$keys" cert firewall --from-group ulno --select all --yes 2>&1)"
rc=$?
assert_eq "cert firewall exits successfully" "$rc" "0"
assert_contains "preview names the group policy" "$out" "inbound only from group(s) ulno"
assert_contains "the lighthouse is skipped" "$out" "Skipping lighthouse: vps.mesh"
assert_contains "summary reports the update" "$out" "Firewall updated for 3 certificate(s)"

for n in a1 a2 b1; do
    cfg="$keys/$n.mesh.yml"
    assert_eq "$n: inbound has exactly one rule" "$(yq -r '.firewall.inbound | length' "$cfg")" "1"
    assert_eq "$n: inbound allows group ulno" "$(yq -r '.firewall.inbound[0].group' "$cfg")" "ulno"
    assert_eq "$n: inbound port is any" "$(yq -r '.firewall.inbound[0].port' "$cfg")" "any"
    assert_eq "$n: outbound allows all hosts" "$(yq -r '.firewall.outbound[0].host' "$cfg")" "any"
done
assert_eq "lighthouse config is byte-identical" "$(sha "$keys/vps.mesh.yml")" "$vps_before"
assert_ne "a node config was actually rewritten" "$(sha "$keys/a1.mesh.yml")" "$a1_before"

# The rule is also stored as a reusable policy pack.
pack="$XDG_CONFIG_HOME/nebula-manager/policies/group-ulno.yml"
assert_file "auto policy pack created" "$pack"
assert_eq "pack targets group ulno" "$(yq -r '.groups | join(",")' "$pack")" "ulno"
assert_eq "pack carries the inbound group rule" "$(yq -r '.firewall.inbound[0].group' "$pack")" "ulno"

# The per-node preference is remembered for bundles / future refreshes.
state="$XDG_CONFIG_HOME/nebula-manager/node-firewall.tsv"
assert_contains "a1 remembers the pack" "$(cat "$state")" $'a1.mesh\tpack\tgroup-ulno'
assert_contains "a2 remembers the pack" "$(cat "$state")" $'a2.mesh\tpack\tgroup-ulno'

# --- bundles reuse the updated config --------------------------------------
mkdir -p "$SANDBOX/out"
pki_bundle_client_zip a1.mesh "$SANDBOX/out" "$keys" >/dev/null 2>&1
if command -v unzip >/dev/null 2>&1; then
    unzip -p "$SANDBOX/out/a1.mesh-nebula-bundle.zip" config.yml.template > "$SANDBOX/bundle.yml"
    assert_eq "bundle ships the group firewall" \
        "$(yq -r '.firewall.inbound[0].group' "$SANDBOX/bundle.yml")" "ulno"
else
    _ok "unzip unavailable - skipping bundle content check"
fi

# --- lighthouse can be included explicitly ---------------------------------
"$NM" --cert-dir "$keys" cert firewall --from-group ulno \
    --select cert:vps.mesh --include-lighthouse --yes >/dev/null 2>&1
assert_eq "included lighthouse gets the group rule" \
    "$(yq -r '.firewall.inbound[0].group' "$keys/vps.mesh.yml")" "ulno"

# --- other modes ------------------------------------------------------------
"$NM" --cert-dir "$keys" cert firewall --firewall permissive \
    --select group:students --yes >/dev/null 2>&1
assert_eq "permissive sets inbound_action" \
    "$(yq -r '.firewall.inbound_action' "$keys/b1.mesh.yml")" "accept"

"$NM" --cert-dir "$keys" cert firewall --policy group-ulno \
    --select cert:a1.mesh --yes >/dev/null 2>&1
assert_eq "explicit policy applies" \
    "$(yq -r '.firewall.inbound[0].group' "$keys/a1.mesh.yml")" "ulno"

# --- dry run changes nothing ------------------------------------------------
a1_dry="$(sha "$keys/a1.mesh.yml")"
out="$("$NM" --cert-dir "$keys" cert firewall --firewall permissive --select all --dry-run 2>&1)"
assert_contains "dry run announces itself" "$out" "Dry run: no config was changed."
assert_eq "dry run left the config alone" "$(sha "$keys/a1.mesh.yml")" "$a1_dry"

# --- non-interactive refusal ------------------------------------------------
if "$NM" --cert-dir "$keys" cert firewall --from-group admin --select all </dev/null >/dev/null 2>&1; then
    _bad "refuses without --yes on a non-tty"
else
    _ok "refuses without --yes on a non-tty"
fi
assert_eq "refused run left the config alone" "$(sha "$keys/a1.mesh.yml")" "$a1_dry"

# --- multiple groups must become one rule each (Nebula ANDs groups:) --------
"$NM" --cert-dir "$keys" cert firewall --from-group ulno,lighthouse \
    --select cert:a2.mesh --include-lighthouse --yes >/dev/null 2>&1
cfg="$keys/a2.mesh.yml"
assert_eq "multi-group: inbound has exactly two rules" \
    "$(yq -r '.firewall.inbound | length' "$cfg")" "2"
assert_eq "multi-group: first rule allows ulno" \
    "$(yq -r '.firewall.inbound[0].group' "$cfg")" "ulno"
assert_eq "multi-group: second rule allows lighthouse" \
    "$(yq -r '.firewall.inbound[1].group' "$cfg")" "lighthouse"
assert_eq "multi-group: no AND groups list is emitted" \
    "$(yq -r '.firewall.inbound[0].groups' "$cfg")" "null"
mpack="$XDG_CONFIG_HOME/nebula-manager/policies/group-ulno-lighthouse.yml"
assert_file "multi-group policy pack created" "$mpack"

assert_eq "no sudo used anywhere" "$(sudo_count)" "0"

harness_summary
