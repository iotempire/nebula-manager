# Nebula client bundle installer (Windows / PowerShell)
# =====================================================
# Installs the certificate, private key, CA and config that sit next to this
# script. Existing files are backed up first. If config.yml already exists the
# script shows a diff and asks before overwriting it.
#
# Usage (elevated PowerShell):
#   powershell -ExecutionPolicy Bypass -File .\install.ps1
#   powershell -ExecutionPolicy Bypass -File .\install.ps1 -Dir C:\ProgramData\nebula
#   powershell -ExecutionPolicy Bypass -File .\install.ps1 -Yes -NoStart
#   powershell -ExecutionPolicy Bypass -File .\install.ps1 -CertsOnly
#
# The archive contains a private key: transfer it over a trusted channel and
# delete it from the client after installation.
#
# Automation: NEBULA_INSTALL_NO_ELEVATE=1 assumes the caller is already elevated.

[CmdletBinding()]
param(
    [string]$Dir = '',
    [string]$Service = 'Nebula',
    [switch]$Yes,
    [switch]$NoStart,
    [switch]$CertsOnly
)

$ErrorActionPreference = 'Stop'
# External tools such as `git diff` return 1 for "differences"; do not turn that
# into a terminating error on newer PowerShell versions.
if (Get-Variable PSNativeCommandUseErrorActionPreference -ErrorAction SilentlyContinue) {
    $PSNativeCommandUseErrorActionPreference = $false
}
$BundleDir = Split-Path -Parent $PSCommandPath

# The install logic (file discovery, config diff, copies, backups) is portable;
# only elevation, ACLs and service management are Windows-specific. That also
# lets the script be exercised under pwsh on Linux/macOS in the test suite.
$isWindowsHost = ($env:OS -eq 'Windows_NT') -or ($PSVersionTable.PSEdition -eq 'Desktop')
if ([string]::IsNullOrWhiteSpace($Dir)) {
    if ($isWindowsHost) { $Dir = Join-Path $env:ProgramData 'nebula' }
    else { $Dir = Join-Path ([IO.Path]::GetTempPath()) 'nebula' }
}

function Say([string]$m)  { Write-Host "[install] $m" }
function Warn([string]$m) { Write-Warning "[install] $m" }
function Die([string]$m)  { Write-Error "[install] $m"; exit 1 }

# --- elevation (Windows only) -----------------------------------------------
# NEBULA_INSTALL_NO_ELEVATE=1 is for automation/CI that already runs elevated.
$skipElevation = ($env:NEBULA_INSTALL_NO_ELEVATE -eq '1')
if ($isWindowsHost -and -not $skipElevation) {
    $principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    $isAdmin = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    if (-not $isAdmin) {
        Say 'Administrator rights are required - relaunching elevated...'
        $relaunch = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`"",
                      '-Dir', "`"$Dir`"", '-Service', "`"$Service`"")
        if ($Yes)       { $relaunch += '-Yes' }
        if ($NoStart)   { $relaunch += '-NoStart' }
        if ($CertsOnly) { $relaunch += '-CertsOnly' }
        try {
            Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList $relaunch -Wait
        } catch {
            Die "could not elevate: $($_.Exception.Message)"
        }
        exit 0
    }
}

# --- locate the bundle files ------------------------------------------------
$ca = Join-Path $BundleDir 'ca.crt'
if (-not (Test-Path -LiteralPath $ca)) { Die "ca.crt not found in $BundleDir" }

$pair = Get-ChildItem -LiteralPath $BundleDir -Filter '*.crt' |
    Where-Object { $_.Name -ne 'ca.crt' } |
    ForEach-Object {
        $key = Join-Path $BundleDir ($_.BaseName + '.key')
        if (Test-Path -LiteralPath $key) {
            [pscustomobject]@{ Crt = $_.FullName; Key = $key; Name = $_.BaseName }
        }
    } | Select-Object -First 1
if (-not $pair) { Die "no <name>.crt + <name>.key pair found in $BundleDir" }

$tmpl = $null
foreach ($candidate in @((Join-Path $BundleDir 'config.yml.template'),
                         (Join-Path $BundleDir 'config.yml'))) {
    if (Test-Path -LiteralPath $candidate) { $tmpl = $candidate; break }
}
if (-not $tmpl) { Die "config.yml.template / config.yml not found in $BundleDir" }

# --- render the config for the chosen directory -----------------------------
$dirYaml = $Dir -replace '\\', '/'
$rendered = (Get-Content -Raw -LiteralPath $tmpl).Replace('/etc/nebula', $dirYaml)
$tmp = [IO.Path]::GetTempFileName()
try {
    [IO.File]::WriteAllText($tmp, $rendered, (New-Object System.Text.UTF8Encoding($false)))
} catch {
    Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
    Die "could not render the config: $($_.Exception.Message)"
}

$config = Join-Path $Dir 'config.yml'

# --- existing config: show a diff and ask -----------------------------------
if ((-not $CertsOnly) -and (Test-Path -LiteralPath $config)) {
    Say "config.yml already exists: $config"
    Say 'Proposed changes (- existing, + bundle):'
    $git = Get-Command git -ErrorAction SilentlyContinue
    if ($git) {
        try { & $git.Source diff --no-index --no-color -- $config $tmp } catch { }
    } else {
        $old = Get-Content -LiteralPath $config
        $new = Get-Content -LiteralPath $tmp
        Compare-Object -ReferenceObject $old -DifferenceObject $new | ForEach-Object {
            $mark = if ($_.SideIndicator -eq '<=') { '-' } else { '+' }
            Write-Host ("{0} {1}" -f $mark, $_.InputObject)
        }
    }
    if (-not $Yes) {
        if ([Console]::IsInputRedirected) {
            Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
            Die 'config.yml exists; refusing to overwrite in a non-interactive shell (use -Yes)'
        }
        $answer = Read-Host 'Overwrite the existing config? [y/N]'
        if ($answer -notmatch '^(y|yes)$') {
            Say 'aborted - nothing was changed'
            Say 'Tip: -CertsOnly refreshes cert/key/CA without touching config.yml'
            Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
            exit 1
        }
    }
}

# --- install ----------------------------------------------------------------
try {
    New-Item -ItemType Directory -Force -Path $Dir | Out-Null
} catch {
    Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
    Die "cannot create ${Dir}: $($_.Exception.Message)"
}

$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
function Backup([string]$path) {
    if (Test-Path -LiteralPath $path) {
        Copy-Item -LiteralPath $path -Destination "$path.bak.$stamp" -Force
    }
}

$crtDst = Join-Path $Dir ($pair.Name + '.crt')
$keyDst = Join-Path $Dir ($pair.Name + '.key')
$caDst  = Join-Path $Dir 'ca.crt'

Backup $crtDst; Backup $keyDst; Backup $caDst
if (-not $CertsOnly) { Backup $config }
try {
    Copy-Item -LiteralPath $pair.Crt -Destination $crtDst -Force
    Copy-Item -LiteralPath $pair.Key -Destination $keyDst -Force
    Copy-Item -LiteralPath $ca      -Destination $caDst  -Force
    if (-not $CertsOnly) {
        Copy-Item -LiteralPath $tmp -Destination $config -Force
    }
} catch {
    Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
    Die "failed to install files: $($_.Exception.Message)"
}
Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue

# Private key: SYSTEM (for the service) + Administrators only on Windows.
# Elsewhere (pwsh on Linux/macOS) plain POSIX permissions are the right thing.
if ($isWindowsHost) {
    & icacls.exe $keyDst /inheritance:r /grant:r 'SYSTEM:(R)' 'Administrators:(F)' 2>$null | Out-Null
} else {
    $chmod = Get-Command chmod -ErrorAction SilentlyContinue
    if ($chmod) { & $chmod.Source 600 $keyDst }
}

Say "Installed '$($pair.Name)' into $Dir"
if ($CertsOnly) {
    if (Test-Path -LiteralPath $config) { Say 'Kept the existing config.yml (-CertsOnly)' }
    else { Warn '-CertsOnly: no config.yml installed (none existed)' }
    Say "  $($pair.Name).crt, $($pair.Name).key, ca.crt"
} else {
    Say "  $($pair.Name).crt, $($pair.Name).key, ca.crt, config.yml"
}

# --- validate ---------------------------------------------------------------
$nebula = $null
$cmd = Get-Command nebula.exe -ErrorAction SilentlyContinue
if ($cmd) { $nebula = $cmd.Source }
if (-not $nebula -and -not $isWindowsHost) {
    $cmd = Get-Command nebula -ErrorAction SilentlyContinue
    if ($cmd) { $nebula = $cmd.Source }
}
if (-not $nebula) {
    $candidates = @((Join-Path $Dir 'nebula.exe'))
    if ($env:ProgramFiles) { $candidates += (Join-Path $env:ProgramFiles 'Nebula\nebula.exe') }
    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath $candidate) { $nebula = $candidate; break }
    }
}
if ($nebula) {
    if (Test-Path -LiteralPath $config) {
        & $nebula -test -config $config
        if ($LASTEXITCODE -eq 0) {
            Say 'Configuration validated with nebula -test'
        } else {
            Warn 'nebula -test reported a problem; check config.yml before starting the service'
        }
    } else {
        Say 'No config.yml present; skipped validation'
    }
} else {
    Say 'nebula.exe not found; skipped config validation'
}

# --- service ----------------------------------------------------------------
if ($NoStart) {
    Say 'Service start skipped (-NoStart)'
    Say 'Done. Start Nebula manually or with your service manager.'
    exit 0
}

if (-not $isWindowsHost) {
    Say 'Service management is Windows-only; files are installed'
    exit 0
}

$svc = Get-Service -Name $Service -ErrorAction SilentlyContinue
if (-not $svc) {
    if (-not $nebula) {
        Warn "nebula.exe not found; cannot install the '$Service' service"
        exit 1
    }
    Say "Installing the '$Service' Windows service..."
    & $nebula -service install -config $config
    Start-Sleep -Seconds 1
    $svc = Get-Service -Name $Service -ErrorAction SilentlyContinue
}

if (-not $svc) {
    Warn "service '$Service' is not installed; files are in place, start Nebula manually"
    exit 1
}

try {
    if ($svc.Status -eq 'Running') {
        Restart-Service -Name $Service -Force
        Say "Restarted service '$Service'"
    } else {
        Start-Service -Name $Service
        Say "Started service '$Service'"
    }
} catch {
    Warn "could not (re)start service '$Service': $($_.Exception.Message)"
    exit 1
}
