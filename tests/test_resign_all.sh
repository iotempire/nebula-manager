#!/usr/bin/env bash
# Test: re-sign every certificate after a CA rotation.
#   * dry-run previews the plan and changes nothing
#   * a non-interactive run refuses without --yes
#   * certificates signed by an old CA are re-issued by the current CA
#   * --keep-keys preserves private keys and public keys
#   * the default mode rotates keys for certificates that have a local .key
#   * device certificates (no local .key) keep their device-generated key
#   * --skip-device leaves device certificates untouched
#   * the certificate store is snapshotted before mutation
#   * no sudo is required in a user-owned store
#   * the CLI (cert resign-all) mirrors the library helper
set -uo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/helpers.sh"

TEST_LABEL="resign-all"
harness_init
require_cmd nebula-cert
require_cmd jq

keys="$SANDBOX/keys"
export CERT_DIR_OVERRIDE="$keys"
cert_bin_dir="$(dirname "$(pki_cert_bin)")"

cert_json()  { nebula_cert_json "$cert_bin_dir" "$1"; }
ca_fp()      { cert_json "$1" | jq -r '.fingerprint'; }
issuer_of()  { cert_json "$1" | jq -r '.details.issuer'; }
pub_of()     { cert_json "$1" | jq -r '.publicKey'; }
networks_of(){ cert_json "$1" | jq -r '(.details.networks // []) | join(",")'; }
subnets_of() { cert_json "$1" | jq -r '(.details.unsafeNetworks // []) | join(",")'; }
groups_of()  { cert_json "$1" | jq -r '(.details.groups // []) | join(",")'; }
sha()        { sha256sum "$1" | cut -d' ' -f1; }
backup_count() {
    [[ -d "$keys/backups" ]] || { echo 0; return; }
    find "$keys/backups" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' '
}

# --- fixture: CA #1 + three certificates ------------------------------------
CA_NAME="CA-ONE" CERT_DIR="$keys" pki_ca_create >/dev/null 2>&1 \
    || { echo "SKIP: cannot create a CA with the installed nebula-cert"; exit 77; }
ca1_fp="$(ca_fp "$keys/ca.crt")"

SIGN_NAME="node1.mesh" SIGN_IP="10.42.0.2/24" SIGN_GROUPS="web" \
    CERT_DIR="$keys" pki_sign >/dev/null 2>&1
SIGN_NAME="node2.mesh" SIGN_IP="10.42.0.3/24" SIGN_GROUPS="db" \
    SIGN_SUBNETS="192.168.50.0/24" CERT_DIR="$keys" pki_sign >/dev/null 2>&1
# Device certificate: the private key stays on the device, no local .key.
mkdir -p "$SANDBOX/device"
nebula-cert keygen -out-key "$SANDBOX/device/phone.key" \
    -out-pub "$SANDBOX/device/phone.pub" >/dev/null 2>&1
SIGN_NAME="phone.mesh" SIGN_IP="10.42.0.4/24" SIGN_GROUPS="mobile" \
    SIGN_IN_PUB="$SANDBOX/device/phone.pub" CERT_DIR="$keys" pki_sign >/dev/null 2>&1

assert_file "fixture node1.crt"  "$keys/node1.mesh.crt"
assert_file "fixture node2.crt"  "$keys/node2.mesh.crt"
assert_file "fixture phone.crt"  "$keys/phone.mesh.crt"
assert_no_file "device certificate has no local key" "$keys/phone.mesh.key"
assert_eq "node1 is signed by CA #1" "$(issuer_of "$keys/node1.mesh.crt")" "$ca1_fp"
assert_eq "phone is signed by CA #1" "$(issuer_of "$keys/phone.mesh.crt")" "$ca1_fp"

node1_crt_before="$(sha "$keys/node1.mesh.crt")"
node1_key_before="$(sha "$keys/node1.mesh.key")"
node1_pub_before="$(pub_of "$keys/node1.mesh.crt")"
node2_key_before="$(sha "$keys/node2.mesh.key")"
phone_crt_before="$(sha "$keys/phone.mesh.crt")"
phone_pub_before="$(pub_of "$keys/phone.mesh.crt")"
backups_before="$(backup_count)"

# --- dry run ----------------------------------------------------------------
out="$(PKI_RESIGN_DRY=1 PKI_RESIGN_YES=1 pki_resign_all "$keys" 2>&1)"; rc=$?
assert_eq "dry run exits successfully" "$rc" "0"
assert_contains "preview lists node1" "$out" "node1.mesh"
assert_contains "preview lists node2" "$out" "node2.mesh"
assert_contains "preview lists the device certificate" "$out" "phone.mesh"
assert_contains "preview announces new keys for local certs" "$out" "new key"
assert_contains "preview keeps the device key" "$out" "Device certs (no local key; device key kept): phone.mesh"
assert_contains "dry run says nothing changed" "$out" "Dry run: nothing changed."
assert_eq "dry run left node1 certificate alone"   "$(sha "$keys/node1.mesh.crt")" "$node1_crt_before"
assert_eq "dry run left node1 key alone"           "$(sha "$keys/node1.mesh.key")" "$node1_key_before"
assert_eq "dry run left the device certificate alone" "$(sha "$keys/phone.mesh.crt")" "$phone_crt_before"
assert_eq "dry run created no backup"              "$(backup_count)" "$backups_before"

# --- non-interactive refusal ------------------------------------------------
set +e
out="$(pki_resign_all "$keys" </dev/null 2>&1)"; rc=$?
assert_eq "refuses without --yes on a non-tty" "$rc" "2"
assert_contains "refusal explains itself" "$out" "Refusing to re-sign all certificates without --yes"
assert_eq "refused run left node1 alone" "$(sha "$keys/node1.mesh.crt")" "$node1_crt_before"
assert_eq "refused run created no backup" "$(backup_count)" "$backups_before"

# --- rotate the CA ----------------------------------------------------------
CA_NAME="CA-TWO" CERT_DIR="$SANDBOX/newca" pki_ca_create >/dev/null 2>&1 \
    || { echo "SKIP: cannot create the replacement CA"; exit 77; }
cp "$SANDBOX/newca/ca.crt" "$keys/ca.crt"
cp "$SANDBOX/newca/ca.key" "$keys/ca.key"
ca2_fp="$(ca_fp "$keys/ca.crt")"
assert_ne "the CA really changed" "$ca2_fp" "$ca1_fp"

if nebula-cert verify -ca "$keys/ca.crt" -crt "$keys/node1.mesh.crt" >/dev/null 2>&1; then
    _bad "old certificate no longer verifies against the new CA"
else
    _ok "old certificate no longer verifies against the new CA"
fi

# --- keep existing keys -----------------------------------------------------
out="$(PKI_RESIGN_YES=1 PKI_RESIGN_KEEP_KEYS=1 pki_resign_all "$keys" 2>&1)"; rc=$?
assert_eq "--keep-keys exits successfully" "$rc" "0"
assert_contains "--keep-keys reports the re-sign" "$out" "Re-signed 3 certificate(s); 0 failed."

assert_eq "node1 now signed by CA #2"  "$(issuer_of "$keys/node1.mesh.crt")" "$ca2_fp"
assert_eq "node2 now signed by CA #2"  "$(issuer_of "$keys/node2.mesh.crt")" "$ca2_fp"
assert_eq "phone now signed by CA #2"  "$(issuer_of "$keys/phone.mesh.crt")" "$ca2_fp"

assert_eq "--keep-keys preserves node1 key bytes" "$(sha "$keys/node1.mesh.key")" "$node1_key_before"
assert_eq "--keep-keys preserves node1 public key" "$(pub_of "$keys/node1.mesh.crt")" "$node1_pub_before"
assert_eq "--keep-keys preserves node2 key bytes" "$(sha "$keys/node2.mesh.key")" "$node2_key_before"
assert_eq "device public key is preserved"        "$(pub_of "$keys/phone.mesh.crt")" "$phone_pub_before"

assert_eq "node1 name/IP preserved"   "$(networks_of "$keys/node1.mesh.crt")" "10.42.0.2/24"
assert_eq "node1 group preserved"     "$(groups_of "$keys/node1.mesh.crt")" "web"
assert_eq "node2 routed subnet preserved" "$(subnets_of "$keys/node2.mesh.crt")" "192.168.50.0/24"
assert_eq "node2 group preserved"     "$(groups_of "$keys/node2.mesh.crt")" "db"

for c in node1 node2 phone; do
    if nebula-cert verify -ca "$keys/ca.crt" -crt "$keys/$c.mesh.crt" >/dev/null 2>&1; then
        _ok "$c verifies against the new CA"
    else
        _bad "$c verifies against the new CA"
    fi
done

backups_after_keep="$(backup_count)"
if (( backups_after_keep > backups_before )); then
    _ok "a backup snapshot was recorded before the re-sign"
else
    _bad "a backup snapshot was recorded before the re-sign" \
        "before=$backups_before after=$backups_after_keep"
fi
latest_backup="$(find "$keys/backups" -mindepth 1 -maxdepth 1 -type d | sort | tail -n1)"
assert_file "the snapshot carries an action log" "$latest_backup/ACTION.txt"
assert_contains "the action log names resign-all" "$(cat "$latest_backup/ACTION.txt")" "reason: resign-all"
assert_file "the snapshot keeps the old node1 certificate" "$latest_backup/node1.mesh.crt"
assert_eq "the snapshot keeps the old node1 certificate bytes" \
    "$(sha "$latest_backup/node1.mesh.crt")" "$node1_crt_before"

# --- default mode rotates keys ---------------------------------------------
node1_key_kept="$(sha "$keys/node1.mesh.key")"
node1_pub_kept="$(pub_of "$keys/node1.mesh.crt")"
out="$(PKI_RESIGN_YES=1 pki_resign_all "$keys" 2>&1)"; rc=$?
assert_eq "default re-sign exits successfully" "$rc" "0"
assert_contains "default re-sign reports the plan" "$out" "new key"
assert_ne "default mode writes a new private key" "$(sha "$keys/node1.mesh.key")" "$node1_key_kept"
assert_ne "default mode certifies the new public key" "$(pub_of "$keys/node1.mesh.crt")" "$node1_pub_kept"
assert_eq "default mode still signs with CA #2" "$(issuer_of "$keys/node1.mesh.crt")" "$ca2_fp"
assert_eq "device key is not regenerated locally" "$(pub_of "$keys/phone.mesh.crt")" "$phone_pub_before"
assert_eq "device certificate still has no local key" "$( [[ -f "$keys/phone.mesh.key" ]] && echo yes || echo no )" "no"

# --- skip device certificates ----------------------------------------------
phone_crt_before_skip="$(sha "$keys/phone.mesh.crt")"
node2_crt_before_skip="$(sha "$keys/node2.mesh.crt")"
out="$(PKI_RESIGN_YES=1 PKI_RESIGN_SKIP_DEVICE=1 pki_resign_all "$keys" 2>&1)"; rc=$?
assert_eq "--skip-device exits successfully" "$rc" "0"
assert_contains "--skip-device lists the skipped certificate" "$out" "Skipped (no local key): phone.mesh"
assert_eq "--skip-device left the device certificate untouched" \
    "$(sha "$keys/phone.mesh.crt")" "$phone_crt_before_skip"
assert_ne "--skip-device still re-signed local certificates" \
    "$(sha "$keys/node2.mesh.crt")" "$node2_crt_before_skip"

# --- least privilege --------------------------------------------------------
assert_eq "no sudo used for user-owned PKI" "$(sudo_count)" "0"

# --- CLI --------------------------------------------------------------------
out="$(bash "$REPO_ROOT/nebula-manager" cert resign-all --cert-dir "$keys" \
    --yes --dry-run 2>&1)"; rc=$?
assert_eq "CLI dry run exits successfully" "$rc" "0"
assert_contains "CLI dry run previews the plan" "$out" "Dry run: nothing changed."

phone_crt_before_cli="$(sha "$keys/phone.mesh.crt")"
set +e
bash "$REPO_ROOT/nebula-manager" cert resign-all --cert-dir "$keys" </dev/null >/dev/null 2>&1
cli_rc=$?
assert_eq "CLI refuses without --yes on a non-tty" "$cli_rc" "2"
assert_eq "CLI refusal changed nothing" "$(sha "$keys/phone.mesh.crt")" "$phone_crt_before_cli"

out="$(bash "$REPO_ROOT/nebula-manager" cert resign-all --cert-dir "$keys" \
    --yes --skip-device 2>&1)"; rc=$?
assert_eq "CLI re-sign exits successfully" "$rc" "0"
assert_contains "CLI reports the re-sign" "$out" "Re-signed"
assert_eq "CLI still used no sudo" "$(sudo_count)" "0"

out="$(bash "$REPO_ROOT/nebula-manager" cert resign-all --help 2>&1)"
assert_contains "CLI help documents --keep-keys" "$out" "--keep-keys"
assert_contains "CLI help documents --skip-device" "$out" "--skip-device"
assert_contains "CLI help documents --dry-run" "$out" "--dry-run"

harness_summary
