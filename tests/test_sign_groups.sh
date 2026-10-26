#!/usr/bin/env bash
# Test: interactive group prompt during certificate creation.
#   * existing workspace groups (with counts) are shown
#   * roles are suggested when the workspace is empty (not device types)
#   * Enter reuses the last groups used in THIS workspace
#   * different workspaces never inherit each other's groups
#   * invalid group input re-prompts
#   * mobile certs default to "mobile"
set -uo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/helpers.sh"

TEST_LABEL="sign groups prompt"
harness_init
require_cmd nebula-cert
require_cmd jq

keys="$SANDBOX/keys"
mkdir -p "$keys"
export CERT_DIR_OVERRIDE="$keys"
CA_NAME="group-ca" CERT_DIR="$keys" pki_ca_create >/dev/null 2>&1 || {
    echo "SKIP: cannot create a CA with the installed nebula-cert"; exit 77; }

# Existing certs give the prompt something to summarise.
SIGN_NAME="a.mesh.demo" SIGN_IP="10.80.0.2/24" SIGN_GROUPS="instructor,admin" \
    CERT_DIR="$keys" pki_sign >/dev/null 2>&1
SIGN_NAME="b.mesh.demo" SIGN_IP="10.80.0.3/24" SIGN_GROUPS="instructor" \
    CERT_DIR="$keys" pki_sign >/dev/null 2>&1

cert_groups() { # <cert-path>
    nebula_cert_json "$(dirname "$(pki_cert_bin)")" "$1" | jq -r '.details.groups | join(",")'
}

# --- explicit groups: prompt lists what already exists ----------------------
prompt_before="$(cert_groups_prompt "$keys" node)"
out="$(printf 'c.mesh.demo\nn\n10.80.0.4/24\ninstructor,admin\nn\n\n' | generate_nebula_cert 2>&1)"
assert_contains "prompt lists existing groups with counts" "$prompt_before" "existing: instructor (2), admin (1)"
assert_not_contains "prompt offers roles only when no groups exist" "$prompt_before" "roles, e.g."
assert_file "cert with explicit groups was signed" "$keys/c.mesh.demo.crt"

# --- Enter reuses the last groups for the same workspace --------------------
out="$(printf 'd.mesh.demo\nn\n10.80.0.5/24\n\nn\n\n' | generate_nebula_cert 2>&1)"
assert_contains "prompt shows the last selection as the Enter default" "$(cert_groups_prompt "$keys" node)" "Enter = instructor,admin"
assert_eq "Enter reuses the last groups" "$(cert_groups "$keys/d.mesh.demo.crt")" "instructor,admin"

# --- '-' clears the groups even when an Enter default exists --------------
out="$(printf 'f.mesh.demo\nn\n10.80.0.7/24\n-\nn\n\n' | generate_nebula_cert 2>&1)"
assert_contains "prompt explains how to clear groups" "$(cert_groups_prompt "$keys" node)" "'-' = none"
assert_eq "'-' clears the groups" "$(cert_groups "$keys/f.mesh.demo.crt")" ""

# --- invalid input is rejected and re-prompted ------------------------------
out="$(printf 'e.mesh.demo\nn\n10.80.0.6/24\nbad group\ninstructor\nn\n\n' | generate_nebula_cert 2>&1)"
assert_contains "invalid groups are reported" "$out" "Invalid groups"
assert_eq "valid input after the error is used" "$(cert_groups "$keys/e.mesh.demo.crt")" "instructor"

# --- an empty workspace suggests roles, not device types --------------------
empty="$SANDBOX/empty"
mkdir -p "$empty"
CA_NAME="empty-ca" CERT_DIR="$empty" pki_ca_create >/dev/null 2>&1
out="$(printf 'first.mesh.demo\nn\n10.81.0.2/24\n\nn\n\n' | CERT_DIR_OVERRIDE="$empty" generate_nebula_cert 2>&1)"
assert_contains "empty workspace suggests role examples" "$(cert_groups_prompt "$empty" node)" "roles, e.g. instructor,student"
assert_not_contains "old device examples are gone" "$(cert_groups_prompt "$empty" node)" "servers,desktops"
assert_not_contains "groups do not leak across workspaces" "$(cert_groups_prompt "$empty" node)" "Enter = instructor,admin"
assert_eq "empty workspace signed without groups" "$(cert_groups "$empty/first.mesh.demo.crt")" ""

# --- mobile certs offer "mobile" as the default -----------------------------
"$NEBULA_BIN_PATH/nebula-cert" keygen -out-key "$SANDBOX/dev.key" -out-pub "$SANDBOX/dev.pub" >/dev/null 2>&1
out="$(printf 'phone.mesh.demo\ny\n%s\n10.82.0.2/24\n\nn\n\n\n' "$SANDBOX/dev.pub" | generate_nebula_cert 2>&1)"
assert_contains "mobile prompt defaults to the mobile role" "$(cert_groups_prompt "$keys" mobile)" "Enter = mobile"
assert_eq "mobile Enter applies the mobile group" "$(cert_groups "$keys/phone.mesh.demo.crt")" "mobile"

harness_summary
