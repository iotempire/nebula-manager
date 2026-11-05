#!/usr/bin/env bash
# Test: self-contained client bundles (installer scripts + README + sharing).
#   * the archive ships install.sh / install.ps1 / README.txt
#   * install.sh installs into a user-owned dir without sudo
#   * an existing config.yml triggers a diff + refusal (non-interactive) and
#     needs --yes, keeping a timestamped backup
#   * README/console one-liners carry the requested share URL
set -uo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/helpers.sh"

TEST_LABEL="self-contained client bundle"
harness_init
require_cmd nebula-cert
require_cmd jq

keys="$SANDBOX/keys"
export CERT_DIR_OVERRIDE="$keys"
CA_NAME="test-ca" CERT_DIR="$keys" pki_ca_create >/dev/null 2>&1 || {
    echo "SKIP: cannot create a CA with the installed nebula-cert"; exit 77; }
SIGN_NAME="roamer.mesh" SIGN_IP="10.80.0.2/24" SIGN_GROUPS="home" \
    CERT_DIR="$keys" pki_sign >/dev/null 2>&1

out_dir="$SANDBOX/bundles"
mkdir -p "$out_dir"
share_base="https://class.example/bundles"
bundle_out="$(pki_bundle_client_zip roamer.mesh "$out_dir" "$keys" "" "$share_base" "1234-abcd" 2>"$SANDBOX/bundle.err")"
archive="$(printf '%s\n' "$bundle_out" | tail -n1)"
assert_file "bundle created" "$archive"
assert_contains "bundle announces sharing" "$bundle_out" "Share this bundle"
assert_contains "console one-liner uses the URL" "$bundle_out" "$share_base/"

unpack="$SANDBOX/unpacked"; mkdir -p "$unpack"
case "$archive" in
    *.zip)
        require_cmd unzip
        unzip -q "$archive" -d "$unpack" || { echo "SKIP: cannot unzip bundle"; exit 77; }
        listing="$(unzip -l "$archive")" ;;
    *.tar.gz)
        tar -xzf "$archive" -C "$unpack"
        listing="$(tar -tzf "$archive")" ;;
    *) _bad "unexpected archive type" "$archive"; harness_summary; exit 1 ;;
esac

assert_contains "bundle ships install.sh"  "$listing" "install.sh"
assert_contains "bundle ships install.ps1" "$listing" "install.ps1"
assert_contains "bundle ships README.txt"  "$listing" "README.txt"

readme="$unpack/README.txt"
assert_contains "README names the node"        "$(cat "$readme")" "roamer.mesh"
assert_contains "README has a curl one-liner"  "$(cat "$readme")" "curl -fsSL"
assert_contains "README has a croc one-liner"  "$(cat "$readme")" "croc --yes"
assert_contains "README uses the share URL"    "$(cat "$readme")" "$share_base/"
assert_contains "README mentions sudo install" "$(cat "$readme")" "sudo bash"

ps1="$unpack/install.ps1"
assert_contains "PowerShell installer elevates"   "$(cat "$ps1")" "RunAs"
assert_contains "PowerShell installer diffs"      "$(cat "$ps1")" "diff --no-index"
assert_contains "PowerShell installer can skip"   "$(cat "$ps1")" "NoStart"

# --- install into a user-owned directory (no sudo, no service) --------------
target="$SANDBOX/client"
: > "$SUDO_LOG"
# Fake systemctl so the (re)start path can be verified without touching the host.
cat > "$SANDBOX/bin/systemctl" <<'MOCK'
#!/usr/bin/env bash
echo "$*" >> "${SYSTEMCTL_LOG:?}"
exit 0
MOCK
chmod +x "$SANDBOX/bin/systemctl"
export SYSTEMCTL_LOG="$SANDBOX/systemctl.log"
: > "$SYSTEMCTL_LOG"
install_out="$(bash "$unpack/install.sh" --dir "$target" --no-start --yes 2>&1)"
assert_eq "installer exits 0" "$?" "0"
assert_contains "installer reports success" "$install_out" "Installed 'roamer.mesh'"
assert_file "certificate installed" "$target/roamer.mesh.crt"
assert_file "key installed"         "$target/roamer.mesh.key"
assert_file "CA installed"          "$target/ca.crt"
assert_file "config installed"      "$target/config.yml"
assert_contains "config paths rebased" "$(cat "$target/config.yml")" "$target"
assert_eq "private key is mode 600" "$(stat -c %a "$target/roamer.mesh.key")" "600"
assert_eq "user-owned install used no sudo" "$(sudo_count)" "0"
assert_empty_file "--no-start skips the service manager" "$SYSTEMCTL_LOG"

# --- service restart ---------------------------------------------------------
bash "$unpack/install.sh" --dir "$target" --yes >/dev/null 2>&1
assert_contains "installer enables the service"  "$(cat "$SYSTEMCTL_LOG")" "enable nebula.service"
assert_contains "installer restarts the service" "$(cat "$SYSTEMCTL_LOG")" "restart nebula.service"

# --- existing config: diff + refuse without a TTY, accept with --yes --------
printf '\n# local change\n' >> "$target/config.yml"
out="$(bash "$unpack/install.sh" --dir "$target" --no-start </dev/null 2>&1)"; rc=$?
assert_ne "existing config stops without --yes" "$rc" "0"
assert_contains "installer shows the existing path" "$out" "already exists"
assert_contains "installer shows a diff"            "$out" "# local change"
assert_contains "installer explains the refusal"    "$out" "refusing"
assert_contains "config was not overwritten" "$(cat "$target/config.yml")" "# local change"

out="$(bash "$unpack/install.sh" --dir "$target" --no-start --yes 2>&1)"; rc=$?
assert_eq "installer accepts --yes" "$rc" "0"
assert_not_contains "config was replaced" "$(cat "$target/config.yml")" "# local change"
if compgen -G "$target/config.yml.bak.*" >/dev/null; then
    _ok "existing config was backed up"
else
    _bad "existing config was backed up"
fi

assert_eq "installer never used sudo for user paths" "$(sudo_count)" "0"

# --- certs-only: refresh the certificate and keep the config ----------------
printf '\n# keep me\n' >> "$target/config.yml"
out="$(bash "$unpack/install.sh" --dir "$target" --certs-only --no-start </dev/null 2>&1)"; rc=$?
assert_eq "--certs-only succeeds without --yes" "$rc" "0"
assert_contains "--certs-only keeps the existing config" \
    "$(cat "$target/config.yml")" "# keep me"
assert_contains "--certs-only says it kept the config" "$out" "Kept the existing config.yml"

# --- rendering adapts to the archive type -----------------------------------
tpl="$SANDBOX/tpl.txt"
printf '@ARCHIVE@|@EXT@|@EXTRACT_LINUX@|@EXTRACT_WIN@\n' > "$tpl"
pki_render_bundle_readme "$tpl" "$SANDBOX/rendered-tar" "n" "x.tar.gz" p u c
assert_contains "tar bundle renders tar extraction" "$(cat "$SANDBOX/rendered-tar")" "tar -xzf"
pki_render_bundle_readme "$tpl" "$SANDBOX/rendered-zip" "n" "x.zip" p u c
assert_contains "zip bundle renders unzip extraction" "$(cat "$SANDBOX/rendered-zip")" "unzip -q"

# --- regression: the default dir must not hang -------------------------------
# The renderer used to replace "/etc/nebula" with itself in an endless loop, so
# every default install stalled before touching anything.
if command -v timeout >/dev/null 2>&1; then
    out="$(timeout 20 bash "$unpack/install.sh" --certs-only --no-start --yes 2>&1)"; rc=$?
    assert_eq "default /etc/nebula install does not hang" "$rc" "0"
    assert_contains "default-dir install reports success" "$out" "Installed 'roamer.mesh'"
    assert_contains "default-dir install finishes the --no-start path" "$out" "Service start skipped"

    # A target that itself contains "/etc/nebula" must be substituted exactly
    # once (the in-place loop kept re-expanding the inserted path).
    mkdir -p "$SANDBOX/etc"
    grow="$SANDBOX/etc/nebula"
    out="$(timeout 20 bash "$unpack/install.sh" --dir "$grow" --no-start --yes 2>&1)"; rc=$?
    assert_eq "nested target install exits 0" "$rc" "0"
    assert_eq "old path replaced exactly once" \
        "$(grep -m1 'ca:' "$grow/config.yml" | sed 's/^[[:space:]]*//')" \
        "ca: $grow/ca.crt"
else
    echo "SKIP: 'timeout' not available - hang regression not checked"
fi

# --- mesh DNS: the bundle carries a hint -------------------------------------
cat > "$SANDBOX/local.yml" <<'YML'
lighthouse:
  am_lighthouse: false
  interval: 5
  hosts:
    - "10.80.0.1"
static_host_map:
  "10.80.0.1": ["vpn.example:4545"]
tun:
  dev: nebula1
YML
mkdir -p "$SANDBOX/dnsbundles"
dns_out="$(NEBULA_LOCAL_CONFIG="$SANDBOX/local.yml" \
    pki_bundle_client_zip roamer.mesh "$SANDBOX/dnsbundles" "$keys" "" "" "" 2>&1)"
dns_archive="$(printf '%s\n' "$dns_out" | tail -n1)"
assert_file "bundle with DNS hint created" "$dns_archive"
case "$dns_archive" in
    *.zip)    assert_contains "bundle ships nebula-dns.conf" "$(unzip -l "$dns_archive" 2>/dev/null)" "nebula-dns.conf"
              dns_body="$(unzip -p "$dns_archive" nebula-dns.conf 2>/dev/null || true)" ;;
    *.tar.gz) assert_contains "bundle ships nebula-dns.conf" "$(tar -tzf "$dns_archive" 2>/dev/null)" "nebula-dns.conf"
              dns_body="$(tar -xzOf "$dns_archive" nebula-dns.conf 2>/dev/null || true)" ;;
    *)        dns_body="" ;;
esac
assert_contains "DNS hint carries the mesh suffix"   "$dns_body" "DOMAIN=mesh"
assert_contains "DNS hint carries the lighthouse IP" "$dns_body" 'LIGHTHOUSES="10.80.0.1"'
assert_contains "DNS hint carries the tun device"    "$dns_body" "TUN=nebula1"

# --- mesh DNS: the installer applies it --------------------------------------
cat > "$SANDBOX/bin/resolvectl" <<'MOCK'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${RESOLVECTL_LOG:?}"
exit 0
MOCK
chmod +x "$SANDBOX/bin/resolvectl"
cat > "$SANDBOX/bin/ip" <<'MOCK'
#!/usr/bin/env bash
exit 0
MOCK
chmod +x "$SANDBOX/bin/ip"
export RESOLVECTL_LOG="$SANDBOX/resolvectl.log"

cat > "$unpack/nebula-dns.conf" <<'DNS'
TUN=nebula1
DOMAIN=test.mesh
LIGHTHOUSES=10.80.0.1 10.80.0.2
DNS
: > "$RESOLVECTL_LOG"
out="$(bash "$unpack/install.sh" --dir "$target" --yes 2>&1)"; rc=$?
assert_eq "installer with DNS hint exits 0" "$rc" "0"
assert_contains "mesh DNS servers applied" "$(cat "$RESOLVECTL_LOG")" "dns nebula1 10.80.0.1 10.80.0.2"
assert_contains "mesh DNS suffix applied"  "$(cat "$RESOLVECTL_LOG")" "domain nebula1 ~test.mesh"
assert_contains "installer reports mesh DNS" "$out" "Mesh DNS: ~test.mesh"

: > "$RESOLVECTL_LOG"
out="$(bash "$unpack/install.sh" --dir "$target" --yes --no-dns 2>&1)"; rc=$?
assert_eq "--no-dns still succeeds" "$rc" "0"
assert_empty_file "--no-dns leaves the resolver alone" "$RESOLVECTL_LOG"
assert_contains "--no-dns is announced" "$out" "Mesh DNS setup skipped"

# --- old nebula binary: actionable V2 guidance -------------------------------
cat > "$SANDBOX/bin/nebula" <<'MOCK'
#!/usr/bin/env bash
case "${1:-}" in
    --version|-version) echo "Version: 1.6.2"; exit 0 ;;
esac
echo 'ERRO Could not load client cert error="error while unmarshaling pki.cert: bytes did not contain a proper nebula certificate banner"' >&2
exit 1
MOCK
chmod +x "$SANDBOX/bin/nebula"
out="$(bash "$unpack/install.sh" --dir "$target" --yes --no-dns 2>&1)"; rc=$?
assert_eq "install with an old nebula exits 0" "$rc" "0"
assert_contains "old nebula is detected"        "$out" "older than v1.10"
assert_contains "V2 requirement is explained"   "$out" "V2 certificate"
assert_contains "upgrade hint is printed"       "$out" "Upgrade Nebula to v1.10+"
rm -f "$SANDBOX/bin/nebula"

harness_summary
