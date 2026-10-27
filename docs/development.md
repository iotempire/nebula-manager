# Architecture, security & development

[← Back to README](../README.md) · [Documentation map](../README.md#documentation-map)

---

How the tool is put together, why it is least-privilege, and how to run and
extend the test suite.

## 🏗️ Architecture

The tool is a thin entrypoint plus modules under `lib/`:

```
nebula-manager          # entrypoint: arg parsing, dispatch, TUI root + Manager Setup menu
lib/
  ui.sh                 # colours, status badges, whiptail/dialog + plain menus
  pki.sh                # CA, signing, inspection, workspaces, client bundling, node configs
  bench.sh              # iperf3 server/client, connectivity, diagnostics
  system.sh             # elevate()/sudo, systemd, /etc/nebula, config & server management
  import.sh             # discover an existing Nebula -> generate nebula-manager.conf
  select.sh             # certificate selector grammar for batch actions
  policy.sh             # policy packs + per-node firewall choices
  store.sh              # store action log, backups, optional git snapshots
  fleet.sh              # croc mass sharing, SSH push, reachability probing
nebula-manager.conf.template  # bundled config template (offline first-run)
tests/                  # standalone mock-driven Bash test harness
run_tests.sh            # test runner (also: make test)
```

`nebula-manager.sh` is kept as a thin **backwards-compatibility shim** that
re-execs the real entrypoint.

### Privilege model

- `elevate() { [[ $EUID -eq 0 ]] && "$@" || sudo "$@"; }` — the single choke point for privilege escalation.
- `path_requires_root()` classifies a target path; `ensure_dir()` elevates **only** when the nearest existing parent isn't writable by you.
- Everything else (printing/signing certs, zipping bundles, pings, `iperf3`, `ss`) runs as you.
- **Editing a service-owned `config.yml`** (Instance Settings ▸ Edit Config / Edit Firewall) reads it through the same one-time-sudo path, edits a **user-owned working copy** with `yq`, and saves once at the end through `elevate()` with a timestamped `.bak.*` backup. `yq` never touches a file you cannot read/write.
- Reading a **service-owned** Nebula config (`/etc/nebula/config.yml`, often
  owned by `nobody`) goes through `readable_nebula_config()` for **explicit actions**
  (`diag`, Validate Config, `import`, client bundling):
  - it uses cached `sudo` if available, otherwise asks once — showing the
    **reason and exact command** — before elevating;
  - the prompt is tied to stderr (not stdout), so capturing command output
    never suppresses it; it also works when stdin is redirected by a batch loop
    (the prompt falls back to `/dev/tty`);
  - derived values (TUN dev, listen host/port, lighthouse role and whether
    `lighthouse.hosts`/`static_host_map` are present) are cached in
    `$XDG_CACHE_HOME/nebula-manager/system-info`, so the **startup header needs
    no elevation on later runs**;
  - with no cache yet, the header detects the `nebula*` interface itself and
    **warns that the config (and therefore the lighthouse/static_host_map)
    could not be verified**, pointing to **Diagnostics** or
    **Instance Settings ▸ Validate Config** to authorize the first read;
  - cached values are keyed by the **real** config path even when a temporary
    readable copy was used; if `nebula -test` then fails because the referenced
    `pki.key`/`pki.crt` are service-owned, **Validate Config offers a one-time
    elevated re-test** instead of reporting a misleading “invalid config”.

Privileged actions (the only ones that use `sudo`):
`mkdir/chmod/write under system paths`, `mkdir -p /etc/nebula` + template download, systemd (`daemon-reload`, `enable`, `start/stop/restart/reload`), installing binaries into `bin_path`, and the self-update copy.

---

## Testing

A lightweight, dependency-free test harness (no BATS required) lives in `tests/`.
It uses a **mocked `sudo`** that records every invocation, so least-privilege
behaviour is asserted directly.

```bash
./run_tests.sh        # or: make test
```

What it covers:

| Test | Verifies |
|---|---|
| `tests/test_pki_unprivileged.sh` | CA + cert signing + bundling work with **no root**, in a `mktemp -d` workspace |
| `tests/test_pki_suggest.sh` | client-cert name/IP suggestions: mesh-domain suffix + next free overlay address |
| `tests/test_mobile_cert.sh` | mobile certs: `--in-pub` signs a device key (no `.key` written), `--qr` emits a QR, plus the TUI “mobile device” flow |
| `tests/test_sudo_mock.sh` | `sudo` is invoked **only** for privileged target dirs; failure is surfaced |
| `tests/test_resolve_dir.sh` | `--cert-dir` > `NEBULA_KEYS_DIR` > saved selection > manager `[global] cert_dir` > legacy dir > default |
| `tests/test_port.sh` | listen-port resolution: `listen.port` → auto-detect → `default_port` |
| `tests/test_distro.sh` | distro detection + Arch/CachyOS package mapping; unknown distro no longer hard-fails |
| `tests/test_workspace.sh` | certificate workspace selection + "already known" detection |
| `tests/test_workspace_menu.sh` | workspace selector: detected stores listed, number *or* typed path accepted, invalid input re-prompts, env-override warning |
| `tests/test_conf.sh` | config path resolution: user-first, `--config`/env override, bundled template + `config init` offline |
| `tests/test_setup.sh` | Manager Setup state summary (detected config/instances/workspace), `config_use_file` validation, `config remove` without sudo for user paths |
| `tests/test_tui_menu.sh` | entrypoint Manager Setup/bootstrap menu wiring (import/browse/delete/reload/exit), the state-line refresh hook, the instance-context block and the main-menu labels |
| `tests/test_sysinfo.sh` | header is cache-first (no sudo/prompt), falls back to the `nebula*` interface guess, points at Diagnostics; unreadable configs never spew `Permission denied` |
| `tests/test_template_online.sh` | optional (needs `NEBULA_TEST_ONLINE=1`) freshness check of the bundled template vs the repo |
| `tests/test_update.sh` | update source resolution (origin/env) + no-downgrade version comparison |
| `tests/test_realstore_readonly.sh` | uses a real cert store **read-only** (hashes unchanged, no `sudo`) |
| `tests/test_cli.sh` | CLI parsing, flag precedence, usage/exit codes, end-to-end unprivileged PKI |
| `tests/test_debug.sh` | `DEBUG` levels: `learn` prints notes + commands to stderr only, mirrors them into the store audit log, `warn` hides info, stdout stays clean |
| `tests/test_bundle.sh` | client export: candidate listing, substring/ambiguous matching, default output dir, TUI picker, mode 0600 |
| `tests/test_bundle_installer.sh` | self-contained bundles: install.sh/install.ps1/README shipped, user-owned install without sudo, config diff + refusal/`--yes`, backups, share one-liners |
| `tests/test_installer_ps1.sh` | PowerShell installer under `pwsh` (Linux CI): parse, portable install, config diff/refusal/`-Yes`, `-CertsOnly`, plus simulated-Windows ACL and service install/start/restart with mocks |
| `tests/test_fleet_croc.sh` | fleet croc: selection → bundles, one `CROC_SECRET=<code> croc send …` per node (never the rejected `--code` form), code table, dry-run, mobile-cert skip, policy embedding, unique codes |
| `tests/test_fleet_ssh.sh` | fleet SSH: name expansion, port probing, user discovery, passwordless-sudo/root handling, remote fetch → local merge → diff → upload/backup/test, dry-run, unreachable guidance |
| `tests/test_client_config.sh` | generated client template: real static_host_map/lighthouse/punchy/listen/tun/firewall from the local config, `[server.*]` fallback, and missing-value warnings |
| `tests/test_edit.sh` | privileged-safe config editing: working copy for read-only/unreadable configs, elevated write-back, timestamped backup, and no-op when nothing changed |
| `tests/test_import_bundle.sh` | client bundle import: tar.gz extraction, validation, path rebasing, manager.conf creation, overwrite/backup, dry-run, TUI wrapper, CLI, post-import `--start` |
| `tests/test_dns.sh` | Nebula DNS: lighthouse `serve_dns` + UDP/53 firewall, client `resolvectl` DNS/domain setup, status output, static_host_map fallback |
| `tests/test_duration.sh` | human certificate durations (`720`, `720h`, `365d`, `52w`, `10y`) normalized to Go hours; invalid/zero/fractional input rejected; CA defaults offered from the current CA or the newest backup |
| `tests/test_resign_all.sh` | one-shot CA rotation: dry-run/no-op, non-TTY refusal, old-CA certs re-issued by the new CA, `--keep-keys`, default key rotation, device-key preservation, `--skip-device`, snapshot + action log, no sudo, CLI `cert resign-all` |
| `tests/test_node_config.sh` | per-node `<name>.yml` next to the cert: signing writes it, detected network settings/firewall embedded, hand edits survive, `--force` refreshes, bundle reuses it, explicit policy overrides, legacy `configs/` auto-migration, mobile skipped, CLI list/show/path/generate, no sudo |
| `tests/test_rename_group.sh` | group migration: preview/scan, dedup + order, re-sign preserves name/IP/expiry, unaffected certs/keys byte-identical, `*.crt.bak`, no sudo, CLI `--yes`/non-tty refusal |
| `tests/test_group_batch.sh` | selector grammar (`group`/`without`/`name` glob/`ip` CIDR/`cert`/union/exclude) + batch add/remove/move/set/prune, idempotency, `--dry-run`, non-tty refusal, `group list`, plain checklist parsing |
| `tests/test_firewall_batch.sh` | batch node firewall: `--from-group` rule, lighthouse skipped by default/`--include-lighthouse`, auto policy pack + remembered choice, real YAML assertions, bundle reuse, permissive/`--policy`, `--dry-run`, non-tty refusal, no sudo |
| `tests/test_firewall_groups.sh` | firewall group discovery/counts, picker (defaults/manual/unknown groups), rule templates, editor picker wiring, explain (defaults/matches/typo warning), diff + save prompt, CLI |
| `tests/test_policy_packs.sh` | policy packs: create/list/show/validate, group-based suggestions, embedding in generated configs/bundles (CLI + TUI), per-host export, apply (working copy + `--yes`), delete, no sudo |
| `tests/test_store_history.sh` | store action log; datestamped backups before overwrite/group/CA/remove; git snapshots with keys/backups excluded; CLI `cert store status/log/backup/git-init`; no sudo |
| `tests/pki.bats` | BATS mirror of the core unprivileged-PKI guarantees |

Requirements: `bash`, `nebula-cert` (for PKI tests; auto-skipped otherwise).
BATS tests run when `bats` is installed. `test_realstore_readonly.sh` uses a real
store from `$NEBULA_TEST_STORE` (unset by default, so it skips) and only ever
reads from it — no paths or names are hardcoded.

The PowerShell installer is exercised under `pwsh` (including a simulated-Windows
ACL/service run with mocks). **Real** Windows, Android and iPhone confirmation is
tracked in [Roadmap ▸ Manual platform confirmation](roadmap.md#manual-platform-confirmation-needed).

`make lint` syntax-checks the entrypoint and all modules (and runs `shellcheck`
when available).

## 🔒 Security Notes
- The tool runs **unprivileged**; review any `sudo` prompt before approving it.
- Keep backups of your `config.yml` and certificates before making changes.
- Only run Nebula Manager on trusted systems — it manages cryptographic keys.
- Keep certificate workspaces user-owned (mode `700`) to avoid ever needing root.

---

## Where to next?

- **Roadmap / TODO** → [roadmap.md](roadmap.md)
- **Preview transcripts** → [preview.md](preview.md)
- **User stories (acceptance criteria)** → [user-stories.md](user-stories.md)
