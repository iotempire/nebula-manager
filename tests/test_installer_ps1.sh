#!/usr/bin/env bash
# Test: the PowerShell bundle installer under pwsh (Linux/macOS CI included).
#   * parses cleanly
#   * installs cert/key/CA/config into a user-owned directory (no Windows APIs)
#   * shows a diff and refuses to overwrite an existing config without -Yes
#   * -Yes replaces it and keeps a backup; -CertsOnly keeps the config
#   * service management is skipped with a clear message off Windows
set -uo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/helpers.sh"

TEST_LABEL="PowerShell bundle installer"
harness_init
require_cmd pwsh
require_cmd nebula-cert
require_cmd jq

script="$REPO_ROOT/lib/bundle/install.ps1"
cat > "$SANDBOX/parse.ps1" <<'PS'
param([string]$Path)
$tokens = $null
$errors = $null
[System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors) | Out-Null
if ($errors.Count) {
    $errors | ForEach-Object { Write-Host $_.Message }
    exit 1
}
PS
pwsh -NoProfile -File "$SANDBOX/parse.ps1" "$script" >/dev/null 2>&1
assert_eq "install.ps1 parses" "$?" "0"

# --- fixture: a real bundle ------------------------------------------------
keys="$SANDBOX/keys"
export CERT_DIR_OVERRIDE="$keys"
CA_NAME="test-ca" CERT_DIR="$keys" pki_ca_create >/dev/null 2>&1 || {
    echo "SKIP: cannot create a CA with the installed nebula-cert"; exit 77; }
SIGN_NAME="roamer.mesh" SIGN_IP="10.90.0.2/24" SIGN_GROUPS="home" \
    CERT_DIR="$keys" pki_sign >/dev/null 2>&1

mkdir -p "$SANDBOX/bundles"
bundle_out="$(pki_bundle_client_zip roamer.mesh "$SANDBOX/bundles" "$keys" "" 2>/dev/null)"
archive="$(printf '%s\n' "$bundle_out" | tail -n1)"
unpack="$SANDBOX/unpacked"; mkdir -p "$unpack"
case "$archive" in
    *.zip)    require_cmd unzip; unzip -q "$archive" -d "$unpack" ;;
    *.tar.gz) tar -xzf "$archive" -C "$unpack" ;;
    *) _bad "unexpected archive type" "$archive"; harness_summary; exit 1 ;;
esac
installer="$unpack/install.ps1"
assert_file "PowerShell installer is in the bundle" "$installer"

# --- install (portable path, no service) -----------------------------------
target="$SANDBOX/pstarget"
out="$(pwsh -NoProfile -File "$installer" -Dir "$target" -NoStart -Yes 2>&1)"; rc=$?
assert_eq "PowerShell installer exits 0" "$rc" "0"
assert_contains "PowerShell installer reports success" "$out" "Installed 'roamer.mesh'"
assert_file "PowerShell installed the certificate" "$target/roamer.mesh.crt"
assert_file "PowerShell installed the key"         "$target/roamer.mesh.key"
assert_file "PowerShell installed the CA"          "$target/ca.crt"
assert_file "PowerShell installed the config"      "$target/config.yml"
assert_contains "PowerShell rebased the config" "$(cat "$target/config.yml")" "$target"
assert_eq "PowerShell restricts the key (non-Windows)" "$(stat -c %a "$target/roamer.mesh.key")" "600"

# --- existing config: diff + refusal; then -Yes + backup --------------------
printf '\n# local change\n' >> "$target/config.yml"
out="$(pwsh -NoProfile -File "$installer" -Dir "$target" -NoStart </dev/null 2>&1)"; rc=$?
assert_ne "existing config stops without -Yes" "$rc" "0"
assert_contains "shows the diff"        "$out" "# local change"
assert_contains "explains the refusal"  "$out" "refusing"
assert_contains "config was not overwritten" "$(cat "$target/config.yml")" "# local change"

out="$(pwsh -NoProfile -File "$installer" -Dir "$target" -NoStart -Yes 2>&1)"; rc=$?
assert_eq "-Yes accepts the overwrite" "$rc" "0"
assert_not_contains "config was replaced" "$(cat "$target/config.yml")" "# local change"
if compgen -G "$target/config.yml.bak.*" >/dev/null; then
    _ok "existing config was backed up"
else
    _bad "existing config was backed up"
fi

# --- -CertsOnly keeps the config -------------------------------------------
printf '\n# keep me\n' >> "$target/config.yml"
out="$(pwsh -NoProfile -File "$installer" -Dir "$target" -CertsOnly -NoStart </dev/null 2>&1)"; rc=$?
assert_eq "-CertsOnly exits 0 without -Yes" "$rc" "0"
assert_contains "-CertsOnly keeps the config" "$(cat "$target/config.yml")" "# keep me"
assert_contains "-CertsOnly explains the config" "$out" "Kept the existing config.yml"

# --- off Windows the service step is skipped, not failed -------------------
out="$(pwsh -NoProfile -File "$installer" -Dir "$target" -Yes 2>&1)"; rc=$?
assert_eq "non-Windows service step exits 0" "$rc" "0"
assert_contains "explains Windows-only service" "$out" "Windows-only"

assert_eq "PowerShell installer used no sudo" "$(sudo_count)" "0"

# --- simulated Windows: ACL + service install/start -------------------------
mockbin="$SANDBOX/mockbin"; mkdir -p "$mockbin"
cat > "$mockbin/nebula.exe" <<'MOCK'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${NEBULA_LOG:?}"
exit 0
MOCK
cat > "$mockbin/icacls.exe" <<'MOCK'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${ICACLS_LOG:?}"
exit 0
MOCK
chmod +x "$mockbin/nebula.exe" "$mockbin/icacls.exe"
export NEBULA_LOG="$SANDBOX/nebula.log" ICACLS_LOG="$SANDBOX/icacls.log" SVC_LOG="$SANDBOX/svc.log"
: > "$NEBULA_LOG"; : > "$ICACLS_LOG"; : > "$SVC_LOG"
rm -f "$SVC_LOG.armed"

cat > "$SANDBOX/win.ps1" <<'PS'
param([string]$Installer, [string]$Dir)
$env:OS = 'Windows_NT'
function Get-Service {
    [CmdletBinding()]
    param([string]$Name)
    Add-Content -LiteralPath $env:SVC_LOG -Value "get $Name"
    $marker = "$env:SVC_LOG.armed"
    if ($env:SVC_MISSING -eq '1' -and -not (Test-Path $marker)) {
        New-Item -ItemType File -Path $marker -Force | Out-Null
        return $null
    }
    $status = if ($env:SVC_RUNNING -eq '1') { 'Running' } else { 'Stopped' }
    [pscustomobject]@{ Name = $Name; Status = $status }
}
function Start-Service {
    [CmdletBinding()]
    param([string]$Name)
    Add-Content -LiteralPath $env:SVC_LOG -Value "start $Name"
}
function Restart-Service {
    [CmdletBinding()]
    param([string]$Name, [switch]$Force)
    Add-Content -LiteralPath $env:SVC_LOG -Value "restart $Name"
}
& $Installer -Dir $Dir -Yes
exit $LASTEXITCODE
PS

out="$(PATH="$mockbin:$PATH" NEBULA_INSTALL_NO_ELEVATE=1 SVC_MISSING=1 SVC_RUNNING=0 \
    pwsh -NoProfile -File "$SANDBOX/win.ps1" "$installer" "$target" 2>&1)"; rc=$?
assert_eq "simulated Windows install exits 0" "$rc" "0"
assert_contains "ACL restricted on Windows" "$(cat "$ICACLS_LOG")" "/inheritance:r"
assert_contains "Windows service installed"  "$(cat "$NEBULA_LOG")" "-service install"
assert_contains "Windows config validated"   "$(cat "$NEBULA_LOG")" "-test"
assert_contains "Windows service started"    "$(cat "$SVC_LOG")" "start Nebula"

: > "$NEBULA_LOG"; : > "$ICACLS_LOG"; : > "$SVC_LOG"
out="$(PATH="$mockbin:$PATH" NEBULA_INSTALL_NO_ELEVATE=1 SVC_MISSING=0 SVC_RUNNING=1 \
    pwsh -NoProfile -File "$SANDBOX/win.ps1" "$installer" "$target" 2>&1)"; rc=$?
assert_eq "simulated Windows restart exits 0" "$rc" "0"
assert_contains "running service is restarted" "$(cat "$SVC_LOG")" "restart Nebula"

harness_summary
