# Motivation & history

[← Back to README](../README.md) · [Documentation map](../README.md#documentation-map)

---

**Nebula Manager — academic edition** is ulno's fork of
[Jordan Hillis' Nebula Manager](https://github.com/jordanhillis/nebula-manager)
v2.0.0. It keeps the original goal — one friendly tool to install, configure and
operate [Slack Nebula](https://github.com/slackhq/nebula) — and extends it for
teaching, least-privilege operation and reproducible classroom workflows.

The credit line used throughout the project is:

```text
ulno's academic spin - orig: Jordan Hillis v2.0.0
```

## Why a fork?

Nebula is an excellent teaching network: small enough to explain, real enough to
break in interesting ways, and it gives students a tangible overlay they can
reach from home. The original manager was already a strong operations tool, but
running a class exposed a different set of requirements:

1. **Students (and teachers) should not run the manager as root.**
   Certificate work, diagnostics, bundles and benchmarks belong to the user.
   Only writing system paths, controlling systemd and touching kernel/firewall
   state need elevation — and only for that specific action.
2. **The PKI must be allowed to live in a normal user directory.**
   A classroom CA, a demo CA and a production CA should coexist without sudo,
   with an explicit, inspectable store and clear precedence
   (`--cert-dir` > `NEBULA_KEYS_DIR` > selected workspace > manager config).
3. **A node's configuration should be a first-class artefact.**
   Certificates, keys and the deployable `config.yml` should sit together, so
   "what do I hand to this machine?" has one obvious answer.
4. **Group and fleet operations must be safe and repeatable.**
   Renaming groups, re-issuing certificates after a CA rotation, changing a
   firewall for a whole class, and handing out bundles should be previewed,
   snapshotted and scriptable.
5. **The UI should be teachable.**
   Plain numbered menus by default, a full transcript, searchable menus, and
   headless equivalents for every action. Curses dialogs (whiptail) are used
   where they genuinely help, such as file/directory pickers.
6. **The documentation should be usable in a course.**
   Story-driven examples (`theprof` and the students), distro guides, and a test
   suite that doubles as executable acceptance criteria.

## What changed in the academic edition

| Area | Extension |
|---|---|
| Privilege | Removed the global root check; `elevate()` + `path_requires_root()` call `sudo` only for system paths, systemd and host firewall state. Service-owned config reads ask once with the reason and exact command. |
| Structure | A thin `nebula-manager` entrypoint plus modules in `lib/` (`ui`, `pki`, `bench`, `system`, `import`, `policy`, `select`, `store`, `fleet`). |
| Workspaces | User-owned certificate stores, switchable at runtime, with manager-config and legacy detection. |
| Certificates | Human durations, safer CA recreation, re-signing after a CA rotation, batch group editing, `*.crt.bak` and store snapshots. |
| Node configs | Per-node `<name>.yml` next to the key/cert, generated at signing time and reused by bundles. |
| Firewall | Policy packs, group pickers, batch node firewalls with lighthouse-aware defaults, and explicit AND/OR semantics. |
| Bundles | Self-contained Linux/macOS and Windows installers, config diffs, cert-only updates, HTTP/croc sharing one-liners. |
| Fleet | `fleet croc` for classroom mass deployment and `fleet ssh` with diff/backup/validate/restart. |
| Adoption | `import` discovers an existing Nebula installation and proposes `nebula-manager.conf`. |
| Teaching | [User stories](user-stories.md), [distribution guides](linux-distros.md), preview transcripts, debug/`learn` modes. |
| Quality | A dependency-free mock-driven Bash test suite, checksummed modules, and explicit manual-confirmation items for Windows/macOS/Android/iOS. |

## Design principles

- **Least privilege, always.** No ambient root; every elevation is narrow,
  explained and logged. The whole tool should never need to be run with `sudo`.
- **Preview before mutation.** Dry runs, diffs, per-file snapshots, and a
  datestamped backup or git commit before certificates or configs are replaced.
- **User-owned state by default.** Workspaces, policy packs, logs, saved
  selections and generated configs live in the user's home, not in `/etc`.
- **Plain text first.** Numbered menus are the default because they are easy to
  teach, copy, debug and script. A curses picker is used only when it helps.
- **One implementation, two faces.** The TUI and the headless CLI call the same
  functions; documentation shows both.
- **Stories as acceptance criteria.** The user stories are not marketing — they
  describe real workflows and are kept in sync with the tool.
- **Upstream-friendly.** The fork keeps the original structure and credits, and
  its update check resolves the fork first, then the upstream repository.

## Scope and non-goals

- It orchestrates `nebula`, `nebula-cert`, `systemctl`, `yq` and the local
  filesystem. It is **not** a replacement for Nebula.
- It is a per-host manager with fleet helpers, **not** a central control plane,
  database or monitoring system.
- It does not implement a custom PKI, HSM integration, or a hosted service.
- It does not silently change remote machines: `fleet ssh`/`fleet croc` are
  explicit commands with previews.

## History in one paragraph

The project started from Jordan Hillis' v2.0.0 manager. The academic edition
first removed the unconditional root requirement and split the monolith into
modules with tests. It then added user-owned certificate workspaces, the import
wizard, per-node configs, CA-rotation re-signing, batch group and firewall
operations, self-contained bundles/installers, croc/SSH fleet deployment, and a
documentation set built around teaching. Each step kept the original
least-surprise goal: explain what will happen, do only that, and leave enough
state behind to undo it.

## Upstream, versions and credits

- Academic fork: <https://github.com/ulno/nebula-manager>
- Original project: <https://github.com/jordanhillis/nebula-manager>
- Nebula: <https://github.com/slackhq/nebula>

The original v2.0.0 tool was created by **Jordan Hillis**. The academic
improvements — least-privilege (non-root) operation, the modular `lib/` layout,
the `import` wizard, server management, the plain-first TUI, mobile certificate
support, per-node configs, batch group/firewall operations and the
distribution guides — were developed **by ulno** for teaching Nebula in a
networking class.

Update checks and fork/upstream resolution are documented in
[Operations ▸ Update checks](operations.md#update-checks--forks). The license is
MIT; see [LICENSE](../LICENSE).

## How to help

- Run the suite on your distribution and report gaps
  ([Development](development.md#testing)).
- Add a user story or refine an existing one in
  [user-stories.md](user-stories.md).
- Test the manual platform items in [Roadmap](roadmap.md#manual-platform-confirmation-needed)
  (Windows, macOS, Android, iOS).
- Keep examples reproducible: prefer real commands and small, inspectable state.

---

## Where to next?

- [Getting started](getting-started.md)
- [Certificates & workspaces](certificates.md)
- [Roadmap & TODO](roadmap.md)
- [Back to README](../README.md)
