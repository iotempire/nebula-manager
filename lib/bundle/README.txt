Nebula client bundle: @NAME@
Generated: @DATE@
Firewall: @POLICY@

Files
  @NAME@.crt           client certificate
  @NAME@.key           client private key (keep secret)
  ca.crt               certificate authority
  config.yml.template  ready-to-install Nebula config
  install.sh           Linux / macOS installer
  install.ps1          Windows installer (PowerShell)
  README.txt           this file

Quick install
  Linux / macOS
      sudo bash install.sh
      # choose another directory:
      sudo bash install.sh --dir /etc/nebula --service nebula.service
      # user-owned test (no sudo, no service):
      bash install.sh --dir ~/nebula --no-start

  Windows (elevated PowerShell)
      powershell -ExecutionPolicy Bypass -File .\install.ps1
      # choose another directory:
      powershell -ExecutionPolicy Bypass -File .\install.ps1 -Dir C:\ProgramData\nebula

  The installer backs up existing files, installs the certificate/key/CA,
  writes config.yml, validates it with `nebula -test`, and (re)starts the
  Nebula service. If config.yml already exists it prints a diff and asks
  before overwriting it.

  Non-interactive: bash install.sh --yes / install.ps1 -Yes
  Files only:      bash install.sh --no-start / install.ps1 -NoStart
  Certificate only: bash install.sh --certs-only / install.ps1 -CertsOnly
                    (refresh cert/key/CA, leave any existing config.yml alone)

One-liners (share the archive, not just this README)
  Linux / macOS, HTTP:
      tmp=$(mktemp -d) && curl -fsSL @HTTP_URL@ -o "$tmp/b.@EXT@" && @EXTRACT_LINUX@ && sudo bash "$tmp/install.sh"

  Linux / macOS, croc (no open ports, works behind eduroam/NAT):
      Server sends the archive:  croc send @ARCHIVE@
      Client receives + installs:
      tmp=$(mktemp -d) && cd "$tmp" && croc --yes @CROC_CODE@ && @EXTRACT_CROC@ && sudo bash install.sh

  Windows, HTTP (PowerShell):
      $d=Join-Path $env:TEMP 'nebula-bundle'; $z=Join-Path $env:TEMP 'nb.@EXT@'; Invoke-WebRequest '@HTTP_URL@' -OutFile $z; @EXTRACT_WIN@; powershell -ExecutionPolicy Bypass -File (Join-Path $d 'install.ps1')

  Windows, croc:
      cd $env:TEMP; croc --yes @CROC_CODE@
      # then run install.ps1 from the received folder (elevated PowerShell)

Serving the archive yourself
      python3 -m http.server 8000 --directory <folder-with-the-archive>
  then use http://<this-host>:8000/@ARCHIVE@ as the URL above.
  `croc send @ARCHIVE@` needs no open ports: share the code it prints.

Security
  The archive contains a private key. Transfer it only over a trusted channel,
  keep the archive mode 0600, and delete it from the client after installing.

Do I need nebula-manager?
  No. These scripts are self-contained. The classic route (clone the
  nebula-manager repository and use Manager Setup > Import client bundle) still
  works, but cloning is optional for a client install.
