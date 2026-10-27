# Usage & CLI reference

[← Back to README](../README.md) · [Documentation map](../README.md#documentation-map)

---

Nebula Manager is **menu-first**. This chapter documents the interactive flow,
the headless equivalents, global flags, environment variables and debug modes.

## Interactive and headless

Nebula Manager is **menu-driven first**. Run it and everything is selectable from
the numbered menus (plain text by default; file/dir pickers pop up graphically
when `whiptail` is available). The same actions are also available as
headless subcommands for scripting — see *Expert / scriptable* below.

### Interactive (the main way)

```bash
./nebula-manager        # or just: nebula-manager   (once installed)
```

| Menu | What you can do |
|---|---|
| **Manager Setup** | shows the **detected state** (manager config, Nebula service, cert workspace), then: import/update from this host, **import a client bundle (.zip/.tar.gz)**, create, browse, edit, delete `nebula-manager.conf`, manage instances, pick the certificate workspace |
| **Instances** | list / add / enable-disable / remove `[server.*]` entries, and start/stop the selected instance's service |
| **Certificates** | list, create CA, sign, **re-sign all after a CA rotation**, **edit groups in bulk** (add/remove/move/set/rename with a filter), **firewall for nodes in bulk** (group policy, lighthouse-safe), view, expiry, **bundle/export** (pick from a list), **per-node client configs** (`<name>.yml` next to each cert: generate/edit/refresh), revoke, switch workspace, store backup/git |
| **Fleet** | **croc mass deployment** (one code per student/node), **SSH push** of a config/firewall change, and SSH reachability probing |
| **Instance Settings** | validate / edit Nebula `config.yml` (service-owned files are edited on a working copy and saved once with a timestamped backup), edit firewall rules with a **group picker + rule templates + explain**, **policy packs** (embed in bundles / apply / export), **name resolution (Nebula DNS)** |
| **Connectivity** | ping every cert IP; optional `iperf3` test |
| **Diagnostics** | TUN IP, listening UDP socket, certificate expiry; reads a service-owned config once with temporary sudo and caches the header values |
| **Benchmarks** | `iperf3` server / client |
| **Updates & Install** | update Nebula, auto-update scheduler, install the script system-wide / remove Nebula |

The main menu (and *Instance Settings*) prints the **active paths** above the
options, so you can see at a glance which store you are working on:

```text
Instance: default (nebula.service)
Nebula config: /etc/nebula/config.yml
Certificates: /home/you/keys/nebula (7 .crt)
Manager config: /home/you/.config/nebula-manager/nebula-manager.conf
```

**First run** (no config yet) opens the **Manager Setup** menu, which shows what
was detected on this host and lets you *Import / update from this host* (adopt a
running Nebula), *Import client bundle* (install a `.zip`/`.tar.gz` produced by
`cert bundle`), *Create config from template*, or *Browse for a config file* —
then *Manage instances* to add your instances and *Reload & continue* to enter
the main menu.

#### Moving around the menus

The plain menus accept more than numbers:

| Key | Action |
|---|---|
| `1`…`N` | select an entry |
| **Enter** | default: **Back** in a submenu, **Exit** on the main menu (the bold entry) |
| `b`, `back`, `..` | back one menu |
| `m`, `main` | jump straight to the main menu |
| `q`, `quit` | exit at the top level; back in a submenu |
| `/keyword` | search every menu — e.g. `/firewall`, `/dns`, `/ca`, `/nodes` |
| `/` | ask for a search keyword |
| `?` | show these keys |

Every menu prints a one-line purpose/hint; the search also matches those hints
and extra synonyms (`nodes`, `machines`, `systemd`, `pki`, …). Top-level entries
carry a short reminder in brackets, e.g. *Certificates (CA, nodes, groups)*.

Nomenclature used throughout: **nodes** are mesh members (their certificates),
**instances** are local Nebula installations/services, and the **workspace** is
the certificate store.

Handy extras: menus are **plain numbered** by default (easy to script and debug);
file/directory browsing automatically uses `whiptail` when it is installed.
`NEBULA_UI=whiptail nebula-manager` forces the curses UI for the menus too.

Screen clearing is **off by default**, so the menu history, `DEBUG=learn`
commands and any errors remain visible for verification. Use `--clear-screen`
(or `NEBULA_CLEAR_SCREEN=1`) for the old full-screen behaviour.

### Expert / scriptable (the same actions as the menus)

```bash
# Manager Setup / instances (TUI: Manager Setup, Instances)
./nebula-manager import                 # detect running Nebula -> propose nebula-manager.conf
./nebula-manager import --dry-run       # just show what was detected / proposed
./nebula-manager import --yes           # write it non-interactively
./nebula-manager import --bundle ~/Downloads/client-nebula-bundle.zip --yes
./nebula-manager import --bundle bundle.tar.gz --dir /srv/nebula --yes --force
./nebula-manager instance add vps --dir /etc/nebula --service nebula.service --role lighthouse --host vps.theprof.demo:4545
./nebula-manager instance list
./nebula-manager instance disable lab
./nebula-manager instance remove lab
#   ^ 'server' works as an alias: server add|list|disable|remove …
./nebula-manager config init            # create ~/.config/nebula-manager/nebula-manager.conf
./nebula-manager config edit            # open it in $EDITOR
./nebula-manager config refresh         # pull the latest template from your repo
./nebula-manager config remove --force  # delete the active config

# Certificates               (TUI: Certificates)
./nebula-manager ca --name my-ca --duration 999999h --cert-dir ~/keys/nebula
./nebula-manager sign --name host1 --ip 10.42.0.2/24 --groups servers --cert-dir ~/keys/nebula
./nebula-manager sign --cert-dir ~/keys/nebula   # name+IP auto-suggested from existing certs
./nebula-manager sign --cert-dir ~/keys/nebula --in-pub ~/phone.pub --qr ~/keys/nebula/phone.png
#   ^ mobile: sign the device-generated public key; no .key written, QR for the app
./nebula-manager cert list
./nebula-manager cert expiry 30         # certs expiring within 30 days
./nebula-manager cert resign-all         # re-issue everything with the current CA
./nebula-manager cert resign-all --dry-run   # preview only; --keep-keys/--skip-device available
./nebula-manager cert config list        # per-node configs in <cert-dir>/configs
./nebula-manager cert config generate --all   # create/refresh every node config
./nebula-manager cert bundle             # list certificates that can be exported
./nebula-manager cert bundle host1       # exact or unique substring; writes to cwd
./nebula-manager cert bundle host1 --out ~/Downloads
./nebula-manager rename-group laptops theprof --cert-dir ~/keys/nebula
#   ^ re-signs every cert carrying 'laptops', keeps *.crt.bak; --yes to skip the prompt
./nebula-manager group list --cert-dir ~/keys/nebula
./nebula-manager group add home --select group:laptops --cert-dir ~/keys/nebula
./nebula-manager group move laptops home --select group:laptops
./nebula-manager group prune laptops --when group:home
#   ^ select → act: only certs with 'home' lose 'laptops'; others are untouched
./nebula-manager group set "home,admin" --select name:theprof-* --dry-run

# Benchmarks & diagnostics   (TUI: Benchmarks, Diagnostics)
./nebula-manager bench server --port 5201
./nebula-manager bench client 10.42.0.2 --time 15 --streams 4 --reverse
./nebula-manager diag                   # TUN IP, UDP socket, cert expiry

# Firewall                   (TUI: Instance Settings ▸ Edit Firewall)
./nebula-manager firewall explain --nebula-config /etc/nebula/config.yml
#   ^ read-only: defaults, every rule, and how many certs each group rule matches
./nebula-manager firewall groups --cert-dir ~/keys/nebula
#   ^ groups available to rules, with member counts
./nebula-manager policy new home --groups home --description "Home machines"
./nebula-manager policy list
./nebula-manager cert bundle theprof-ge75.theprof.mesh --policy home
./nebula-manager policy export --pack home --select group:home --out ./policies/
./nebula-manager policy apply --pack home --nebula-config /etc/nebula/config.yml

# Fleet                      (TUI: Fleet)
./nebula-manager fleet croc --select group:students --policy students
#   ^ one bundle + one croc code per student; Ctrl-C stops the senders
./nebula-manager fleet croc --select group:students --policy students --dry-run
./nebula-manager fleet probe node4
./nebula-manager fleet ssh node4 --policy home --yes
./nebula-manager fleet ssh node4 --config ./config.yml --dry-run

# Utilities
./nebula-manager paths                  # resolved config / key dirs, info cache + UI backend
./nebula-manager ui                     # which UI backend is active (menu + browse)
./nebula-manager auto-update            # update Nebula to latest
./nebula-manager --version
```

### Global flags

| Flag | Description |
|---|---|
| `--config <path>` | Override `nebula-manager.conf` location |
| `--cert-dir <path>` | Certificate workspace (overrides everything) |
| `--ui auto\|plain\|whiptail\|dialog` | Force a UI backend |
| `--debug <levels>` | Debug mode: `warn\|log\|info\|learn\|all` (comma-separated; see below) |
| `-l`, `--learn` | Shorthand for `--debug=learn` |
| `--clear-screen` | Clear the screen between TUI redraws (default: keep the transcript) |
| `--no-clear-screen` | Keep the transcript (default) |
| `--no-color` | Disable coloured output |

### Environment variables

| Variable | Purpose |
|---|---|
| `NEBULA_KEYS_DIR` | Certificate workspace (2nd precedence, after `--cert-dir`) |
| `NEBULA_BUNDLE_DIR` | Default directory for exported client bundles (default: start dir, then `~/Downloads`, `~/tmp`) |
| `NEBULA_BUNDLE_SHARE_URL` | Base URL used in the bundle's README/one-liners (same as `--share-url`) |
| `NEBULA_BUNDLE_CROC_CODE` | croc code pre-filled in the bundle's README/one-liners (same as `--croc-code`) |
| `NEBULA_LOCAL_CONFIG` | Explicit Nebula `config.yml` used to populate generated client templates (default: active server dir, then `/etc/nebula/config.yml`) |
| `NEBULA_NO_LOCAL_CONFIG` | Set to `1` to skip auto-detecting the host's Nebula config for templates (an explicit `NEBULA_LOCAL_CONFIG` still applies) |
| `NEBULA_MANAGER_LIB` | Override the `lib/` module directory |
| `NEBULA_MANAGER_CONF` | Path to `nebula-manager.conf` (alias for `--config`) |
| `NEBULA_MANAGER_REPO` | `owner/repo` used for update checks / templates (default: git `origin`) |
| `NEBULA_MANAGER_REF` | Git ref (branch) used for update checks (default `main`) |
| `NEBULA_MANAGER_DEFAULT_REPO` | Last-resort repo when neither env nor git `origin` is available (default `jordanhillis/nebula-manager`) |
| `NEBULA_UI` | UI backend. Default (*unset*/`auto`) = **plain numbered menus**; `whiptail`/`dialog` are used automatically for file/dir browsing when available, or set one to force a curses UI everywhere |
| `NEBULA_NO_PROMPT` | Set to `1` to never prompt; unreadable privileged files are skipped instead of read via sudo (used internally for state detection) |
| `NEBULA_DEFAULT_PORT` | Fallback Nebula listen port for diagnostics (default `4242`) |
| `DEBUG` | Debug levels: `warn`, `log` (default), `info`, `learn`, `all` — same as `--debug` |
| `NEBULA_CLEAR_SCREEN` | Set to `1` to clear between TUI redraws (default: off, transcript preserved) |

### Debug modes (`DEBUG` / `--debug`)

`DEBUG=learn` is the teaching mode: **every command is printed (to stderr)
immediately before it runs**, together with a short `note:` explaining what the
step does and why. This lets you watch — and later reproduce — what the menus
actually do. Normal output is unchanged and stdout stays clean for scripts. At
`learn`/`all` level, the **same command line is also appended to the active
certificate store's audit log** (`<cert-dir>/nebula-manager.log`) as
`exec cmd="…"`, so a later review shows exactly what ran. `-l` and `--learn`
are direct shortcuts for `--debug=learn`.

| Level | What you see |
|---|---|
| `warn` | only warnings/errors (hides normal info/success lines) |
| `log` | classic output (the default when `DEBUG` is unset) |
| `info` | classic output + resolved config/cert-dir and binary detection (stderr) |
| `learn` | classic output + a note and each command before execution (stderr), also written to the store log |
| `all` | `info` + `learn` |

Levels can be combined, e.g. `DEBUG=warn,learn` (quiet, but show commands).

```bash
# See the exact commands while signing a certificate
DEBUG=learn ./nebula-manager sign --cert-dir ~/keys/nebula --name host2 --ip 10.42.0.3/24

# Reproduce it by hand:
nebula-cert sign -name host2 -ip 10.42.0.3/24 \
  -ca-crt ~/keys/nebula/ca.crt -ca-key ~/keys/nebula/ca.key \
  -out-crt ~/keys/nebula/host2.crt -out-key ~/keys/nebula/host2.key

# Headless debugging: details and commands on stderr, data on stdout
DEBUG=all ./nebula-manager cert list > certs.txt

# Same via the flag, or the learn shorthand
./nebula-manager --debug=info paths
./nebula-manager --learn cert list
./nebula-manager -l cert list
```

The learn lines look like:

```text
[learn] note: Signing 'host2' for overlay IP(s) '10.42.0.3/24' with groups 'servers' using the CA in /home/you/keys/nebula.
[learn] note: A new private key (.key) is written next to the certificate; deliver it only to that device.
[learn] note: Snapshotting /home/you/keys/nebula before changes (git commit when tracked, otherwise a datestamped backups/ folder).
[learn] /usr/bin/nebula-cert sign -name host2 -ip 10.42.0.3/24 -ca-crt ... -ca-key ... -out-crt ... -out-key ...
[learn] sudo systemctl restart nebula.service
```

The same commands are then in the store log:

```text
2026-10-24T16:30:12+02:00 user=you host=... exec cmd="/usr/bin/nebula-cert sign -name host2 -ip 10.42.0.3/24 ..."
2026-10-24T16:30:12+02:00 user=you host=... sign name="host2" ip="10.42.0.3/24" groups="servers" overwrite=0 in_pub=no
```

Command logging is tied to `learn`/`all`; at the default `log` level only the
higher-level actions are recorded.

---

## Where to next?

- **Getting started** → [getting-started.md](getting-started.md)
- **Certificates** → [certificates.md](certificates.md)
- **Firewall** → [firewall.md](firewall.md)
- **Operations & troubleshooting** → [operations.md](operations.md)
