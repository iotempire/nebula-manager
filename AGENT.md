# AGENT.md — working in this repository

Orientation for AI agents (and new maintainers) editing **iotempire/nebula-manager**,
the academic edition of Jordan Hillis' nebula-manager. Humans: skip to
[`docs/decisions.md`](docs/decisions.md) for the *why*; this file is the *how*.

---

## 1. What this is

A least-privilege, user-space CLI/TUI that manages [Slack Nebula](https://nebula.defined.net/)
on one host and deploys client bundles to a fleet of hosts. Bash only, no build
step for development, no runtime dependencies beyond the ones listed in
`docs/getting-started.md`.

- Entry point: `nebula-manager` (argument parsing, menus, dispatch).
- Modules: `lib/*.sh`, sourced in order (`ui pki select bench system import policy relay store fleet`) **when they are loaded matters only for top-level side effects — all cross-module calls are runtime**.
- Canonical source is the modular tree. `dist/nebula-manager` is generated.

## 2. Ground rules

Do not break these without an ADR entry:

1. **No new dependencies.** yq **v4** (mikefarah) is the only YAML tool; detect
   with `require_yq_v4`, never call plain `yq` unguarded.
2. **Every write path snapshots first** (`cert_store_snapshot_before`, and a
   `*.bak.YYYYmmdd-HHMMSS` for host configs) and validates with `nebula -test`
   where the config runs on this host. If validation fails, restore.
3. **Least privilege.** Use `elevate_why "<reason>" cmd…` for privileged
   actions only; render into a user-writable temp file and elevate the single
   `cp`. Never add a silent `sudo`.
4. **Non-interactive safety.** Any prompt must be skipped when
   `NEBULA_NO_PROMPT=1` or stdin is not a tty; batch loops must not hide a
   `read -p` inside `done < <(...)`.
5. **English docs, same change.** Behaviour change ⇒ update the relevant
   `docs/*.md`, `README.md`'s table/map, `docs/usage.md`, and `docs/decisions.md`.
6. **Never commit** `dist/`, `fleet-bundles-*/`, `*-nebula-bundle.*`,
   `.croc-*.log`, `.bundle-*.log` (private keys). Do not commit at all unless
   asked.
7. **Do not test against the real certificate store** (`~/keys/nebula`). Create a
   workspace with `mktemp -d`; `NEBULA_KEYS_DIR`/`CERT_DIR_OVERRIDE` point the
   tools at it.

## 3. Adding or changing behaviour

Work through this list; the suite fails if any step is skipped.

| Step | What |
|---|---|
| 1 | Find the module. Certificate/ bundle logic → `lib/pki.sh`; firewall/policy → `lib/policy.sh`; relay → `lib/relay.sh`; host config/systemd → `lib/system.sh`; fleet → `lib/fleet.sh`; selector grammar → `lib/select.sh`. |
| 2 | Add the headless CLI path **and** the TUI entry (menus are `dynamic_menu` arrays with a one-line subtitle). |
| 3 | Register a **new module** in four places: `nebula-manager` (`for _mod in …`), `build_single.sh` (`MODULES`), `tests/helpers.sh` (sources), and regenerate `nebula-manager.sha256`. |
| 4 | Add assertions to `tests/test_<area>.sh` (see §4). Extend an existing file rather than creating a new one unless the area is new. |
| 5 | `make lint && ./run_tests.sh`, then `sha256sum nebula-manager lib/*.sh > nebula-manager.sha256 && make build`. |
| 6 | Update docs (see ground rule 5) and append to `docs/decisions.md` if the *why* changed. |

## 4. Tests

- Runner: `./run_tests.sh` (or `make test`); it globs `tests/test_*.sh`.
- Single file: `bash tests/test_relay.sh`.
- Harness: `tests/helpers.sh` — `harness_init` creates `$SANDBOX` with a mocked
  `sudo` (logs to `$SUDO_LOG`, never executes), puts `$SANDBOX/bin` first on
  `PATH`, and sets `NEBULA_UI=plain`, `USE_COLOR=false`, `USE_ICONS=false`,
  `NEBULA_NO_LOCAL_CONFIG=1`, `NEBULA_NO_PROMPT=1`.
- Assertions: `assert_eq`, `assert_ne`, `assert_contains`, `assert_not_contains`,
  `assert_file`, `assert_no_file`, `assert_dir`, `assert_empty_file`,
  `assert_nonempty_file`; finish with `harness_summary`.
- Mock the world, not the code under test: create `$SANDBOX/bin/<tool>` scripts
  (`ssh`, `nc`, `systemctl`, `croc`, `copyparty`, `nebula`, …) and log their
  arguments to a file the test asserts on. **No network, no real sudo.**
- `exit 77` = “skipped” (missing `nebula-cert`, `pwsh`, …).
- Sandboxes are deleted on exit; `/tmp` is not shared between commands in agent
  sessions, so multi-step experiments belong in one script.

## 5. Pitfalls that have bitten us

- `set -uo pipefail` without `-e`: check return codes explicitly; `shift 2` with
  one argument errors under `set -u` — guard with `if (( $# ))`.
- `local IFS=','` shadows safely, but `unset IFS` on a local is a no-op surprise;
  prefer `IFS=',' read -ra arr <<< "$csv"`.
- `awk` substitution loops must consume the input line (a self-replacing
  `awk`/`sed` pattern hung the bundle installer once).
- `sed -i` is avoided in the build script; use a temp file + `mv`.
- Anything that shells out with `$( )` inside `printf '%s'` must stay
  quote-safe; the repo lints with `shellcheck -S error`.
- Files under `/etc/nebula` are often owned by `nobody`; always go through
  `readable_nebula_config`/`read_nebula_config` instead of `cat`.
- The fleet/cert output directories contain **private keys**; they are
  git-ignored for that reason. Keep it that way.
- Single-file mode has no `lib/` tree: module functions must be found through
  `declare -F name >/dev/null` guards when the module might not be loaded.

## 6. Map of the tree

```
nebula-manager            entry point: globals, arg parsing, menus, dispatch
lib/ui.sh                 plain/whiptail UI, dynamic_menu, icons, prompts
lib/pki.sh                CA/certs, node configs, bundles, selectors glue, cert CLI
lib/select.sh             certificate selector grammar + checklist TUI
lib/system.sh             elevate(), systemd, /etc/nebula, config edit/validate, diag glue
lib/policy.sh             policy packs, per-node firewall choice, rule rendering
lib/relay.sh              relay: block (per-node setting, batches, this host)
lib/store.sh              store action log, backups, optional git snapshot
lib/fleet.sh              fleet bundle/serve/croc/ssh, SSH probe
lib/bench.sh              iperf3, connectivity, diagnostics view
lib/import.sh             adopt a running Nebula (manager conf / bundle import)
lib/bundle/*              client-side installers + README template (embedded asset)
docs/                     task docs; decisions.md is the ADR log
tests/                    mock-driven Bash suite
build_single.sh           dist/nebula-manager builder
```

## 7. Documentation map (what to update)

| You changed | Update |
|---|---|
| certificate/PKI behaviour | `docs/certificates.md`, `docs/usage.md` |
| bundles/installers | `docs/bundles.md`, `docs/linux-distros.md` (Windows: the `install.ps1` section in `docs/bundles.md`) |
| firewall/policy | `docs/firewall.md` |
| relay | `docs/relay.md`, `docs/decisions.md` (ADR-14/15) |
| fleet/SSH/HTTP | `docs/fleet.md`, `docs/user-stories.md` (Phase 2e) |
| menus/UX | `docs/preview.md`, `docs/user-stories.md` |
| safety rules, module layout, dependencies | `docs/decisions.md` + this file |

## 8. Before you say “done”

```bash
make lint && ./run_tests.sh
sha256sum nebula-manager lib/*.sh > nebula-manager.sha256 && make build
git --no-optional-locks status --short   # expected files only, no bundles/keys
```

Report: what changed, which tests you ran, what you could not validate (and why).
