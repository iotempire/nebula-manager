#!/usr/bin/env bash
# Test: build_single.sh emits one self-contained executable.
#   * no lib/ sourcing, passes bash -n
#   * --version / --help work from a directory without lib/
#   * embedded config template works offline (config init)
#   * embedded client-bundle assets (install.sh/install.ps1/README.txt) are used
#   * CA/sign/list/config/bundle work and use no sudo
set -uo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/helpers.sh"

TEST_LABEL="single-file build"
harness_init

require_cmd nebula-cert
require_cmd jq
require_cmd zip
require_cmd unzip

# Keep the materialised-asset cache inside the sandbox.
export XDG_CACHE_HOME="$SANDBOX/xdg-cache"
mkdir -p "$XDG_CACHE_HOME"

BUILD="$REPO_ROOT/build_single.sh"
DIST="$SANDBOX/dist"
SINGLE="$DIST/nebula-manager"
mkdir -p "$DIST"

# --- build ------------------------------------------------------------------
bash "$BUILD" "$SINGLE" >"$SANDBOX/build.log" 2>&1
rc=$?
assert_eq "build_single.sh succeeds" "$rc" "0"
if [[ "$rc" -ne 0 ]]; then
    cat "$SANDBOX/build.log" >&2
    harness_summary
    exit 1
fi

assert_file "single-file executable written" "$SINGLE"
assert_file "checksum written next to it" "$SINGLE.sha256"
if [[ -x "$SINGLE" ]]; then _ok "single file is executable"; else _bad "single file is executable"; fi

if bash -n "$SINGLE" 2>"$SANDBOX/n.err"; then
    _ok "single file passes bash -n"
else
    _bad "single file passes bash -n" "$(cat "$SANDBOX/n.err")"
fi

body="$(cat "$SINGLE")"
assert_not_contains "no lib/ sourcing in single file" "$body" 'source "$MANAGER_LIB_DIR'
assert_not_contains "no missing-module path in single file" "$body" 'missing module'

# --- run as a standalone executable from a directory without lib/ -----------
RUN="$SANDBOX/run"
mkdir -p "$RUN"
run_single() {
    ( cd "$RUN" && env -u MANAGER_LIB_DIR -u NEBULA_MANAGER_LIB "$SINGLE" "$@" )
}

out="$(run_single --version 2>&1)"
assert_contains "--version works" "$out" "Nebula Manager v"

out="$(run_single --help 2>&1)"
assert_contains "--help works" "$out" "Usage:"

# --- update URL branches ----------------------------------------------------
single_default="$(
    NEBULA_MANAGER_REPO="me/fork"
    # shellcheck disable=SC1090
    . "$SINGLE" >/dev/null 2>&1
    init_remote_urls
    printf '%s\n' "$SCRIPT_URL"
)"
assert_eq "single-file default SCRIPT_URL is the release asset" \
    "$single_default" "https://github.com/me/fork/releases/latest/download/nebula-manager"

single_override="$(
    NEBULA_MANAGER_SINGLE_URL="https://example.invalid/nebula-manager"
    # shellcheck disable=SC1090
    . "$SINGLE" >/dev/null 2>&1
    init_remote_urls
    printf '%s\n' "$SCRIPT_URL"
)"
assert_eq "NEBULA_MANAGER_SINGLE_URL overrides SCRIPT_URL" \
    "$single_override" "https://example.invalid/nebula-manager"

# The here-doc assets are materialised under the cache on first run.
asset_root="$XDG_CACHE_HOME/nebula-manager/single-file-assets"
assert_dir "asset cache created" "$asset_root"
asset_dir="$(find "$asset_root" -mindepth 1 -maxdepth 1 -type d | head -n1)"
assert_dir "versioned asset dir created" "$asset_dir"
assert_file "config template materialised" "$asset_dir/nebula-manager.conf.template"
assert_file "install.sh materialised" "$asset_dir/bundle/install.sh"
assert_file "install.ps1 materialised" "$asset_dir/bundle/install.ps1"
assert_file "README.txt materialised" "$asset_dir/bundle/README.txt"

# --- PKI / config / bundle through the single file -------------------------
keys="$SANDBOX/keys"
mkdir -p "$keys"

# A readable local Nebula config so generated node configs inherit real values.
LOCAL="$SANDBOX/local/config.yml"
mkdir -p "$(dirname "$LOCAL")"
cat > "$LOCAL" <<'YAML'
static_host_map:
  "10.91.0.1": ["vps.mesh:4545"]

lighthouse:
  am_lighthouse: false
  interval: 5
  hosts:
    - "10.91.0.1"

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
export NEBULA_NO_LOCAL_CONFIG=1

run_single ca --name single-ca --cert-dir "$keys" >/dev/null 2>&1
assert_eq "ca succeeds via single file" "$?" "0"
assert_file "CA certificate created" "$keys/ca.crt"
assert_file "CA key created" "$keys/ca.key"

run_single sign --cert-dir "$keys" --name node1 --ip 10.91.0.2/24 --groups servers >/dev/null 2>&1
assert_eq "sign succeeds via single file" "$?" "0"
assert_file "signed certificate created" "$keys/node1.crt"
assert_file "signed key created" "$keys/node1.key"

out="$(run_single --cert-dir "$keys" cert list 2>/dev/null)"
assert_contains "cert list shows node1" "$out" "node1"

run_single --cert-dir "$keys" cert config generate --force node1 >/dev/null 2>&1
assert_eq "cert config generate succeeds" "$?" "0"
assert_file "node config generated" "$keys/node1.yml"
assert_contains "node config used the local fixture" "$(cat "$keys/node1.yml")" "10.91.0.1"

out_dir="$SANDBOX/out"
run_single --cert-dir "$keys" cert bundle node1 --out "$out_dir" >/dev/null 2>&1
assert_eq "cert bundle succeeds" "$?" "0"
archive="$out_dir/node1-nebula-bundle.zip"
assert_file "bundle archive written" "$archive"
listing="$(unzip -l "$archive" 2>/dev/null)"
assert_contains "bundle contains install.sh" "$listing" "install.sh"
assert_contains "bundle contains install.ps1" "$listing" "install.ps1"
assert_contains "bundle contains README.txt" "$listing" "README.txt"

# --- embedded nebula-manager.conf template works offline -------------------
run_single config init --config "$SANDBOX/single.conf" >/dev/null 2>&1
assert_eq "config init succeeds via single file" "$?" "0"
assert_file "config init wrote a config" "$SANDBOX/single.conf"
assert_contains "config init used the embedded template" "$(cat "$SANDBOX/single.conf")" "[global]"

# --- least privilege --------------------------------------------------------
assert_eq "single-file operations used no sudo" "$(sudo_count)" "0"

harness_summary
