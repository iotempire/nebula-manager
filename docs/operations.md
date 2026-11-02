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
- **The Manager's own self-update is disabled in this fork.** It would replace
  the modular tree with a single-file release — and could adopt another
  publisher's codebase entirely. Update with git instead; see
  [development.md ▸ How this fork relates to upstream](development.md#-how-this-fork-relates-to-upstream).
  The **Nebula binary** check and update are unaffected.

---

## Nebula Manager updates (disabled in this fork)

The academic edition replaced upstream's monolithic `nebula-manager.sh` with the
`nebula-manager` entrypoint plus `lib/` modules, tests and docs. A self-update
would download a single-file release **over** that tree — and if `origin`
pointed at another publisher, it would adopt *that* codebase instead. The
startup call is therefore commented out (`tui_main` in `nebula-manager`);
`check_script_update` and `perform_manager_update` remain in `lib/system.sh`
for reference, together with their tests.

Update this fork the way it is developed:

```bash
git fetch upstream        # optional: Jordan's new commits
git rebase upstream/main  # replay our commits on top
git push origin main
```

Only the **Manager** is affected: the **Nebula binary** check and the
auto-update scheduler (`--auto-update-nebula`) still work as before.

### Repo resolution (used by `paths`, and by the dormant check)

The check resolves the repo as `NEBULA_MANAGER_REPO` → git `origin` → built-in
default `iotempire/nebula-manager`, in that order. Results are cached per repo
for 6 hours at `/tmp/nebula-manager-version-<owner>_<repo>.cache`.

### Resolving the original project

`NEBULA_MANAGER_REPO` wins over git `origin`, so you can see what a check would
resolve to — or point it at Jordan's project explicitly:

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
./nebula-manager paths      # -> update-repo: iotempire/nebula-manager@main
```

### Re-enabling the check

Uncomment `check_script_update` in `tui_main` (`nebula-manager`). With the
check active, `disable_version_check=true` under `[global]` in
`nebula-manager.conf` suppresses it again.

### What the update code does (reference)

- **Git checkout:** the tool never overwrites your working tree. It prints the
exact command to use instead (`git -C <dir> pull --ff-only`).
- **File install:** it downloads the entrypoint **and** `lib/*.sh` from the
resolved repo, verifies the entrypoint's SHA-256 against the published
`nebula-manager.sha256`, and only uses `sudo` if the install path requires it.
- **Single-file release:** it downloads only the release asset and its
`.sha256`, verifies it, and replaces the running script (no `lib/` tree).
Point a fork at its own asset with `NEBULA_MANAGER_SINGLE_URL`; the default is
`<repo>/releases/latest/download/nebula-manager`.

`NEBULA_MANAGER_DEFAULT_REPO` overrides the last-resort fallback (step 3) and is
mainly useful for testing.

---

## Where to next?

- **Architecture, tests & security** → [development.md](development.md)
- **Roadmap** → [roadmap.md](roadmap.md)
- **User stories** → [user-stories.md](user-stories.md)
