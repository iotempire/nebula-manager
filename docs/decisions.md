# Architecture decisions

[← Back to README](../README.md) · [Documentation map](../README.md#documentation-map)

---

This is the **living decision log** of this fork: why things are the way they
are, what was rejected, and what would have to change to revisit a decision.
It is reconstructed from the commit history (up to `v2.0.0` and the work after
it) and then kept current.

**Rule for changes:** if you change a user-visible behaviour, a storage format,
a module boundary or a safety rule, add or amend an entry here in the same
change. New entries go at the end (ADR-16, ADR-17, …); do not renumber.

Status values: `accepted` (in force), `superseded` (kept for history),
`open` (decided in principle, implementation incomplete).

---

## ADR-1 — Keep the upstream project, rebase this fork on it

**Status:** accepted · **Context:** the academic edition diverged far enough
that a naive merge would have silently dropped features; an early history
rewrite also disconnected the fork from its upstream parent.

**Decision.** `slackhq`-independent: the repository's first commits are the real
upstream history of Jordan Hillis' `nebula-manager`. Our work is applied on top
as ordinary commits (`git log` shows `Move the project to iotempire/...` as the
lineage point). Tags (`v2.0.0`) and a release workflow publish the single-file
artifact.

**Consequences.** Upstream can be re-merged with `git rebase`/`merge` without
rewriting our history. A PR back upstream is possible but not planned (the file
split and the academic layer are intentional, see ADR-2/ADR-3).

**Rejected.** “Start a new repository with a fresh history” (loses attribution
and makes upstream bug fixes unreviewable).

---

## ADR-2 — Single-file release artifact, modular source tree

**Status:** accepted · **Context:** distribution had to be one `curl` in a
classroom; meanwhile ~10k lines in one file is unmaintainable for review.

**Decision.** `lib/*.sh` stays canonical. `make build` (`build_single.sh`)
splices the modules between `# >>> BUNDLE:MODULES >>>` markers in
`nebula-manager`, embeds the runtime assets (`nebula-manager.conf.template`,
`lib/bundle/{install.sh,install.ps1,README.txt}`) as here-docs, and writes
`dist/nebula-manager` + checksum. `VERSION` is the single source of truth for
the version string.

**Consequences.** Adding a module means touching four places: `nebula-manager`
(module list), `build_single.sh` (`MODULES`), `tests/helpers.sh` (sources) and
`nebula-manager.sha256` (regenerate). Forgetting one breaks either the build or
the tests — the suite catches it.

**Rejected.** Shipping the `lib/` tree only (one `curl` impossible); a Python
packaging layer (new dependency, no benefit here).

---

## ADR-3 — Least privilege by construction

**Status:** accepted · **Context:** the tool runs on a teacher's laptop and on
student machines; students are not admins, and `sudo` prompts are the main
source of support tickets.

**Decision.** Everything that can be user-owned *is* user-owned: certificates,
node configs, bundles, policy packs, store history live under `~/keys/nebula`
or `~/.config/nebula-manager`. `elevate()`/`elevate_why()` are used only for a
named privileged action, and always print the reason + exact command when
credentials are not cached. Reads of service-owned configs are explicit
(`readable_nebula_config`), batched into one read, and can be suppressed
(`NEBULA_NO_PROMPT=1`) for state detection and tests.

**Consequences.** No operation is “silently root”. Batch paths must render into
a user-writable temp file and elevate only the final `cp` (see ADR-8).

**Rejected.** “just run the manager as root” (breaks the user-owned store and
makes every path a privilege hazard).

---

## ADR-4 — Nebula V2 certificates, therefore Nebula ≥ 1.10

**Status:** accepted · **Context:** student machines arrive with distribution
packages (Debian 12: 1.6.1, Debian 13: 1.9.3) that cannot parse V2 certs.

**Decision.** Sign V2 (groups + networks in the certificate) and require
Nebula ≥ 1.10; the bundle installer detects an older binary and prints an
upgrade hint instead of failing obscurely.

**Consequences.** Hosts with old packages need an upgrade (`--install-nebula`
in the bundle installer helps). A v1 CA remains a documented, unsupported
fallback.

---

## ADR-5 — Certificate groups are the authorisation model

**Status:** accepted · **Context:** a class mesh must not need per-host
firewall edits when students join.

**Decision.** Permissions are expressed as certificate **groups**
(`lab01`, `students`, `instructor`), never as IP ranges. Batch actions take the
certificate selector grammar (`group:`, `without:`, `name:`, `ip:`, `cert:`,
`all`) so one command covers a cohort.

**Consequences.** Re-signing is the way to change permissions; group names are
part of the contract with policy packs. Selector semantics are tested
(`tests/test_group_batch.sh`, `tests/test_cli.sh`).

---

## ADR-6 — One overlay prefix, per-lab labels

**Status:** accepted (superseded the first `/24`-per-lab design) · **Context:**
the overlay addresses are baked into certificates; a `/24` per lab made labs
*unreachable* islands because Nebula only installs a route for the certificate's
own prefix, and a class of 40 exhausted a `/24`.

**Decision.** One `/16` for the mesh (`10.100.0.0/16`), with per-lab `/24`
*labels* (`10.100.10.x`) that carry meaning but no routing boundary. Existing
meshes are migrated with `cert renumber --prefix 16` (keeps addresses, groups,
expiry, optionally keys). Signing outside the workspace's networks warns and
explains the routing impact.

**Consequences.** Groups do the isolation (ADR-5). `--subnets`/`unsafe_routes`
are only needed for real routed prefixes, not for lab organisation. Admission
“this address is outside the mesh” is a warning, not a refusal (a second class
may legitimately use a second prefix).

---

## ADR-7 — Default-deny, and never emit an invalid action

**Status:** accepted · **Context:** Nebula accepts only `drop`/`reject` for
`inbound_action`/`outbound_action`; `accept` produced a warning on every start
and misled readers. The bootstrap firewall was permissive so the class could
test immediately, which also let every student reach the teacher's home hosts.

**Decision.** Rendered configs default to `drop` with explicit allow rules
(per group, per port). `policy_validate` rejects any other action value.
`firewall explain` reports the effective default (`drop` when the key is
absent). The migration from “permissive” to “selective” is documented as a
story (`docs/user-stories.md`).

**ICMP is part of the generated policy.** A literal default-deny makes a broken
tunnel indistinguishable from a dropped packet: the first debugging step is
`ping`, so every policy this tool generates (`--from-group`, and the `default`
mode) carries an explicit `proto: icmp` / `host: any` inbound rule.
`cert firewall --from-group … --no-icmp` opts out; a hand-written pack is the
fully custom route. This also means the auto-generated `group-*` packs are
re-rendered when the renderer changes (they are marked auto-generated), instead
of pinning the semantics of the release that first created them.

**Consequences.** A new config without rules blocks everything — the bundle
README and the stories say so, and the permissive mode stays available as a
one-command rollback.

---

## ADR-8 — Per-node client config next to the certificate

**Status:** accepted (superseded `configs/<name>.yml`) · **Context:** bundles
re-rendered configs from host detection, so exporting twice could produce
different files, and a hand-tuned config was lost.

**Decision.** `<cert-dir>/<name>.yml` is *the* client config for that node. It
is written at signing time, edited by the user, refreshed by `--force`, and
reused verbatim by `cert bundle`/`fleet bundle|croc`. Legacy `configs/` files are
migrated on first use. Regenerating snapshots the old file first (ADR-9).

**Consequences.** One place to look, one place to change; batch commands
(`cert firewall`, `cert relay`) rewrite it, so their dry-run prints a full diff.
Privileged stores render in a temp file and elevate only the install.

---

## ADR-9 — Every write is snapshot-first

**Status:** accepted · **Context:** teachers edit production configs on a VPS
and student laptops over SSH; a bad write must be recoverable without a backup
discipline.

**Decision.** Before a write: `cert_store_snapshot_before` (git commit when the
store is a repo, otherwise `backups/<timestamp>-…`), plus a timestamped
`*.bak.YYYYmmdd-HHMMSS` for host configs. After a write where the config runs on
this host: `nebula -test`; `relay local` restores the backup automatically when
validation fails. Remote writes (`fleet ssh`) keep the timestamped backup on the
target and validate there.

**Consequences.** Bundle directories and `.croc-*.log` are git-ignored because
they contain private keys; the store history excludes keys by design.

---

## ADR-10 — Bundles are self-contained, installers are idempotent

**Status:** accepted · **Context:** students should not need this repository,
`git`, or a working `sudo` conversation to join the mesh.

**Decision.** A bundle is `cert`, `key`, `ca.crt`, rendered `config.yml`,
`install.sh` (Linux/macOS), `install.ps1` (Windows) and `README.txt` with the
exact one-liners. The installers diff the existing config and refuse to
overwrite without `--yes`/`-Yes`, write `/etc/nebula` with a timestamped backup,
create a systemd unit when the package shipped none (with the detected
`ExecStart`), and apply mesh DNS only when `systemd-resolved` is actually
running.

**Consequences.** The bundle is a distribution artifact, not a config template:
what you export is what the node runs. `--certs-only` refreshes credentials
without touching the config.

---

## ADR-11 — Class distribution is HTTP; croc is a one-off tool

**Status:** accepted (superseded “mass croc”) · **Context:** the first
classroom-sized croc run hit `relay admission rejected` and croc exited `0`, so
one of three transfers silently failed. croc's public relay limits admissions
per *source IP*, and a lab is one NAT address. Running a private relay only to
hand out files is more work than publishing a directory.

**Decision.** `fleet bundle` renders, `fleet serve` publishes read-only over
HTTP (copyparty with one class login when installed, `python3 -m http.server`
otherwise, with an explicit “no password” warning and reverse-tunnel hints).
`fleet croc` remains for a **single receiver at a time** and uses croc's own
three-word code; a relay refusal is reported as a failure, never as delivered.

**Consequences.** Students get a bookmarked URL instead of a code; a bundle is
never shared among several machines (one certificate = one overlay IP). The
class-pack idea (one archive, one folder per node) is an open roadmap item.

**Rejected.** `croc send --store` for the class (public store allows 5 uploads
per hour and 2 unfinished uploads per IP); one shared bundle for everybody
(duplicate overlay IPs).

---

## ADR-12 — The update mechanism is disabled in this fork

**Status:** accepted · **Context:** the built-in updater pulls the packaged
upstream script over the *modular* tree and would overwrite the academic layer.

**Decision.** The self-update path stays in the code, commented out and
documented; updates happen via `git pull` (modular checkout) or by downloading
a new single-file artifact (release install). The Nebula binary update is
unaffected. The startup “update Nebula?” prompt is disabled (it blocked the TUI
on a network round-trip) but the header still reports availability.

**Consequences.** No accidental downgrade of this fork. `docs/operations.md`
explains how to update deliberately.

---

## ADR-13 — The tests are the specification

**Status:** accepted · **Context:** bash + systemd + sudo + three package
managers is exactly the environment where “it works on my machine” hides.

**Decision.** `tests/*.sh` source the real modules, mock the world
(`sudo`, `systemctl`, `ssh`, `nc`, `croc`, `copyparty`, `nebula`, …) in
`$SANDBOX/bin`, never touch the network, and assert on CLI output and on the
files that were written. `exit 77` = skip (missing tool). `run_tests.sh` runs
everything; `make lint` runs `bash -n` + `shellcheck -S error` over all files.

**Consequences.** Every behaviour change needs an assertion. Tests also pin
*safety* properties (no sudo where none is needed, no write on a dry run,
prompts never hang a batch). `NEBULA_NO_PROMPT=1` and
`NEBULA_NO_LOCAL_CONFIG=1` are set by the harness so a prompt can never stall CI
even on a tty.

---

## ADR-14 — Relay support is a first-class setting (academic requirement)

**Status:** accepted · **Context:** in the classroom the underlay is hostile in
a specific way that makes relays structurally necessary:

- **Client separation:** students' laptops sit behind the campus/CGNAT, the
  teacher's machines behind home routers, the lighthouse on a VPS. Several
  machines routinely share one public address.
- **CGNAT and no IPv6:** campus and mobile networks frequently give no public
  IPv4 and no usable IPv6, which leaves no direct path at all.
- **Very small address ranges:** a lab router hands out a handful of addresses
  (often one) and NATs everything behind them, so “just give the lighthouse a
  public IP” is not available for the labs.

Direct connection fails exactly in those cases, so `relay:` has to be part of
the managed config — not a hand-edited stanza on 40 nodes.

**Decision.** The `relay:` block is managed end to end (ADR-15): stored per
certificate, rendered into node configs and bundles, settable at signing time,
pushable over SSH, and editable on this host — with the two documented shapes
emitted verbatim. The lighthouse is the relay (`am_relay: true`); peers get
`am_relay: false, use_relays: true, relays: [<lighthouse>]`.

Because Nebula defaults `use_relays` to **true**, the tool reports an absent key
as `unset (default: on)` instead of pretending it is off.

`relay local --am-relay on` refuses to run on a host whose
`lighthouse.am_lighthouse` is false. Nebula itself accepts it, but a relay must
be as reachable as a lighthouse (public address, inbound UDP) and every peer
must list it; a silent enable would only produce a relay nobody can reach. The
refusal names the setting and the escape hatch.

**Consequences.** The class topology is explicit and reproducible; a new cohort
is one command. The bandwidth cost is on the lighthouse, so the docs state the
topology rule: peers on one segment must connect over their local addresses, and
a relay is a fallback, not a design (see `docs/relay.md`).

**Open follow-ups.** Relay-aware `diag` hints for the “everything is relayed”
case; optionally auto-suggesting the lighthouse when `cert relay` is used
without `--relay`; a class-pack distribution artifact (ADR-11).

---

## ADR-15 — `relay:` is a saved per-node setting, like the firewall choice

**Status:** accepted · **Context:** rendering from the host's own config is
wrong (the teacher's laptop is not the student's laptop), so the setting has to
travel with the certificate.

**Decision.** One TSV (`~/.config/nebula-manager/node-relay.tsv`, mode
`off|use|am|am+use` + relay list) next to the existing firewall preference.
Node config rendering appends the block from it; `cert relay` rewrites the
stored `<name>.yml`; `pki_bundle_client_zip` re-applies it onto
`config.yml.template`, so a bundle can never ship a stale relay stanza.
`PKI_RELAY_OVERRIDE` renders a hypothetical setting for `--dry-run`, which is
why the preview diffs are byte-identical to the real write.

A **manager-wide default** (`relay default 10.100.0.1`, stored as `relay=` in
the `[global]` section of the manager config, override `NEBULA_RELAY`) fills the
gap for certificates that have no setting at all. The order is: per-node setting
(incl. an explicit `off`) → default → no block. The default is applied at
*render* time, never written into existing files, so it cannot silently rewrite
a hand-tuned config; `cert relay --select all --relay … --rebundle` is the
explicit way to apply it to an existing fleet.

**Consequences.** “No setting” still means “no block”, so an untouched
workspace renders exactly the config it rendered before. Relay addresses are
validated against the certificate store (typos and expired relay certificates
are the two failure modes that waste a lab session).

---

## ADR-16 — Documentation is split, and the transcripts are real

**Status:** accepted · **Context:** the single README grew past the point where
a student could find the one command they needed.

**Decision.** `docs/` holds one page per task area, linked from the README's
documentation map; `docs/preview.md` shows plain-menu transcripts produced by
the tool itself (no mockups); `docs/user-stories.md` is the narrative
specification used to judge UX changes.

**Consequences.** A new feature updates: its page, the README table, the
documentation map, `docs/usage.md` (CLI reference), and — if it changes
behaviour — this file.
