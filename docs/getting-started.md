# Getting started

[← Back to README](../README.md) · [Documentation map](../README.md#documentation-map)

---

This guide takes you from zero to a working mesh — or adopts an existing Nebula
installation — and explains the tool's own configuration file.

## Quick start: three ways in

### A. Nebula is already running on this host

```bash
git clone https://github.com/iotempire/nebula-manager.git
cd nebula-manager
./nebula-manager import     # detect service, config, certs; write nebula-manager.conf
./nebula-manager            # opens the menu with the detected state
```

`import` never elevates silently: reading a service-owned `/etc/nebula/config.yml`
asks once for temporary sudo and shows the exact command. From the menu, use
**Manager Setup** to review/refresh the config and **Certificates** to work with
the existing CA.

### B. Start a new mesh (CA → lighthouse → clients)

```bash
# 1. A user-owned PKI store (no root)
./nebula-manager ca   --name MyMeshCA --cert-dir ~/keys/nebula
./nebula-manager sign --name vps.example --ip 10.100.0.1/24 \
    --groups lighthouse --cert-dir ~/keys/nebula
./nebula-manager sign --name laptop1  --ip 10.100.0.2/24 \
    --groups home --cert-dir ~/keys/nebula

# 2. Ready-to-deploy client configs live next to the certs
./nebula-manager cert config generate --all --cert-dir ~/keys/nebula

# 3. Bundles for the clients
./nebula-manager cert bundle laptop1 --out ~/Downloads
```

Install Nebula on the lighthouse, copy `vps.example.yml` to
`/etc/nebula/config.yml`, put the cert/key/CA in `/etc/nebula/`, and start the
service. Clients can use the bundle's self-contained installer.

### C. Headless, scriptable actions

```bash
./nebula-manager cert list --cert-dir ~/keys/nebula
./nebula-manager cert firewall --from-group home --select all --yes
./nebula-manager cert bundle laptop1 --out ~/Downloads
./nebula-manager fleet croc --select group:students --policy students
./nebula-manager diag
./nebula-manager --help
```

The menus are the primary interface; every menu action has a headless equivalent
in the [usage & CLI reference](usage.md).

## 📥 Installation

The canonical source is `nebula-manager` **plus the `lib/` directory**;
`lib/` stays where development happens. For deployment you can use the
self-contained single-file release, clone the repository, or fetch the modules.

### 🔹 Option 1: Single-file release (one curl)

```bash
curl -fsSL https://github.com/iotempire/nebula-manager/releases/latest/download/nebula-manager -o nebula-manager
curl -fsSL https://github.com/iotempire/nebula-manager/releases/latest/download/nebula-manager.sha256 -o nebula-manager.sha256
sha256sum -c nebula-manager.sha256
chmod +x nebula-manager
./nebula-manager            # no sudo needed
```

The release asset embeds the modules and the runtime assets (config template
plus the client-bundle installers), so no `lib/` directory is needed. A matching
`nebula-manager.sha256` is published next to it; updates use the same release
asset (override with `NEBULA_MANAGER_SINGLE_URL`).

### 🔹 Option 2: Git clone (recommended for development)

```bash
git clone https://github.com/iotempire/nebula-manager.git
cd nebula-manager
./nebula-manager            # no sudo needed
```

Build the single-file artifact locally with `make build` (or
`./build_single.sh`), which writes `dist/nebula-manager` and its checksum.

### 🔹 Option 3: Download the entrypoint and modules

```bash
mkdir -p nebula-manager/lib/bundle && cd nebula-manager
base=https://raw.githubusercontent.com/iotempire/nebula-manager/refs/heads/main
curl -fsSL "$base/nebula-manager" -o nebula-manager
for m in ui.sh pki.sh bench.sh system.sh import.sh policy.sh select.sh store.sh fleet.sh nebula-manager.conf.template; do
  curl -fsSL "$base/lib/$m" -o "lib/$m"
done
for m in install.sh install.ps1 README.txt; do
  curl -fsSL "$base/lib/bundle/$m" -o "lib/bundle/$m"
done
chmod +x nebula-manager
./nebula-manager
```

### 🔹 Install system-wide (optional, needs sudo once)

Use **Updates & Install ▸ Install Script to System** inside the TUI, or copy manually:

```bash
sudo install -d /usr/local/bin /usr/local/lib/nebula-manager/lib
sudo install -m755 nebula-manager /usr/local/bin/nebula-manager
sudo cp -a lib/. /usr/local/lib/nebula-manager/lib/
```

The modular entrypoint auto-discovers `lib/` in the following order:
`$NEBULA_MANAGER_LIB` → `<dir of entrypoint>/lib` → `/usr/local/lib/nebula-manager/lib` → `/usr/lib/nebula-manager/lib`.
The single-file build installs only the script and needs none of this.

---

## 📦 Dependencies

Nebula Manager checks for required tools on first run and prints an install
command if any are missing (skippable via `ignore_dependency_check` in the conf).

**Required:** `gawk` (`awk`), `curl`, `findutils` (`find`), `grep`, `jq`, `sed`, `sudo`, `systemd` (`systemctl`), `tar`, `wget`, `coreutils` (`sha256sum`), `iputils-ping`
**Optional:** `yq` — **mikefarah v4 only**, used by the config and firewall editors (Fedora `yq`, Arch `go-yq`, or the upstream binary); `iperf3` (bandwidth tests); `whiptail` (graphical file/dir picker; menus are plain by default); `zip` (client bundles; falls back to `tar.gz`); `unzip` (installing a bundle via the README one-liner); `croc` (fleet mass deployment without opening ports); `nc`/`netcat` (fast SSH port probing; falls back to bash `/dev/tcp`); `ssh` (fleet SSH push and probing)

> 📖 Per-distribution manuals (Ubuntu/Debian/Mint, Fedora/RHEL, Arch/CachyOS,
> including SELinux and firewall notes): **[Linux distribution guides](linux-distros.md)**.

### Install all dependencies

**Debian / Ubuntu / Linux Mint**

```bash
sudo apt update
sudo apt install -y gawk curl findutils grep jq sed sudo systemd tar wget coreutils iperf3 iputils-ping whiptail zip
```

⚠️ **Do not** `apt install yq` on Ubuntu/Mint/Debian 12 — that is the incompatible Python yq v3. Install mikefarah's v4 binary:

```bash
sudo wget -qO /usr/local/bin/yq https://github.com/mikefarah/yq/releases/latest/download/yq_linux_amd64
sudo chmod +x /usr/local/bin/yq && yq --version   # should say v4.x
```

(Debian 13/trixie also has `yq-go` in its archive.)

**Fedora / RHEL / CentOS / Rocky Linux / AlmaLinux**

```bash
sudo dnf install -y gawk curl findutils grep jq sed sudo systemd tar wget coreutils iperf3 iputils newt zip yq
```

(Fedora's `yq` is mikefarah v4; `newt` provides `whiptail`.)

**Arch Linux / CachyOS**

```bash
sudo pacman -S --needed gawk curl findutils grep jq sed sudo systemd tar wget go-yq coreutils iperf3 iputils libnewt zip
```

(`go-yq` provides mikefarah yq v4 as `/usr/bin/yq`; `libnewt` provides `whiptail`.)

Supported distributions are auto-detected from `/etc/os-release` (Debian/Ubuntu, RHEL
family, Arch/CachyOS). On an unrecognised distribution the tool still runs as long
as the required tools are present — it just can't suggest the install command.

## 🧩 Configuration: `nebula-manager.conf`

Nebula Manager reads an **INI-style** config (with sections). The path is
resolved as `--config` / `$NEBULA_MANAGER_CONF` → an existing
`/etc/nebula/nebula-manager.conf` → `$XDG_CONFIG_HOME/nebula-manager/nebula-manager.conf`.

### First run — and the Manager Setup menu

If no `nebula-manager.conf` is found (or none has usable `[server.*]` entries),
the tool opens the **Manager Setup menu** instead of dead-ending on a download.
The menu first shows what it **detected on this host**, then offers the ways to
get a config:

```text
=~=~=~=~=~=~=~=~=~=~=~[ Main Menu > Manager Setup ]~=~=~=~=~=~=~=~=~=~=~=
First run: import this host, import a client bundle, or create/browse a manager config.
Manager config: none yet (/home/you/.config/nebula-manager/nebula-manager.conf)
Nebula: installed (v1.11.2) - nebula.service running
Certificates: /home/you/keys/nebula (7 .crt)
 1. 📦 Import / update from this host
 2. 📤 Import client bundle (.zip/.tar.gz)
 3. 🆕 Create config from template
 4. 🔍 Browse for a config file
 5. 📝 Edit config
 6. 🗑️ Delete config
 7. 📄 Manage instances
 8. 🗝️ Certificate workspace
 9. 🔄 Reload & continue
 10. 🚪 Exit
 [?] Choose an option [1-10, Enter=Exit, /=search, ?=help]:
```

This is the default **plain** menu; `NEBULA_UI=whiptail` shows the same entries
in a curses box (still used automatically for file browsing). The status lines
are recomputed on every redraw, so after an action (e.g. import) you immediately
see the new state. Reached from the main menu, the Manager Setup menu is the same
but without *Exit* (it has a *Back* instead).

- **Import / update** runs the read-only detector (`lib/import.sh`): it finds the
  systemd unit, its `ExecStart … -config`, `tun.dev`, `listen.port`, the
  lighthouse setting, the first `static_host_map` peer and the pki directory,
  then proposes a `nebula-manager.conf`. Re-running it **updates** an existing
  config — a timestamped backup (`*.bak.YYYYmmdd-HHMMSS`) is kept first.
- **Create** copies the bundled template from `lib/`
  (`lib/nebula-manager.conf.template`) — **offline, no root**.
- **Browse** opens a file browser (a `whiptail` menu navigator, or dialog's
  native `--fselect`) and validates that the picked file really is a manager
  conf (not Nebula's own `config.yml`).
- **Delete** removes the active config (elevating only if it lives in a
  privileged directory such as `/etc/nebula`).

The menu never changes anything without an explicit choice, and never needs root
just to *show* the config or to write the per-user default under
`$XDG_CONFIG_HOME`.

### Managing the config headlessly

```bash
./nebula-manager config path                 # print the resolved config path
./nebula-manager config init [--force]       # create it from the bundled template
./nebula-manager config init --config /etc/nebula/nebula-manager.conf
./nebula-manager config edit                 # open it in $EDITOR
./nebula-manager config refresh              # download the latest template
./nebula-manager config remove [--force]     # delete the active config
```

You can always point at any file with `--config`:

```bash
./nebula-manager --config=/path/to/nebula-manager.conf
```

### File format

- Comments use `#` (inline comments supported).
- Sections use `[global]` and `[server.<name>]`.
- Keys are `key=value`.

#### `[global]` keys

| Key | Description | Default |
|---|---|---|
| `bin_path` | Directory containing `nebula`/`nebula-cert` and where the tool may install itself | `/usr/local/bin` |
| `cert_folder` | Relative folder under each server's Nebula dir to store certs | `certs` |
| `cert_dir` | Explicit certificate workspace (equivalent to `NEBULA_KEYS_DIR`) | *(unset)* |
| `default_port` | Nebula listen port used by diagnostics when `config.yml` has `port: 0` | `4242` |
| `use_color` | Enable colored output | `true` |
| `use_icons` | Enable UI icons/symbols | `true` |
| `disable_version_check` | Skip script version checks | `false` |
| `ignore_dependency_check` | Skip dependency verification | `false` |
| `ignore_nebula_update` | Don't prompt about Nebula updates | `false` |

#### `[server.<name>]` keys

| Key | Description |
|---|---|
| `dir` | Nebula working dir for this server (e.g., `/etc/nebula/my-edge`) |
| `service` | systemd unit for this server (e.g., `/etc/systemd/system/nebula@service`) |
| `enabled` | `true` to include this server in batch operations |

### Example

```ini
[global]
bin_path=/usr/local/bin
cert_folder=certs
use_color=true
use_icons=true
disable_version_check=false
ignore_dependency_check=false
ignore_nebula_update=false

[server.edge-1]
dir=/etc/nebula/edge-1
service=/etc/systemd/system/nebula-edge1.service
enabled=true

[server.lighthouse]
dir=/etc/nebula/lighthouse
service=/etc/systemd/system/nebula-lighthouse.service
enabled=true

[server.lab]
dir=/etc/nebula/lab
service=/etc/systemd/system/nebula-lab.service
enabled=false
```

---

## ➕ Adding & ➖ Removing Instances

Each **instance** is a `[server.<name>]` section in `nebula-manager.conf` (the
key name is historical — the CLI accepts `instance` and `server`
interchangeably). Append a section, then ensure the referenced **Nebula dir**
contains a valid `config.yml` (a template is downloaded if missing) and the
**systemd unit** exists. Set `enabled=false` to exclude an instance from batch
operations, or delete its section to remove it entirely.

---

## Where to next?

- **Certificates & workspaces** → [certificates.md](certificates.md)
- **Client bundles & installers** → [bundles.md](bundles.md)
- **Firewall** → [firewall.md](firewall.md)
- **Full CLI reference** → [usage.md](usage.md)
