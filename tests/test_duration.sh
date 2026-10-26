#!/usr/bin/env bash
# Test: human-friendly certificate durations.
#   * 10y / 365d / 4w / 720h / 720 all normalize to hours
#   * invalid, zero and fractional values are rejected
#   * CA creation accepts 10y
#   * client signing accepts 1y
#   * recreating a CA in place reuses its name and duration as defaults
set -uo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/helpers.sh"

TEST_LABEL="duration parsing"
harness_init
require_cmd nebula-cert
require_cmd jq

# --- normalization -----------------------------------------------------------
assert_eq "years become hours"      "$(_normalize_duration_hours 10y)"  "87600h"
assert_eq "uppercase years"         "$(_normalize_duration_hours 10Y)"  "87600h"
assert_eq "days become hours"       "$(_normalize_duration_hours 365d)" "8760h"
assert_eq "weeks become hours"      "$(_normalize_duration_hours 4w)"   "672h"
assert_eq "explicit hours"          "$(_normalize_duration_hours 720h)" "720h"
assert_eq "bare number is hours"    "$(_normalize_duration_hours 720)"  "720h"
_normalize_duration_hours 0 >/dev/null;       assert_eq "zero rejected"       "$?" "1"
_normalize_duration_hours 0h >/dev/null;      assert_eq "zero hours rejected" "$?" "1"
_normalize_duration_hours 1.5y >/dev/null;    assert_eq "fraction rejected"   "$?" "1"
_normalize_duration_hours nonsense >/dev/null; assert_eq "garbage rejected"    "$?" "1"
_normalize_duration_hours "" >/dev/null;      assert_eq "empty rejected"      "$?" "1"

# --- CA creation with a human duration --------------------------------------
ca_keys="$SANDBOX/ca-keys"
mkdir -p "$ca_keys"
printf 'TestCA\n10y\n\n\n\n\n' | CERT_DIR_OVERRIDE="$ca_keys" generate_nebula_ca >/dev/null 2>&1
assert_file "CA created with 10y" "$ca_keys/ca.crt"
ca_days="$(pki_cert_days_left "$ca_keys/ca.crt")"
if (( ca_days >= 3640 && ca_days <= 3660 )); then
    _ok "CA duration is ~10 years (${ca_days} days)"
else
    _bad "CA duration is ~10 years" "got ${ca_days} days"
fi

# A failed CA run must never remove the existing CA.
ca_before="$(sha256sum "$ca_keys/ca.crt" "$ca_keys/ca.key")"
CA_NAME="TestCA" CA_DURATION="nonsense" CERT_DIR="$ca_keys" pki_ca_create >/dev/null 2>&1; rc=$?
assert_ne "invalid CA duration is rejected" "$rc" "0"
assert_eq "invalid CA duration leaves the old CA intact" "$(sha256sum "$ca_keys/ca.crt" "$ca_keys/ca.key")" "$ca_before"

# Simulate nebula-cert failing after the duration check; the old CA must survive.
real_nc="$(command -v nebula-cert)"
fakebin="$SANDBOX/fakebin"; mkdir -p "$fakebin"
{
    printf '#!/usr/bin/env bash\n'
    printf 'if [[ "$1" == "ca" ]]; then exit 1; fi\n'
    printf 'exec %q "$@"\n' "$real_nc"
} > "$fakebin/nebula-cert"
chmod +x "$fakebin/nebula-cert"
NEBULA_BIN_PATH="$fakebin" CA_NAME="TestCA" CA_DURATION="87600h" CERT_DIR="$ca_keys" pki_ca_create >/dev/null 2>&1; rc=$?
assert_ne "failed nebula-cert ca returns nonzero" "$rc" "0"
assert_eq "failed nebula-cert ca leaves the old CA intact" "$(sha256sum "$ca_keys/ca.crt" "$ca_keys/ca.key")" "$ca_before"

# --- client certificate with a human duration --------------------------------
keys="$SANDBOX/client-keys"
mkdir -p "$keys"
CA_NAME="dur-ca" CERT_DIR="$keys" pki_ca_create >/dev/null 2>&1
printf 'one.mesh.demo\nn\n10.99.0.2/24\n\nn\n1y\n' | CERT_DIR_OVERRIDE="$keys" generate_nebula_cert >/dev/null 2>&1
assert_file "client cert created with 1y" "$keys/one.mesh.demo.crt"
client_days="$(pki_cert_days_left "$keys/one.mesh.demo.crt")"
if (( client_days >= 364 && client_days <= 366 )); then
    _ok "client duration is ~1 year (${client_days} days)"
else
    _bad "client duration is ~1 year" "got ${client_days} days"
fi

# Invalid input re-prompts instead of passing it to nebula-cert.
printf 'two.mesh.demo\nn\n10.99.0.3/24\n\nn\nnonsense\n1y\n' | CERT_DIR_OVERRIDE="$keys" generate_nebula_cert >/dev/null 2>&1
assert_file "invalid duration re-prompts and then succeeds" "$keys/two.mesh.demo.crt"

# --- recreating a CA reuses its name/duration as defaults --------------------
printf 'y\n\n\n\n\n\n\n' | CERT_DIR_OVERRIDE="$ca_keys" generate_nebula_ca >/dev/null 2>&1
assert_file "CA recreated with defaults" "$ca_keys/ca.crt"
json="$(nebula_cert_json "$(dirname "$(pki_cert_bin)")" "$ca_keys/ca.crt")"
assert_eq "CA name default reused" "$(jq -r '.details.name' <<<"$json")" "TestCA"
ca_days="$(pki_cert_days_left "$ca_keys/ca.crt")"
if (( ca_days >= 3640 && ca_days <= 3660 )); then
    _ok "CA duration default reused (${ca_days} days)"
else
    _bad "CA duration default reused" "got ${ca_days} days"
fi

# --- defaults from the newest backup when the workspace CA is missing --------
# Simulates the old failure mode: ca.crt/ca.key only exist in a backup folder.
snapdir="$ca_keys/backups/20990101-000000-000-ca-create-TestCA"
mkdir -p "$snapdir"
cp -p "$ca_keys/ca.crt" "$snapdir/ca.crt"
cp -p "$ca_keys/ca.key" "$snapdir/ca.key"
touch "$snapdir/ca.crt"
rm -f "$ca_keys/ca.crt" "$ca_keys/ca.key"
printf '\n\n\n\n\n\n' | CERT_DIR_OVERRIDE="$ca_keys" generate_nebula_ca >/dev/null 2>&1
assert_file "CA recreated from backup defaults" "$ca_keys/ca.crt"
json="$(nebula_cert_json "$(dirname "$(pki_cert_bin)")" "$ca_keys/ca.crt")"
assert_eq "backup CA name reused" "$(jq -r '.details.name' <<<"$json")" "TestCA"
ca_days="$(pki_cert_days_left "$ca_keys/ca.crt")"
if (( ca_days >= 3640 && ca_days <= 3660 )); then
    _ok "backup CA duration reused (${ca_days} days)"
else
    _bad "backup CA duration reused" "got ${ca_days} days"
fi

harness_summary
