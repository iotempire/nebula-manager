#!/usr/bin/env bash
# Test: fleet bundle preparation + croc sharing (one receiver at a time).
#   * `fleet bundle` renders bundles and transfers nothing
#   * `fleet croc` streams one transfer per bundle, one after the other
#   * croc's own three-word code is used (never a custom --code/CROC_SECRET)
#   * --dir / --bundle share existing archives without re-rendering
#   * a relay refusal (croc exits 0) and an interrupted transfer are reported
set -uo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/helpers.sh"

TEST_LABEL="fleet: bundles + croc (sequential)"
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

# Mock croc: records the call, prints its own three-word code (like the real one)
# and exits. CROC_RELAY_FAIL/CROC_EXIT simulate the field failures.
cat > "$SANDBOX/bin/croc" <<'MOCK'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${CROC_LOG:?}"
n=0
[[ -f "${CROC_COUNT:?}" ]] && n="$(cat "$CROC_COUNT")"
n=$((n + 1)); printf '%s' "$n" > "$CROC_COUNT"
if [[ "${CROC_SILENT:-0}" == 1 ]]; then exit 0; fi
echo "Sending 'bundle' (12 kB)"
echo "Code is: test-word-$n"
if [[ "${CROC_RELAY_FAIL:-0}" == 1 ]]; then
    echo "could not connect to 1.getcroc.com:9009: relay admission rejected" >&2
    exit 0    # croc really exits 0 here - the manager must not call that a delivery
fi
if [[ "${CROC_EXIT:-0}" != 0 ]]; then exit "${CROC_EXIT}"; fi
echo "Received"
exit 0
MOCK
chmod +x "$SANDBOX/bin/croc"
export CROC_LOG="$SANDBOX/croc.log" CROC_COUNT="$SANDBOX/croc.count"
: > "$CROC_LOG"; : > "$CROC_COUNT"

# --- fleet bundle: render only ------------------------------------------------
out_dir="$SANDBOX/fleet"
out="$(fleet_bundle_cli --select group:students --policy students --out "$out_dir" 2>&1)"
assert_eq "bundle exits 0" "$?" "0"
assert_contains "bundle lists the nodes" "$out" "alice.mesh"
assert_contains "bundle lists bob" "$out" "bob.mesh"
assert_contains "bundle suggests fleet serve" "$out" "fleet serve --dir"
assert_contains "bundle suggests fleet croc" "$out" "fleet croc --dir"
assert_contains "bundle says nothing was transferred" "$out" "Bundles ready"
assert_empty_file "bundle starts no transfer" "$CROC_LOG"
assert_contains "mobile cert is skipped" "$out" "no local private key"
assert_file "alice bundle created" "$out_dir/alice.mesh-nebula-bundle.zip"
assert_file "bob bundle created" "$out_dir/bob.mesh-nebula-bundle.zip"
assert_no_file "no bundle for the mobile cert" "$out_dir/phone.mesh-nebula-bundle.zip"

# The policy is embedded and the README has no hard-coded (wrong) croc code.
require_cmd unzip
readme="$(unzip -p "$out_dir/alice.mesh-nebula-bundle.zip" README.txt)"
assert_contains "README has the croc client line" "$readme" "croc --yes"
assert_contains "README mentions the policy pack" "$readme" "policy pack 'students'"
assert_contains "README keeps the code placeholder" "$readme" "CROC-CODE"
tmpl="$(unzip -p "$out_dir/alice.mesh-nebula-bundle.zip" config.yml.template)"
assert_contains "client template uses the pack firewall" "$tmpl" "inbound_action: drop"

# --- croc --dry-run -----------------------------------------------------------
out="$(fleet_croc_cli --select group:students --policy students --out "$SANDBOX/fleet-dry" --dry-run 2>&1)"
assert_eq "dry run exits 0" "$?" "0"
assert_contains "dry run lists alice" "$out" "alice.mesh"
assert_contains "dry run lists bob" "$out" "bob.mesh"
assert_contains "dry run says one after the other" "$out" "one after the other"
assert_empty_file "dry run starts no transfer" "$CROC_LOG"

# --- croc, real run: sequential, croc's own codes ----------------------------
: > "$CROC_LOG"; : > "$CROC_COUNT"
out="$(fleet_croc_cli --select group:students --policy students --out "$SANDBOX/fleet-live" 2>&1)"
assert_eq "croc run exits 0" "$?" "0"
assert_eq "one croc send per bundle" "$(grep -c 'send ' "$CROC_LOG")" "2"
assert_contains "first transfer is alice" "$(sed -n '1p' "$CROC_LOG")" "alice.mesh-nebula-bundle.zip"
assert_contains "second transfer is bob" "$(sed -n '2p' "$CROC_LOG")" "bob.mesh-nebula-bundle.zip"
assert_contains "sharing announces the first slot" "$out" "=== Sharing 1/2: alice.mesh ==="
assert_contains "sharing announces the second slot" "$out" "=== Sharing 2/2: bob.mesh ==="
assert_contains "croc's code is used for alice" "$out" "test-word-1"
assert_contains "croc's code is used for bob" "$out" "test-word-2"
assert_contains "delivery is reported" "$out" "Delivered alice.mesh"
assert_contains "delivery is reported for bob" "$out" "Delivered bob.mesh"
assert_contains "summary table is printed" "$out" "croc sharing summary:"
assert_eq "no custom code is forced on croc" "$(grep -c 'CROC_SECRET\|--code' "$CROC_LOG")" "0"
assert_file "per-transfer log is kept" "$SANDBOX/fleet-live/.croc-alice.mesh.log"

# --- croc shares an existing directory without re-rendering ------------------
: > "$CROC_LOG"; : > "$CROC_COUNT"
out="$(fleet_croc_cli --dir "$out_dir" 2>&1)"
assert_eq "dir share exits 0" "$?" "0"
assert_eq "dir share transfers each bundle" "$(grep -c 'send ' "$CROC_LOG")" "2"
assert_contains "dir share names alice" "$out" "alice.mesh"
assert_contains "dir share does not re-render" "$out" "Delivered"
assert_file "dir share writes the log next to the archive" "$out_dir/.croc-alice.mesh.log"

# --- croc shares exactly one archive -----------------------------------------
: > "$CROC_LOG"; : > "$CROC_COUNT"
out="$(fleet_croc_cli --bundle "$out_dir/bob.mesh-nebula-bundle.zip" 2>&1)"
assert_eq "single bundle exits 0" "$?" "0"
assert_eq "single bundle starts one transfer" "$(grep -c 'send ' "$CROC_LOG")" "1"
assert_contains "single bundle is bob" "$(cat "$CROC_LOG")" "bob.mesh-nebula-bundle.zip"
assert_not_contains "single bundle is not alice" "$(cat "$CROC_LOG")" "alice.mesh"
assert_contains "single bundle is delivered" "$out" "Delivered bob.mesh"

# --- a relay that refuses (croc exits 0) is a failure ------------------------
: > "$CROC_LOG"; : > "$CROC_COUNT"
out="$(CROC_RELAY_FAIL=1 fleet_croc_cli --bundle "$out_dir/alice.mesh-nebula-bundle.zip" 2>&1)"
assert_not_contains "relay refusal is not a delivery" "$out" "Delivered alice.mesh"
assert_contains "relay refusal is diagnosed" "$out" "relay refused the transfer"
assert_contains "relay refusal points at fleet serve" "$out" "fleet serve"
assert_contains "relay refusal marks the node failed" "$out" "failed"
assert_contains "failed node is offered for a retry" "$out" "fleet croc --bundle"

# --- an interrupted transfer stops the loop and lists the rest ---------------
: > "$CROC_LOG"; : > "$CROC_COUNT"
out="$(CROC_EXIT=130 fleet_croc_cli --dir "$out_dir" 2>&1)"
assert_eq "interrupted run exits 0" "$?" "0"
assert_eq "interruption stops after the first transfer" "$(grep -c 'send ' "$CROC_LOG")" "1"
assert_contains "interruption is reported" "$out" "Stopped during"
assert_contains "interrupted node is marked" "$out" "interrupted"
assert_contains "the untouched node is listed" "$out" "not shared"
assert_contains "the untouched node can be retried" "$out" "fleet croc --bundle"

# --- croc without a code (older/newer output) is not a crash -----------------
: > "$CROC_LOG"; : > "$CROC_COUNT"
out="$(CROC_SILENT=1 fleet_croc_cli --bundle "$out_dir/alice.mesh-nebula-bundle.zip" 2>&1)"
assert_eq "codeless croc exits 0" "$?" "0"
assert_contains "codeless croc is still delivered" "$out" "Delivered alice.mesh"

# --- LAN-only and relay modes ------------------------------------------------
: > "$CROC_LOG"; : > "$CROC_COUNT"
out="$(fleet_croc_cli --bundle "$out_dir/alice.mesh-nebula-bundle.zip" --local 2>&1)"
assert_contains "sender uses --local" "$(cat "$CROC_LOG")" "--local"
assert_contains "LAN-only mode is announced" "$out" "LAN only (--local)"

: > "$CROC_LOG"; : > "$CROC_COUNT"
out="$(fleet_croc_cli --bundle "$out_dir/alice.mesh-nebula-bundle.zip" --relay 10.9.9.9:9009 2>&1)"
assert_contains "sender uses the relay" "$(cat "$CROC_LOG")" "--relay 10.9.9.9:9009"
assert_contains "relay is announced" "$out" "Relay: 10.9.9.9:9009"

# --- error handling ----------------------------------------------------------
out="$(fleet_bundle_cli --bogus 2>&1)"; rc=$?
assert_eq "unknown option is rejected" "$rc" "2"
assert_contains "unknown option is named" "$out" "--bogus"

out="$(fleet_croc_cli --bundle "$SANDBOX/nope.zip" 2>&1)"; rc=$?
assert_eq "missing bundle is rejected" "$rc" "1"
assert_contains "missing bundle is named" "$out" "Bundle not found"

assert_eq "no sudo used" "$(sudo_count)" "0"

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
