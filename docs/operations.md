# Operations & troubleshooting

[← Back to README](../README.md) · [Documentation map](../README.md#documentation-map)

---

FAQ, runtime notes, and how the tool checks for updates (including fork vs.
upstream resolution).

## ❓ FAQ

Looking for more answers? Check the [Full FAQ on GitHub Wiki »](https://github.com/jordanhillis/nebula-manager/wiki/FAQ)

---

## 🩺 Runtime notes

- **Your config lives with you by default.** `nebula-manager.conf` is resolved as
  `--config` / `$NEBULA_MANAGER_CONF` → an existing
  `/etc/nebula/nebula-manager.conf` → `$XDG_CONFIG_HOME/nebula-manager/nebula-manager.conf`.
  The per-user default means a first run never needs root just to fetch a config
  template. Force a location with `--config <path>`.
- **Privilege requests explain themselves.** Before any `sudo` password prompt the
  tool prints the reason and the exact command it is about to run, e.g.:
  ```
  [!] Administrator privileges required: restart the Nebula service
      command: sudo systemctl restart nebula
  ```
  It only ever asks for the specific privileged action, never for the whole session.
- **Nebula often runs as a service user.** Files under `/etc/nebula` may be owned by
  `nobody` (or the unit's `User=`), so the tool reads them read-only and only
  elevates for the read when necessary. If the config isn't readable, diagnostics
  falls back to sane defaults and says so.
- **`listen.port: 0` means an OS-assigned port.** Diagnostics resolves the port in
  this order: explicit `listen.port` → auto-detection (via `ss`, using passwordless
  `sudo` when available, or an opt-in elevated lookup on a TTY) → `default_port`.
  Set `default_port` to your usual port (e.g. `4545`) to avoid ambiguity.
- **Systemd (not containers), for now.** The tool assumes Nebula runs as a host
  systemd unit. Pod/container support is tracked in the [Roadmap](roadmap.md).
- **Update checks follow your source repo, not upstream.** The version check and
  self-update resolve the repo as `NEBULA_MANAGER_REPO` → git `origin` → built-in
  upstream (`jordanhillis/nebula-manager`), so a fork checks itself. An update is
  only offered when the published version is **strictly newer** (semantic
  comparison), never as a downgrade. Git checkouts are never auto-overwritten —
  the tool tells you to `git pull` instead.

---

## Update checks & forks

Nebula Manager checks for newer versions of **itself** at startup (and via
`--auto-update-nebula`). Where it checks depends on where your copy came from,
in this order:

1. `NEBULA_MANAGER_REPO` (`owner/repo`), if set
2. the git remote **`origin`** of the checkout it is running from
3. the built-in upstream: **`jordanhillis/nebula-manager`**

So a fork checks *itself* by default. An update is only offered when the
published version is **strictly newer** than the running one (version-aware
comparison, e.g. `1.10 > 1.9`) — a fork that is ahead of upstream is never
offered a downgrade. The result is cached per repo for 6 hours at
`/tmp/nebula-manager-version-<owner>_<repo>.cache`.

### Checking upstream explicitly

To compare against the canonical project instead of your fork, point the check
at the upstream repo:

```bash
# one-off
NEBULA_MANAGER_REPO=jordanhillis/nebula-manager ./nebula-manager

# for the current shell / a CI job
export NEBULA_MANAGER_REPO=jordanhillis/nebula-manager
```

Pick a specific branch or tag with `NEBULA_MANAGER_REF`:

```bash
NEBULA_MANAGER_REPO=jordanhillis/nebula-manager NEBULA_MANAGER_REF=main ./nebula-manager
```

Confirm what is being checked with `paths`:

```bash
./nebula-manager paths      # -> update-repo: theprof/nebula-manager@main
```

### Disabling the check

Set `disable_version_check=true` under `[global]` in `nebula-manager.conf`.
(The same setting also silences the "update available" prompt.)

### What accepting an update does

- **Git checkout:** the tool never overwrites your working tree. It prints the
exact command to use instead (`git -C <dir> pull --ff-only`).
- **File install:** it downloads the entrypoint **and** `lib/*.sh` from the
resolved repo, verifies the entrypoint's SHA-256 against the published
`nebula-manager.sha256`, and only uses `sudo` if the install path requires it.

`NEBULA_MANAGER_DEFAULT_REPO` overrides the last-resort fallback (step 3) and is
mainly useful for testing.

---

## Where to next?

- **Architecture, tests & security** → [development.md](development.md)
- **Roadmap** → [roadmap.md](roadmap.md)
- **User stories** → [user-stories.md](user-stories.md)
