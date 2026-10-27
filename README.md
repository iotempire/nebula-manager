<p align="center"><a href="https://github.com/ulno/nebula-manager/"><img src="resources/img/banner-web.png" alt="Nebula Manager"></a></p>

<p align="center">
  <a href="/LICENSE"><img alt="License: MIT" src="https://img.shields.io/badge/license-MIT-green.svg"></a>
  <a href="https://www.gnu.org/software/bash/"><img alt="Shell: Bash" src="https://img.shields.io/badge/language-bash-blue.svg"></a>
  <a href="https://kernel.org/"><img alt="Platform: Linux" src="https://img.shields.io/badge/platform-Linux-informational?style=flat-square"></a>
  <a href="https://github.com/slackhq/nebula"><img alt="Nebula" src="https://img.shields.io/badge/nebula-supported-brightgreen"></a>
  <a href="https://github.com/ulno/nebula-manager/commits"><img alt="Last Commit" src="https://img.shields.io/github/last-commit/ulno/nebula-manager"></a>
  <a href="https://github.com/ulno/nebula-manager/releases"><img alt="Latest Release" src="https://img.shields.io/github/releases/ulno/nebula-manager?sort=semver&display_name=tag&style=flat-square"></a>
</p>

> **Nebula Manager — academic edition.** ulno's academic spin on Jordan Hillis'
> Nebula Manager **v2.0.0**. One friendly tool to install, configure, and operate
> [Slack Nebula](https://github.com/slackhq/nebula): certificates, workspaces,
> per-node configs, firewall policy, bundles, fleet deployment, diagnostics and
> updates — with a plain-text UI and a complete headless CLI.

> **v2 runs as a normal user.** The old "must be root" model is gone. The tool
> runs least-privilege and calls `sudo` only for the specific action that needs
> it (writing `/etc/nebula`, controlling systemd units, touching host firewall
> state). Certificate work, config generation, bundles, benchmarks and
> diagnostics never need root.

**New here?** [Quick start](#quick-start) · [Getting started](docs/getting-started.md) · [User stories](docs/user-stories.md)

**Jump to:** [Why this fork?](#why-this-fork) · [What you can do](#what-you-can-do) · [Documentation map](#documentation-map) · [Installation](#installation) · [Security](#security--privilege-model) · [Testing](#testing)

---

## Why this fork?

The upstream project is an operations tool. The academic edition grew out of
teaching Nebula in networking classes, where the requirements are slightly
different:

- **Least privilege is non-negotiable** — students should never run a manager
  as root; elevation must be narrow, explained and logged.
- **The PKI is user-owned** — a class CA, a demo CA and a real CA coexist in
  ordinary directories, with explicit precedence and no sudo.
- **A node is cert + key + config** — the deployable `<name>.yml` lives next to
  the certificate, is generated at signing time, and is what bundles reuse.
- **Batch operations must be safe** — group edits, CA-rotation re-signing and
  fleet-wide firewall changes are previewed, snapshotted and scriptable.
- **The UI must be teachable** — plain numbered menus by default, a preserved
  transcript, searchable menus, and the same actions under the hood in the CLI.
- **The documentation is course material** — distro guides, story-driven
  examples (`theprof` and the students), and a test suite that serves as
  executable acceptance criteria.

The full story, design principles and extension history are in
**[docs/motivation.md](docs/motivation.md)**.

```text
ulno's academic spin - orig: Jordan Hillis v2.0.0
```

---

## Quick start

### A. Nebula is already running on this host

```bash
git clone https://github.com/ulno/nebula-manager.git
cd nebula-manager
./nebula-manager import     # detects service, config and certs; proposes a manager config
./nebula-manager            # opens the plain-text menu
```

`import` never elevates silently. Reading a service-owned `/etc/nebula/config.yml`
asks once for temporary sudo and prints the exact command.

```text
=~=~=~=~=~=~=~=~=~=~=~[ Main Menu ]~=~=~=~=~=~=~=~=~=~=~=
Type a number; Enter = Exit; /keyword = search all menus (e.g. /firewall); ? = help
Instance: default (nebula.service)
Nebula config: /etc/nebula/config.yml
Certificates: /home/theprof/keys/nebula (5 .crt)
 1. 📜 Certificates (CA, nodes, groups)
 2. 📤 Fleet (croc, SSH)
 ...
```

A longer transcript is in **[docs/preview.md](docs/preview.md)**.

### B. Start a new mesh (CA → lighthouse → clients)

```bash
# 1. A user-owned PKI store (no root)
./nebula-manager ca   --name MyMeshCA --cert-dir ~/keys/nebula
./nebula-manager sign --name vps.example --ip 10.100.0.1/24 \
    --groups lighthouse --cert-dir ~/keys/nebula
./nebula-manager sign --name laptop1  --ip 10.100.0.2/24 \
    --groups home --cert-dir ~/keys/nebula

# 2. Ready-to-deploy client configs live next to the certs:
#    ~/keys/nebula/laptop1.yml, ~/keys/nebula/vps.example.yml
./nebula-manager cert config generate --all --cert-dir ~/keys/nebula

# 3. A self-contained bundle for the client
./nebula-manager cert bundle laptop1 --out ~/Downloads
```

Install Nebula on the lighthouse, copy `vps.example.yml` to
`/etc/nebula/config.yml`, place the cert/key/CA in `/etc/nebula/`, and start the
service. Clients can use the bundle's `install.sh` / `install.ps1`.

Everything for one node lives together, which is the core mental model:

```text
~/keys/nebula/
├── ca.crt
├── ca.key
├── laptop1.crt
├── laptop1.key
└── laptop1.yml      # deployable client config (generated next to the cert)
```

### C. Script it

Every menu action has a headless equivalent:

```bash
./nebula-manager cert list --cert-dir ~/keys/nebula
./nebula-manager cert firewall --from-group home --select all --yes
./nebula-manager cert bundle laptop1 --out ~/Downloads
./nebula-manager fleet croc --select group:students --policy students
./nebula-manager diag
./nebula-manager --help
```

### Common one-liners

| Task | Command |
|---|---|
| List certificates | `nebula-manager cert list` |
| Sign a node | `nebula-manager sign --name node1 --ip 10.100.0.2/24 --groups home` |
| Generate/refresh node configs | `nebula-manager cert config generate --all --force` |
| Re-issue everything after a CA rotation | `nebula-manager cert resign-all --yes` |
| Allow inbound only from a group | `nebula-manager cert firewall --from-group home --select all --yes` |
| Export a client bundle | `nebula-manager cert bundle node1 --out ~/Downloads` |
| Share a class fleet over croc | `nebula-manager fleet croc --select group:students --policy students` |
| Diagnostics | `nebula-manager diag` |

---

## What you can do

| Area | Highlights |
|---|---|
| **Setup** | first-run Manager Setup (import/update from this host, import a client bundle, create/browse/download `nebula-manager.conf`), instance management → [getting-started.md](docs/getting-started.md) |
| **Certificates** | CA creation, signing (including mobile `--in-pub`/QR), group editing, re-sign all after a CA rotation, expiry, revoke, user-owned workspaces → [certificates.md](docs/certificates.md) |
| **Node configs** | `<name>.yml` next to the cert/key, generated at signing time, editable, reused by bundles → [certificates.md](docs/certificates.md#per-node-client-configs-nameyml-next-to-the-certificate) |
| **Bundles** | cert/key/CA + config, Linux/macOS `install.sh`, Windows `install.ps1`, config diffs, cert-only refresh, HTTP/croc one-liners → [bundles.md](docs/bundles.md) |
| **Firewall** | this host's rules with a group picker, policy packs, batch node firewalls (lighthouse-safe) → [firewall.md](docs/firewall.md) |
| **Configuration** | validate/edit the Nebula `config.yml` on a working copy, service restart, policy packs, name resolution → [usage.md](docs/usage.md), [dns.md](docs/dns.md) |
| **Fleet** | `fleet croc` for a class (one code per node), `fleet ssh` with diff/backup/validate/restart → [fleet.md](docs/fleet.md) |
| **DNS** | lighthouse `serve_dns`, client resolver setup, boot hook → [dns.md](docs/dns.md) |
| **Diagnostics** | TUN IP, listening UDP socket, certificate expiry; `listen.port`/auto-detect/`default_port`; ping and `iperf3` benchmarks → [usage.md](docs/usage.md) |
| **Nebula lifecycle** | install/update from official releases with rollback, auto-update scheduler, service control → [usage.md](docs/usage.md) |
| **Adoption** | `import` discovers a running Nebula and proposes `nebula-manager.conf` → [getting-started.md](docs/getting-started.md) |
| **Safety** | dry runs, diffs, `*.crt.bak`, datestamped `backups/`, optional git snapshots, action log → [certificates.md](docs/certificates.md#store-history-backups--git) |
| **Updates** | Nebula update with rollback; self-update check with fork/upstream resolution → [operations.md](docs/operations.md#update-checks--forks) |
| **Release** | one-`curl` single-file artifact (`make build`), checksum, self-update → [development.md](docs/development.md#single-file-release-build) |

---

## Documentation map

| Document | What is inside |
|---|---|
| **[Getting started](docs/getting-started.md)** | three quick-start paths, installation, dependencies, `nebula-manager.conf`, instances |
| **[Certificates & workspaces](docs/certificates.md)** | signing, mobile certs, groups, re-signing, per-node configs, store history |
| **[Client bundles & installers](docs/bundles.md)** | export, self-contained installers, sharing, importing on the client |
| **[Firewall](docs/firewall.md)** | per-host rules, group semantics, policy packs, batch node firewall |
| **[Name resolution](docs/dns.md)** | lighthouse DNS, `resolvectl`, boot hook |
| **[Fleet deployment](docs/fleet.md)** | croc mass sharing, SSH push, reachability probing |
| **[Usage & CLI reference](docs/usage.md)** | interactive menus, every headless command, flags, env vars, debug modes |
| **[Operations & troubleshooting](docs/operations.md)** | FAQ, runtime notes, update checks and forks |
| **[Architecture, security & development](docs/development.md)** | modules, privilege model, tests, security notes |
| **[Preview](docs/preview.md)** | real plain-menu transcripts |
| **[Motivation & history](docs/motivation.md)** | why the academic edition exists, design principles, credits |
| **[User stories](docs/user-stories.md)** | `theprof` and the students — the workflows the tool is built around |
| **[Linux distribution guides](docs/linux-distros.md)** | Ubuntu/Debian/Mint, Fedora/RHEL, Arch/CachyOS, host firewalls, yq v4 |
| **[Roadmap & TODO](docs/roadmap.md)** | implemented features, open work, manual platform confirmation |

---

## Installation

Development happens in the modular source tree (`nebula-manager` **plus the
`lib/` directory**). Every GitHub Release also ships a **self-contained single
file** with the modules and runtime assets embedded, so deployment can be one
`curl`.

### Single-file release (one curl)

```bash
curl -fsSL https://github.com/ulno/nebula-manager/releases/latest/download/nebula-manager -o nebula-manager
curl -fsSL https://github.com/ulno/nebula-manager/releases/latest/download/nebula-manager.sha256 -o nebula-manager.sha256
sha256sum -c nebula-manager.sha256
chmod +x nebula-manager
./nebula-manager --version
```

The single file needs no `lib/` directory: on first run it materialises the
embedded config template and client-bundle installers into
`${XDG_CACHE_HOME:-~/.cache}/nebula-manager/single-file-assets/<version>-<asset-hash>/`.
Self-update uses the same release asset; point a fork at its own asset with
`NEBULA_MANAGER_SINGLE_URL`.

Build it locally with:

```bash
make build          # -> dist/nebula-manager + dist/nebula-manager.sha256
```

### From source (development)

```bash
git clone https://github.com/ulno/nebula-manager.git
cd nebula-manager
./nebula-manager          # first run offers Manager Setup
```

System-wide (optional, one `sudo`):

```bash
sudo install -d /usr/local/bin /usr/local/lib/nebula-manager/lib
sudo install -m755 nebula-manager /usr/local/bin/nebula-manager
sudo cp -a lib/. /usr/local/lib/nebula-manager/lib/
```

The modular entrypoint finds `lib/` via `$NEBULA_MANAGER_LIB`, `<dir of
entrypoint>/lib`, `/usr/local/lib/nebula-manager/lib`, or
`/usr/lib/nebula-manager/lib`. The single-file build needs none of this.

### Dependencies

**Debian / Ubuntu / Linux Mint**

```bash
sudo apt update
sudo apt install -y gawk curl findutils grep jq sed sudo systemd tar wget coreutils iperf3 iputils-ping whiptail zip
```

`yq` must be **mikefarah v4** (the archive's `yq` on older Debian/Ubuntu is the
incompatible Python v3):

```bash
sudo wget -qO /usr/local/bin/yq https://github.com/mikefarah/yq/releases/latest/download/yq_linux_amd64
sudo chmod +x /usr/local/bin/yq && yq --version   # should say v4.x
```

**Fedora / RHEL family**

```bash
sudo dnf install -y gawk curl findutils grep jq sed sudo systemd tar wget coreutils iperf3 iputils newt zip yq
```

**Arch Linux / CachyOS**

```bash
sudo pacman -S --needed gawk curl findutils grep jq sed sudo systemd tar wget go-yq coreutils iperf3 iputils libnewt zip
```

Per-distro details, SELinux and host-firewall notes:
**[docs/linux-distros.md](docs/linux-distros.md)**. The tool auto-detects the
distribution and prints the matching command if a dependency is missing.

---

## Security & privilege model

- The tool runs **as you**. `elevate()` is the single `sudo` choke point;
  `path_requires_root()` decides whether a target path needs elevation.
- Elevated actions are limited to: writing system paths (e.g. `/etc/nebula`),
  systemd (`daemon-reload`, `enable`, `start/stop/restart`), host firewall/kernel
  state, and installing binaries.
- Reading a service-owned Nebula config asks **once**, showing the reason and the
  exact command; the derived header values are cached, so later starts do not
  prompt.
- Certificate stores, policy packs, per-node configs, logs and backups are
  user-owned. Before a certificate or config is replaced, a snapshot is taken
  (git commit when tracked, otherwise `backups/<timestamp>-…/ACTION.txt`).
- Bundles contain a **private key**. They are credentials: the generated
  `fleet-bundles-*` directories and `*-nebula-bundle.*` archives are git-ignored.

Full details: **[docs/development.md#privilege-model](docs/development.md#privilege-model)**
and **[docs/operations.md](docs/operations.md)**.

---

## Testing

```bash
./run_tests.sh     # or: make test
make lint          # bash -n + shellcheck (errors) over entrypoint, modules and tests
make build         # dist/nebula-manager (single-file release artifact)
```

The suite is dependency-free: a mock `sudo` records every invocation, so tests
prove that unprivileged work never elevates and that privileged stores do. The
same suite exercises CLI parsing, CA rotation, group/firewall batches, bundles,
fleet helpers, DNS and the store history. See
**[docs/development.md#testing](docs/development.md#testing)**.

---

## Learn more

- **Nebula docs:** <https://nebula.defined.net/docs/>
- **Nebula quick start:** <https://nebula.defined.net/docs/guides/quick-start/>
- **Configuration reference:** <https://nebula.defined.net/docs/config/>
- **`static_host_map`:** <https://nebula.defined.net/docs/config/static-host-map/>
- **Example `config.yml`:** <https://raw.githubusercontent.com/slackhq/nebula/master/examples/config.yml>
- **Nebula releases:** <https://github.com/slackhq/nebula/releases>

---

## Contributing

Pull requests are welcome. For major changes, please open an issue first to
discuss the change. Before sending a patch, run `make lint` and `./run_tests.sh`;
see [Development](docs/development.md) for the test harness and checksum rules.

---

## License & credits

[MIT](LICENSE) — free to use, modify, and distribute.

- Original project and v2.0.0: [Jordan Hillis](https://github.com/jordanhillis)
- Academic edition, extensions and documentation: **ulno**
  ([ulno/nebula-manager](https://github.com/ulno/nebula-manager))

The least-privilege refactor, modular `lib/` layout, `import` wizard, server
management, plain-first TUI, mobile certificates, per-node configs, batch
firewall/group operations and the distribution guides were developed for
teaching Nebula in a networking class.

```text
ulno's academic spin - orig: Jordan Hillis v2.0.0
```
