# Client bundles & installers

[← Back to README](../README.md) · [Documentation map](../README.md#documentation-map)

---

A bundle is the unit you hand to a machine: certificate, private key, CA,
and a config. This chapter covers export, the self-contained installers,
sharing one-liners (HTTP/croc), and importing a bundle on the client.

> Bundles contain a **private key**. Treat them like credentials; the generated
> `fleet-bundles-*` directories and `*-nebula-bundle.*` archives are git-ignored.

## Bundles in practice

### Exporting a client bundle

**Certificates ▸ Bundle / Export Client Certificate** lists every certificate
that can actually be exported (a matching `.crt` and `.key`), showing its
overlay IP and groups. CAs and mobile certs signed with `--in-pub` are skipped
because there is no local private key to ship. In **plain mode you can type a
(partial) name or path directly** at the selection prompt instead of picking a
number; the curses menu offers a *Type a certificate name manually…* entry.
Then confirm the output directory in a browser/prompt.

Headless usage accepts a **unique substring** (case-insensitive) instead of the
exact name, and lists candidates when the name is omitted or ambiguous:

```bash
./nebula-manager cert bundle                    # list exportable certificates
./nebula-manager cert bundle host1              # exact or unique substring
./nebula-manager cert bundle host1 --out ~/Downloads
./nebula-manager cert bundle host1 ./bundles    # positional dir still works
./nebula-manager cert bundle host1 --firewall permissive
./nebula-manager cert bundle host1 --firewall pack:home  # same as --policy home
./nebula-manager cert bundle host1 --share-url https://class.example/bundles
./nebula-manager cert bundle host1 --croc-code 1234-abcd  # fill the croc one-liner
export NEBULA_BUNDLE_DIR=~/exports              # default destination
export NEBULA_BUNDLE_SHARE_URL=https://class.example/bundles
export NEBULA_BUNDLE_CROC_CODE=1234-abcd
```

**CLI** destination precedence: `--out` → `NEBULA_BUNDLE_DIR` → the directory
nebula-manager was started in → `~/Downloads` → `~/tmp` → `$TMPDIR`.

**TUI** (*Certificates ▸ Bundle / Export*) first shows a destination menu with
sensible defaults: `NEBULA_BUNDLE_DIR` (when set) → the **last used** folder →
`<cert-dir>/export` → `~/Downloads/nebula-bundles` → `~/tmp/nebula-bundles`
(only when `~/tmp` exists) → *Browse…* or *Type a path…*. Enter picks the first
entry, and the choice is remembered in
`~/.config/nebula-manager/bundle-dir`.

The archive contains the cert, key, `ca.crt`, `config.yml.template`,
**`install.sh`**, **`install.ps1`** and a `README.txt` with client instructions,
and is written mode **0600** because it holds the private key.

#### Self-contained installers

The bundle no longer needs nebula-manager on the client:

```text
install.sh    Linux/macOS: installs cert/key/CA + config, validates,
              then enables/restarts systemd (or brew/launchd on macOS)
install.ps1   Windows: same, using nebula.exe -service install/start
README.txt    files, install commands, one-liners, security note
```

```bash
# Linux / macOS (system install)
sudo bash install.sh
# refresh only the certificate/key/CA (keep config.yml):
sudo bash install.sh --certs-only
# user-owned directory, no sudo, no service:
bash install.sh --dir ~/nebula --no-start

# Windows (elevated PowerShell)
powershell -ExecutionPolicy Bypass -File .\install.ps1
powershell -ExecutionPolicy Bypass -File .\install.ps1 -CertsOnly
```

Both installers:

- are **portable where it matters**: the file/config/backup logic in
  `install.ps1` runs under `pwsh` on Linux/macOS too (covered by the test suite),
  with only elevation/ACLs/Windows-service handling guarded by OS detection;
- back up existing files as `<file>.bak.YYYYmmdd-HHMMSS`;
- **`--certs-only` / `-CertsOnly`** refreshes just cert/key/CA and leaves an
  existing `config.yml` untouched (useful after a re-sign or group change);
- **stop and show a diff if `config.yml` already exists**, asking before
  overwriting (`--yes` / `-Yes` for automation; a non-interactive shell without
  `--yes`/`-Yes` refuses to touch it);
- rewrite `/etc/nebula` in the template when `--dir` / `-Dir` is used;
- set the private key mode `600` (Linux/macOS) or restrict it to
  `SYSTEM`+`Administrators` (Windows);
- validate with `nebula -test` when the binary is available;
- (re)start the service unless `--no-start` / `-NoStart` is given.

#### Sharing one-liners

Every bundle creation prints ready-to-share commands and embeds them in
`README.txt`. Use `--share-url` (or `NEBULA_BUNDLE_SHARE_URL`) and
`--croc-code` (or `NEBULA_BUNDLE_CROC_CODE`) to fill in real values:

```bash
# HTTP: serve the folder, then let clients run the one-liner
python3 -m http.server 8000 --directory ~/exports
# client:
tmp=$(mktemp -d) && curl -fsSL https://class.example/bundles/host1-nebula-bundle.zip \
  -o "$tmp/b.zip" && unzip -q "$tmp/b.zip" -d "$tmp" && sudo bash "$tmp/install.sh"

# croc (no open ports, good behind NAT/eduroam)
croc send ~/exports/host1-nebula-bundle.zip       # share the code it prints
# client:
tmp=$(mktemp -d) && cd "$tmp" && croc --yes CODE && unzip -q '*.zip' && sudo bash install.sh
```

Windows equivalents (PowerShell `Invoke-WebRequest`/`Expand-Archive` or
`croc`) are in the bundle's `README.txt`. The classic route — clone the repo and
use **Manager Setup ▸ Import client bundle** — still works; cloning is optional
for a client install.

The template is **populated from the running Nebula config** when one can be
read (`static_host_map`, `lighthouse.hosts`/`interval`, `punchy`, `listen`,
`tun` and the `firewall` policy). If no readable local config exists, it derives
lighthouses from the `[server.*]` entries plus the certificate workspace. Any
value it still cannot determine is left commented out, listed at the top of the
file, and reported as a warning — so a bundle never silently ships a config with
missing lighthouses.

Before writing, the bundle flow shows the **firewall menu** preselected with the
node's saved choice (from certificate creation, or the last choice). Accept it
with Enter, or override it for this bundle: a policy pack is embedded, while
*permissive* / *Nebula defaults* / *copy this host's firewall* render the
corresponding `firewall:` block.

### Importing a bundle on the client

On a machine that already has nebula-manager, **Manager Setup ▸ Import client
bundle (.zip/.tar.gz)** opens a file browser, extracts
the archive safely, validates `ca.crt` plus the matching `<name>.crt`/`<name>.key`,
and installs them together with the bundled `config.yml.template` (renamed to
`config.yml`, with `/etc/nebula` rewritten if you choose another target).
On a bare client, use the self-contained `install.sh` / `install.ps1` from the
archive instead (see above).

The install-directory menu explains the trade-off and offers a default:

```text
Where should the bundle be installed?

/etc/nebula is read by the system Nebula service (writes need sudo).
/home/you/nebula is user-owned (no sudo, but only manual runs use it).
Press Enter for /etc/nebula, or type a path directly.
  1. /etc/nebula (system service; needs sudo) [default]
  2. /home/you/nebula (user-owned; no sudo)
  3. Browse for a directory...
  4. Type a path...
```
Existing files are backed up with a timestamp; an existing `config.yml` is never
replaced without confirmation or `--force`. It then creates/updates
`nebula-manager.conf` (`[server.<name>]`, `dir=<target>`, `role=client`), offers
to **enable and start the systemd service** when it is installed but not running,
and reloads straight into the main menu.

Headless equivalent:

```bash
./nebula-manager import --bundle ~/Downloads/client-nebula-bundle.zip --yes
./nebula-manager import --bundle bundle.tar.gz --dir /srv/nebula --yes --force
./nebula-manager import --bundle bundle.zip --dry-run   # inspect, write nothing
```

Only the writes are elevated (via the usual reasoned sudo prompt); extraction and
validation happen as your normal user.

---

## Where to next?

- **Classroom mass deployment** → [fleet.md](fleet.md)
- **The config that goes inside the bundle** → [certificates.md](certificates.md#per-node-client-configs-nameyml-next-to-the-certificate)
- **Privilege model** → [development.md](development.md#privilege-model)
