# Certificates & workspaces

[← Back to README](../README.md) · [Documentation map](../README.md#documentation-map)

---

Everything about the PKI: user-owned workspaces, signing, groups, re-signing
after a CA rotation, per-node client configs, and store history.

> The tool never needs root for certificate work. A workspace is just a
> directory you own; `sudo` is only used when you deliberately target a
> service-owned location.

All PKI lives in a **certificate workspace** (a directory containing
`ca.crt`, `ca.key`, `<name>.crt`, `<name>.key`). Workspaces are ordinary
directories — keep them user-owned and no privilege is ever needed.

## Signing, groups & per-node configs

### Generating a client certificate

**Certificates ▸ Generate Client Certificate** (or `nebula-manager sign …`) walks
you through a name, IP, groups and optional subnets/duration. The name and IP
prompts come with **suggestions derived from the existing certs**:

- **name** — `<this-host-short-name><mesh-domain>`, where the domain is the most
  common suffix among existing cert names (e.g. `theprof-framework.theprof.mesh` when
  your certs are `vps.theprof.mesh`, `theprof-ge75.theprof.mesh`, …);
- **IP** — the **next free /24 host** in the overlay network used by most of your
  certs (e.g. `10.100.0.1`, `.2`, `.3` present → `10.100.0.4/24`);
- **groups** — the workspace's existing groups are listed with member counts
  (e.g. `existing: instructor (3), lighthouse (1)`), and **Enter reuses the last
  groups you used in this workspace** (node and mobile selections are tracked
  separately). With no groups yet it suggests **roles**
  (`instructor,student`; mobile: `student,mobile`) instead of device types.
  Type `-` to clear the groups. Invalid input re-prompts, and the last
  successful choice is remembered under
  `~/.config/nebula-manager/sign-groups/`.
- **duration** — accepts hours (`8760h`), days (`365d`), weeks (`52w`) or
  years (`1y`/`10y`); a bare number means hours. Press Enter to inherit the
  CA's expiration. When recreating a CA in place, its existing name and
  duration are offered as defaults, so Enter keeps the old lifetime. If the CA
  is only present in a `backups/` snapshot (for example after an interrupted
  attempt), the newest backup is used for those defaults.

Press Enter to accept a suggestion or type your own. The name is a free-form
label (Nebula does not require the domain), but keeping the `.mesh` suffix
matches the convention the rest of your certs follow.

If you type a **bare name** (no dot) while your existing certs use a mesh domain,
the TUI offers to append it: with **one** domain it asks for confirmation; with
**several** it shows a menu (most-used first, with counts) plus *keep as-is*.
`nebula-manager sign --name bare` only prints the same hint — it never renames
silently.

```
[?] Enter the certificate name [theprof-framework.theprof.mesh]:
[?] Enter the IP address [10.100.0.4/24]:
```

#### Choosing the firewall for a new node

After a node certificate is signed, the TUI asks which firewall its generated
client config should carry:

- suggested **policy packs** whose `groups` intersect the node's groups (shown
  with their target groups) — the meaningful set derived from your existing
  rules and certificates;
- **copy this host's firewall** (the detected rules);
- **permissive** (allow all inbound/outbound);
- **Nebula defaults** (outbound allow, inbound drop);
- **decide later** (at bundle time).

The choice is remembered **per certificate**, and the last choice is offered as
the default for the next node. Enter accepts the first entry. State lives in
`${XDG_CONFIG_HOME:-~/.config}/nebula-manager/node-firewall.tsv` — a plain
user-owned file, no `sudo` and no daemon.

#### Mobile devices (Android / iOS)

The same TUI entry asks **“Is this certificate for a phone/tablet (Mobile Nebula)?”**.
For a mobile device you give it the **public key exported by the app** (the app
generates the keypair; the private key never leaves the phone), and it emits a
**QR code** you scan in the app:

```bash
# device exports device.pub from the app; then:
./nebula-manager sign --cert-dir ~/keys/nebula \
    --in-pub ~/device.pub \
    --name phone.mesh.example --ip 10.100.0.6/24 --groups mobile \
    --qr ~/keys/nebula/phone.png
```

- `--in-pub KEY.pub` — sign the device's public key; **no `.key` is written**.
- `--qr OUT.png` — write a QR code of the signed certificate to scan/copy into the
  app. (The QR contains the certificate only; the device already has the key.)
- Name/IP are still auto-suggested if omitted.

The app also needs the **CA certificate** (paste `ca.crt`, or scan a QR made with
`qrencode`), plus the lighthouse's overlay IP and public `host:port`. See
See [the user stories](user-stories.md) (Story 1, Phase 2b / Story 2, Dana) for the full flow.

### Editing groups (batch)

Groups are baked into the certificate, so any group change means **re-signing the
affected certificates**. Instead of one hard-wired rename, nebula-manager uses a
**select → act** model (1–10 nodes is a comfortable checklist):

**Certificates ▸ Edit Groups (Batch)…**

1. type a **filter** — the prompt is built from **this workspace's actual
groups and overlay networks, with counts** (e.g. `Groups: home (3), admin (1)`,
`Networks: 10.100.0.0/24 (4)`), and the examples are generic (`group:NAME`,
`name:GLOB`, `ip:CIDR`). Unions and exclusions are supported; an invalid filter
offers to retry;
2. confirm the matches in a **checkbox list** (all pre-selected; space toggles);
3. pick an **action**: add, remove, move, set or rename. The workspace's
   groups are listed with member counts both in the action menu and in every
   group prompt — pick one by number or type a new name, so you never have to
   recall exact group names. (The former "Show the current groups" entry is
   gone because the list is now always visible.)
4. review the exact per-certificate diff and confirm;
5. optionally apply **another action to the same selection** (e.g. add `home`,
   then also add `admin`).

```text
Add group "home" to 2 certificate(s).
Originals are backed up as *.crt.bak; private keys are not touched.

theprof-framework.theprof.mesh.crt (10.100.0.2/24): [laptops,admin] -> [laptops,admin,home]
theprof-ge75.theprof.mesh.crt      (10.100.0.3/24): [laptops] -> [laptops,home]
```

| Action | Semantics |
|---|---|
| **add** | union — never replaces an existing group; already-present is a no-op |
| **remove** | subtract; absent is a no-op |
| **move A B** | add B and remove A **in one re-sign** (in-place, deduplicated) |
| **set** | replace the whole group list (`set ""` clears it) |
| **rename A B** | replace A with B only where A exists |

The conditional case is just a selection: *“remove `laptops` if `home` is
present, otherwise keep it”* = **select `group:home`, action remove `laptops`** —
certificates without `home` are never selected, so they stay untouched.

Headless equivalents (all support `--dry-run`, `--yes` and `--cert-dir DIR`):

```bash
./nebula-manager group list --cert-dir ~/keys/nebula

./nebula-manager group add home      --select group:laptops
./nebula-manager group remove laptops --select group:home
./nebula-manager group move laptops home --select group:laptops
./nebula-manager group set "home,admin" --select name:theprof-*
./nebula-manager group prune laptops --when group:home   # conditional remove
./nebula-manager group rename laptops home               # alias: rename-group

./nebula-manager group add test --select group:laptops --dry-run   # preview only
```

Selector grammar (repeat `--select` to union; `--exclude` subtracts):

| Spec | Matches |
|---|---|
| `all` | every non-CA certificate |
| `group:G` / `has:G` | certificates carrying group G |
| `without:G` / `missing:G` | certificates **not** carrying G |
| `name:GLOB` | certificate-name glob (`name:theprof-*`) |
| `ip:CIDR` / `ip:ADDR` | overlay address inside the CIDR / exactly ADDR |
| `cert:NAME` / `NAME` | exact certificate name (case-insensitive) |

What is preserved: **name, IP networks, subnets and expiry**. Duplicate groups
are removed and the original order is kept. Each original certificate is saved
next to itself as `<name>.crt.bak` (a pre-existing backup is never overwritten),
and the private key on the device is **not** touched: the helper reads the
public key out of the existing certificate and passes it back to
`nebula-cert sign -in-pub`, so the re-issued certificate matches the key the
device already has.

Without `--yes` the CLI prints the preview and asks first; on a non-interactive
shell it refuses instead of re-signing silently. Batch actions require an
explicit `--select` (only `rename` defaults to `group:<old>`), so a missing
filter can never silently rewrite everything.

To give a **single** certificate more groups you can also re-sign it directly
(`nebula-manager sign --name … --ip … --groups a,b,c`), or use the batch editor
with `--select cert:<name>`.

### Re-signing everything after a CA rotation

When the CA was recreated (or you simply want a fresh validity window), every
certificate in the workspace still carries the **old** CA's signature. The
one-shot re-sign replaces them in a single previewed action:

**Certificates ▸ Re-sign All Certificates** — or headless:

```bash
# 1. See exactly what would happen (safe; nothing is written):
./nebula-manager cert resign-all --cert-dir ~/keys/nebula --dry-run

# 2. Re-issue every certificate with the current CA:
./nebula-manager cert resign-all --cert-dir ~/keys/nebula --yes
```

What happens:

- Only **non-CA** certificates are touched; `ca.crt`/`ca.key` are never rewritten.
- **Name, overlay networks, routed subnets, groups and the existing expiry** are
  carried over, so the fleet keeps the same addressing and policy.
- Local certificates (`<name>.key` exists) get **new private keys** by default,
  because rotation is the safer choice after a CA change. Keep the old keys with
  `--keep-keys`.
- **Device certificates** (mobile/`--in-pub`, no local `.key`) cannot get a new
  key here. Their public key is extracted from the certificate and the cert is
  re-signed for it, so the phone keeps working. Use `--skip-device` to leave
  those certificates untouched instead.
- Before anything is replaced, the store is snapshotted (git commit when tracked,
  otherwise `<cert-dir>/backups/<timestamp>-resign-all/` with `ACTION.txt`) and
  the run is recorded in `<cert-dir>/nebula-manager.log`.

| Flag | Effect |
|---|---|
| `--dry-run` / `-n` | print the plan (name, IPs, groups, new/keep key); write nothing |
| `--yes` / `-y` | no confirmation prompt (required when stdin is not a TTY) |
| `--keep-keys` | reuse existing `<name>.key` files instead of rotating them |
| `--skip-device` | skip certificates that have no local private key |

After re-signing, redeploy the updated certificates (and, when keys rotated, the
new `.key`) to the nodes — e.g. with a client bundle, the self-contained
installer, or the Fleet menu. Nodes whose key changed must receive the new key
or they will fall out of the mesh.

### Per-node client configs (`<name>.yml` next to the certificate)

Every local certificate now keeps its ready-to-deploy client config **in the
workspace**, next to the PKI:

```text
~/keys/nebula/
├── ca.crt
├── node1.mesh.crt
├── node1.mesh.key
└── node1.mesh.yml     # pki paths, static_host_map, lighthouse, punchy, firewall, tun
```

Older releases kept these in a `configs/` subdirectory. Those files are moved
next to the certificate automatically the next time they are used or generated.

- The file is written **when the certificate is signed** (the firewall you pick
  for the node is embedded) and kept in sync by re-signing/resign-all when it is
  missing. Existing files are **never overwritten silently**, so hand edits
  survive group changes and key rotation; a forced regeneration first snapshots
  the old file into the store history.
- **Certificates ▸ Node Client Configs** lets you list, show, edit, regenerate
  one node, or regenerate every config. Editing needs no root: it is a normal
  user-owned file.
- **Certificates ▸ Bundle / Export Client** ships the stored config as
  `config.yml.template`. An explicit `--policy`/`--firewall` choice still wins
  and refreshes the stored copy.
- Mobile/`--in-pub` certificates have no client config (the app manages it).
- The config contains no private key; only the bundle adds the `.key`.
- A **lighthouse's** listen port is taken from its `static_host_map` endpoint
  (e.g. `vps.example:4545` → `listen.port: 4545`), so a non-default port is not
  silently replaced by 4242.

Headless equivalents (all support `--cert-dir DIR`):

```bash
./nebula-manager cert config list
./nebula-manager cert config path node1     # unique substring is fine
./nebula-manager cert config show node1
./nebula-manager cert config edit node1     # opens $EDITOR, generates if missing
./nebula-manager cert config generate node1
./nebula-manager cert config generate --all --force   # refresh every node
```

When a deployment needs a different firewall than the stored one, edit the
stored config (or regenerate with a policy pack) rather than patching the
bundle: the bundle is intentionally predictable.

## Workspace & store history

### Resolution precedence

1. `--cert-dir <path>` (CLI flag — highest priority)
2. `NEBULA_KEYS_DIR` environment variable
3. The saved interactive selection (chosen from **Certificates ▸ Switch Certificate Workspace**)
4. `[global] cert_dir` from `nebula-manager.conf`
5. The active server's legacy directory: `$NEBULA_DIR/$cert_folder`
6. Default fallback: `$HOME/.local/share/nebula-manager/keys`

Use **Certificates ▸ Switch Certificate Workspace** to point the tool at a
different store; the choice is persisted in
`$XDG_CONFIG_HOME/nebula-manager/certdir`. A stale saved selection (a directory
that no longer exists or has no `.crt` files) is ignored when the manager config
points at a populated store, and the saved selection is re-synced automatically.

### Store history, backups & git

Every certificate-store write is recorded in **`<cert-dir>/nebula-manager.log`**
(timestamp, user, host, action; mode `600`). Before a certificate is
**overwritten, re-signed or removed**, the old state is preserved using one of
two strategies:

- **git mode** — if the store is inside a git work tree, pending certificate
  changes are committed first (`nebula-manager: pre-change snapshot (…)`).
  Private keys are **never** committed: `*.key`, `backups/`, `*.crt.bak`,
  archives and QR images are excluded via a nested `.gitignore` and an explicit
  staging pathspec.
- **folder mode** — otherwise a datestamped folder is written:
  ```text
  <cert-dir>/backups/20261024-160032-000-sign-host1-overwrite/
      host1.crt  host1.key  ACTION.txt        # files are mode 600
  ```
  `ACTION.txt` records time, user, host, reason and the file list.

If a git commit cannot be made (no usable repo/identity), the tool **falls back
to a folder backup**, so an overwrite is never left unprotected. Re-signing
also signs into a temporary directory and only then installs the new files
(`nebula-cert` itself refuses to overwrite).

```bash
nebula-manager cert store status
nebula-manager cert store log -n 40
nebula-manager cert store backup --reason "before classroom demo"
nebula-manager cert store git-init      # safe: keys/backups are ignored
```

In the TUI: **Certificates ▸ Store Backup / Git** shows the VCS state, log size
and backup count, and offers *snapshot now*, *initialize git*, *show the log*.
When a folder backup is created and no git repo exists, a one-time hint points
at `cert store git-init`. With `DEBUG=learn`/`all`, every command shown on the
terminal is also appended to this log as `exec cmd="…"`, including the notes
that explain each step.

### First run: choosing a certificate workspace

If no workspace is determined yet (no `--cert-dir`, no `NEBULA_KEYS_DIR`, no saved
selection, and no populated server cert dir), the TUI offers to pick one:

```
[!] No certificate workspace selected yet.
      1. Use existing store: /home/you/keys/nebula
      2. Use default store: /home/you/.local/share/nebula-manager/keys
      3. Use server dir: /etc/nebula/certs
      4. Browse for a certificate directory...
      5. Skip for now (use default)
```

Existing stores (`~/keys/nebula`, the default, and the active server's `certs/`)
are auto-detected and offered. **Browse** opens a directory browser
(`whiptail --dselect`) or lets you type a path. Your pick is remembered.

The **Certificates ▸ Workspace** menu later offers the same list (current store,
any detected stores, default, server dir, custom) and, in plain mode, **also
accepts a directory typed directly** at the prompt — so you can either enter a
menu number or type the path you mean. If `--cert-dir`/`NEBULA_KEYS_DIR` is set
it still wins over the saved selection, and the tool warns you when that happens.

---

## Where to next?

- **Export/import bundles** → [bundles.md](bundles.md)
- **Firewall for these nodes** → [firewall.md](firewall.md)
- **Batch groups / re-sign examples** → [user stories](user-stories.md)
