#!/usr/bin/env bash
# Test: fleet mass deployment over croc.
#   * the selection is turned into self-contained bundles
#   * one `CROC_SECRET=CODE croc send FILE` process per bundle is started
#   * the code table and per-student commands are printed
#   * --dry-run creates bundles but starts nothing
#   * policy packs and the bundle README are wired correctly
set -uo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/helpers.sh"

TEST_LABEL="fleet croc deployment"
harness_init
require_cmd nebula-cert
require_cmd jq
require_cmd yq

keys="$SANDBOX/keys"
export CERT_DIR_OVERRIDE="$keys"
CA_NAME="test-ca" CERT_DIR="$keys" pki_ca_create >/dev/null 2>&1 || {
    echo "SKIP: cannot create a CA with the installed nebula-cert"; exit 77; }
SIGN_NAME="alice.mesh" SIGN_IP="10.91.0.2/24" SIGN_GROUPS="students,g1" \
    CERT_DIR="$keys" pki_sign >/dev/null 2>&1
SIGN_NAME="bob.mesh" SIGN_IP="10.91.0.3/24" SIGN_GROUPS="students,g1" \
    CERT_DIR="$keys" pki_sign >/dev/null 2>&1
# A mobile-style cert (no local key) must be skipped, not fail the run.
SIGN_NAME="phone.mesh" SIGN_IP="10.91.0.4/24" SIGN_GROUPS="students,mobile" \
    CERT_DIR="$keys" pki_sign >/dev/null 2>&1
rm -f "$keys/phone.mesh.key"

mkdir -p "$(policy_dir)"
cat > "$(policy_dir)/students.yml" <<'YAML'
name: students
groups: [students]
firewall:
  inbound_action: drop
  inbound:
    - port: any
      proto: any
      groups: [students]
YAML

# Mock croc: record the invocation and exit immediately.
cat > "$SANDBOX/bin/croc" <<'MOCK'
#!/usr/bin/env bash
printf 'CROC_SECRET=%s %s\n' "${CROC_SECRET:-}" "$*" >> "${CROC_LOG:?}"
if [[ "${CROC_USAGE_NOTICE:-0}" == 1 ]]; then
    echo "On UNIX systems, to send with a custom code phrase,"
    echo "you need to set the environmental variable CROC_SECRET:"
fi
if [[ "${CROC_RELAY_FAIL:-0}" == 1 ]]; then
    echo "relay connection failed: could not connect to 1.getcroc.com:9009: relay admission rejected" >&2
fi
exit 0
MOCK
chmod +x "$SANDBOX/bin/croc"
export CROC_LOG="$SANDBOX/croc.log"; : > "$CROC_LOG"

out_dir="$SANDBOX/fleet"
out="$(fleet_croc_cli --select group:students --policy students --out "$out_dir" --dry-run 2>&1)"
assert_eq "dry run exits 0" "$?" "0"
assert_contains "dry run lists the nodes" "$out" "alice.mesh"
assert_contains "dry run lists bob"       "$out" "bob.mesh"
assert_contains "dry run prints codes"    "$out" "croc "
assert_empty_file "dry run starts no transfers" "$CROC_LOG"
assert_contains "mobile cert is skipped" "$out" "no local private key"
assert_file "alice bundle created" "$out_dir/alice.mesh-nebula-bundle.zip"
assert_file "bob bundle created"   "$out_dir/bob.mesh-nebula-bundle.zip"
assert_no_file "no bundle for the mobile cert" "$out_dir/phone.mesh-nebula-bundle.zip"

# The bundle README contains the student's code and the policy is embedded.
require_cmd unzip
code_a="$(awk '/alice/ {for (i=1;i<=NF;i++) if ($i ~ /^CROC_SECRET=/) { sub(/^CROC_SECRET=/,"",$i); print $i }}' "$CROC_LOG" | head -n1)"
assert_eq "dry run did not call croc" "$code_a" ""
readme="$(unzip -p "$out_dir/alice.mesh-nebula-bundle.zip" README.txt)"
assert_contains "README has the croc client line" "$readme" "croc --yes"
assert_contains "README mentions the students pack" "$readme" "policy pack 'students'"
tmpl="$(unzip -p "$out_dir/alice.mesh-nebula-bundle.zip" config.yml.template)"
assert_contains "client template uses the pack firewall" "$tmpl" "inbound_action: drop"

# Real run: one croc process per bundle (the mock exits immediately).
out="$(fleet_croc_cli --select group:students --policy students --out "$out_dir" 2>&1)"
assert_eq "croc run exits 0" "$?" "0"
assert_eq "one croc send per bundle" "$(grep -c 'CROC_SECRET=.* --yes send ' "$CROC_LOG")" "2"
assert_eq "sender does not use the rejected --code flag" "$(grep -c -- '--code' "$CROC_LOG")" "0"
assert_contains "table lists alice" "$out" "alice.mesh"
assert_contains "table lists bob"   "$out" "bob.mesh"
assert_contains "delivery is reported" "$out" "Delivered alice.mesh"
assert_contains "delivery is reported for bob" "$out" "Delivered bob.mesh"

# Codes are in the invocation and are unique.
mapfile -t codes < <(awk '{for (i=1;i<=NF;i++) if ($i ~ /^CROC_SECRET=/) { sub(/^CROC_SECRET=/,"",$i); print $i }}' "$CROC_LOG")
assert_eq "two codes were generated" "${#codes[@]}" "2"
assert_ne "codes are unique" "${codes[0]}" "${codes[1]}"
assert_eq "codes are long enough for croc" "$([[ ${#codes[0]} -ge 6 ]] && echo yes)" "yes"

# Regression: croc 11.x prints a usage notice for `send --code` and exits 0;
# that must be reported as a setup error, not a delivery.
: > "$CROC_LOG"
out="$(CROC_USAGE_NOTICE=1 fleet_croc_cli --select cert:alice.mesh --out "$SANDBOX/fleet-guard" 2>&1)"
assert_eq "usage-notice run exits 0" "$?" "0"
assert_not_contains "usage notice is not a delivery" "$out" "Delivered alice.mesh"
assert_contains "usage notice is diagnosed" "$out" "rejected the custom code"

assert_eq "no sudo used" "$(sudo_count)" "0"

# --- own relay ---------------------------------------------------------------
: > "$CROC_LOG"
out="$(fleet_croc_cli --select cert:alice.mesh --relay 10.9.9.9:9009 \
    --out "$SANDBOX/fleet-relay" 2>&1)"
assert_contains "sender invokes the relay" "$(cat "$CROC_LOG")" "--relay 10.9.9.9:9009"
assert_contains "printed receiver command carries the relay" "$out" "croc --relay 10.9.9.9:9009"
assert_contains "relay is announced" "$out" "Relay: 10.9.9.9:9009"

# A relay that refuses (croc exits 0 anyway) must not be reported as delivered.
: > "$CROC_LOG"
out="$(CROC_RELAY_FAIL=1 fleet_croc_cli --select cert:alice.mesh \
    --out "$SANDBOX/fleet-relayfail" 2>&1)"
assert_not_contains "relay refusal is not a delivery" "$out" "Delivered alice.mesh"
assert_contains "relay refusal is diagnosed" "$out" "Relay refused alice.mesh"
assert_contains "relay refusal suggests --relay" "$out" "--relay HOST:PORT"

# --- LAN-only mode -----------------------------------------------------------
: > "$CROC_LOG"
out="$(fleet_croc_cli --select cert:alice.mesh --local --out "$SANDBOX/fleet-local" 2>&1)"
assert_contains "sender uses --local" "$(cat "$CROC_LOG")" "--local"
assert_contains "printed receiver command uses --local" "$out" "croc --local"
assert_contains "LAN-only mode is announced" "$out" "LAN only (--local)"
assert_contains "HTTP fallback is suggested" "$out" "python3 -m http.server"

# Regression: bundle creation redirects stderr to a log. An unreadable local
# Nebula config must not sit on an invisible [y/N] prompt (looked like a hang).
sec="$SANDBOX/service-owned.yml"
printf 'tun:\n  dev: nebula1\n' > "$sec"
chmod 000 "$sec"
if [[ -r "$sec" ]]; then
    echo "SKIP: cannot make a file unreadable in this environment"
else
    out="$(NEBULA_NO_PROMPT=1 timeout 5 bash -c "source '$REPO_ROOT/lib/ui.sh'; source '$REPO_ROOT/lib/system.sh'; read_nebula_config '$sec'" 2>&1)"; rc=$?
    assert_ne "unreadable config fails fast instead of prompting" "$rc" "124"
    assert_eq "unreadable config reports failure" "$rc" "1"
fi
chmod 644 "$sec"

harness_summary
