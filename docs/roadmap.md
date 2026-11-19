# Roadmap & TODO

[← Back to README](../README.md) · [Documentation map](../README.md#documentation-map)

---

Status of implemented features and the work that is still open. Items marked
for manual confirmation need a real Windows/macOS/Android/iOS host.

## Status

- [x] **`import` wizard** – detect a running Nebula (service, binaries, config,
      certs, `tun.dev`, `listen.port`, lighthouse role) and generate
      `nebula-manager.conf`; never silently elevate (show reason + command).
- [x] **`instance add/list/remove/enable/disable`** (`server` alias) – manage
      `[server.*]` entries (idempotent add, informational `role`/`host`).
- [x] **`import --bundle` client setup** – install a bundle + service on a new host
      (the former `client-setup` idea).
- [ ] **`profile create`** – group collections for a class: issue certs with
      `--groups <group>` and a `--subnets`/`local_cidr` scope, render one config
      per member (lighthouse + group isolation), and emit per-member
      self-contained bundles, the shared `ca.crt`, install scripts and a **per-OS
      README** (Linux/macOS + a Windows PowerShell snippet). Target output is a
      ready-to-hand-out `dist/<group>/` directory; `fleet serve` can then hand it
      out.
- [ ] **`verify`** – re-check reachability to the lighthouse (and the certificate
      chain) from a client, so a student can confirm their install without the
      teacher's console.
- [x] **Mobile certificates** – `sign --in-pub KEY.pub` signs a device-generated
      public key (no `.key` written) and `--qr OUT.png` emits the QR scanned by
      **Mobile Nebula** (Android/iOS); also available in the TUI with the
      “Is this certificate for a phone/tablet?” prompt.
- [x] **Batch group editing** – selector + add/remove/move/set/rename/prune.
- [x] **Firewall policy packs** – group-targeted packs embedded in bundles,
      applied locally, or exported per host for an existing fleet.
- [x] **Batch node firewalls** – `cert firewall --from-group …` rewrites the
      stored per-node configs (lighthouse-safe, auto policy pack, remembered).
- [x] **Relays** – `relay:` block support end to end: stored per-node setting
      (`cert relay --relay/--no-relay/--am-relay/--show`, `--rebundle`), emitted
      by node-config rendering and bundles, `sign --relay`, `fleet ssh
      --relay/--no-relay`, `relay local --am-relay/--show` on this host
      (backup + `nebula -test` + restart + auto-restore), relay state in `diag`
      and `firewall explain` with unknown/expired-address warnings →
      [relay.md](relay.md).
- [ ] **Firewall editor multi-group semantics** – the per-host rule editor still
      writes `groups: [a,b]` when several groups are picked. Nebula AND-s that
      list, so “allow from any of these groups” must emit one `group:` rule per
      selection (as the batch path now does).
- [x] **Certificate-store history** – action log, datestamped backups, optional
      git snapshots (private keys always excluded).
- [x] **Remote fleet push** – `fleet ssh` fetches the remote config, merges a
      policy/firewall locally, shows a diff, uploads with a timestamped backup,
      validates and restarts. `fleet bundle` renders the archives, `fleet serve`
      publishes them over HTTP (read-only, copyparty password, python fallback)
      and `fleet croc` shares them one receiver at a time with croc's own code.
- [x] **Single-file release build** – `make build` (`make release` alias)
      generates `dist/nebula-manager` with modules and runtime assets embedded,
      plus a checksum. The modular `lib/` tree stays canonical; the artifact is
      attached to GitHub Releases and supports a one-`curl` install/update.
- [ ] **Real-network confirmation for fleet** – run `fleet serve` in front of a
      real class (copyparty password, then the python fallback) including the
      router/port-forward and reverse-tunnel variants, `fleet croc` through a
      NAT/eduroam link, and `fleet ssh` against a node with key auth +
      passwordless sudo. **Partially done:** the first classroom-sized croc run
      answered `relay admission rejected` (per-source-IP admission limits), which
      is why the class path is HTTP now and croc is limited to one receiver at a
      time (`--local` for a single lab VLAN).
- [ ] **`fleet serve` niceties** – a QR code for the class URL (so students can
      scan instead of typing it), an optional one-time password note in
      `README.txt`, and `--stop`/`--status` for a copyparty started in the
      background (today it runs in the foreground until Ctrl-C).
- [x] **Linux bundle installer provides the systemd unit.** Field report
      2026-11-17 (Debian, release tarball): `install.sh` now writes
      `/etc/systemd/system/<unit>` with the detected `ExecStart` and the installed
      config path when the package shipped no unit, runs `daemon-reload` and
      `enable --now` (`--no-unit` opts out, `NEBULA_UNIT_DIR` overrides the
      directory). It can also install/upgrade Nebula itself (`--install-nebula`).
- [ ] **`import --bundle` / `fleet ssh` need the same unit check** – both still
      assume a `nebula.service` exists on the target.
- [x] **Never emit `firewall.inbound_action`/`outbound_action: accept`.** Nebula
      only accepts `drop` and `reject`; `node_fw_render_policy permissive` and the
      `permissive` mode now render `drop` (the explicit allow-all rules do the
      rest), and `policy_validate` rejects any other action value. Tests updated.
      `firewall explain` also reports `drop` (not `accept`) when
      `outbound_action` is absent, matching Nebula's default-deny behaviour.
- [x] **Document the lighthouse-outside-the-network warnings.** Explained in
      [operations.md ▸ Field notes](operations.md#-field-notes-debian-clients) and
      [dns.md](dns.md#-debian-enabling-systemd-resolved-can-break-dns): expected
      when the lighthouse is in a different overlay subnet; discovery still works.
- [ ] **Wide default prefix for certificate addresses.** Nebula's `-ip` sets both the node's
      address *and* the network it may talk to, so a mesh split into `/24`s silently breaks every
      cross-range flow: the client hangs, `firewall explain` looks correct, and the cause is
      invisible. `sign` should suggest addresses from a wide prefix (`/16`) rather than a `/24`,
      warn when a new certificate's networks do not cover the other certificates in the same
      workspace, and `docs/certificates.md` should state the `-ip` semantics plainly. Tailscale
      allocates from `100.64.0.0/10` and NetBird defaults to a `/16` for the same reason.
- [ ] **Better menu hierarchy** – revisit the top-level grouping once the fleet
      features land (the current rename to *Instances* / *Instance Settings* /
      *Updates & Install* / *Manager Setup* is the surgical first step):
      - **Option A** – merge *Connectivity* + *Diagnostics* + *Benchmarks* into a
        single **Test & Diagnose** menu.
      - **Option B** (target) – top level **This Mesh / This Host / Tests & Tools /
        Manager**, which scales to multi-host fleets and pods.
      - Add a one-line purpose/subtitle to every menu (shown in the header) so
        the difference between *Instance Settings* and *Updates & Install* is
        obvious without opening them.
- [ ] **Pod/container support** – detect Nebula running under `podman`/`docker` and
      route lifecycle actions through the container runtime instead of `systemctl`.
- [ ] **macOS `launchd` in the TUI** – the bundle's `install.sh` already restarts
      brew/launchd services; the manager's own service menu is still systemd-only.
- [x] **Windows native bundle installer** (`install.ps1`) – elevation, key ACLs and
      `nebula.exe -service install/start` are implemented; a real-host run is
      tracked in the manual checklist below.
- [x] **Network renumbering** – `cert renumber --prefix N` re-signs every non-CA
      certificate with the same address under a new mask (e.g. `/24` → `/16`),
      keeping groups, routed subnets and — with `--keep-keys` — the private keys.
      Dry-run, snapshot and action log included.
- [ ] **Pre-1.10 client compatibility** – optionally create a v1 CA/certificates
      (`nebula-cert ca -version 1`) for meshes that still contain hosts with old
      distribution packages (Debian 12: 1.6.1, Debian 13: 1.9.3). Today those
      hosts get upgrade instructions, and v2 certs fail with `bytes did not
      contain a proper nebula certificate banner`.
- [ ] Optional `nebula-cert` JSON health checks / richer diagnostics output.

### Manual platform confirmation (needed)

These cannot be proven by the Linux test suite (the Windows service/ACL flow is
mock-tested under `pwsh`; the mobile flows need real devices). Check them off
after a first-hand run.

- [ ] **Windows 11 — real host**: unpack a client bundle and run
      `install.ps1` (first `-NoStart -Yes`, then without `-NoStart`). Confirm:
      UAC elevation, key ACL (`SYSTEM` + `Administrators`), config diff + backup,
      `nebula.exe -test`, and `nebula.exe -service install` followed by
      start/restart of the `Nebula` service. Also confirm `-CertsOnly` updates a
      certificate without touching `config.yml`.
- [ ] **Android — real device**: install **Mobile Nebula** from Google Play
      (and confirm whether an F-Droid build is available), sign a device key on
      the CA host with `sign --in-pub KEY.pub --qr OUT.png`, scan the QR, paste
      `ca.crt`, add the lighthouse (`10.100.0.1` / `vps.theprof.demo:4545`),
      enable the site, and confirm `ping` and `*.theprof.mesh` name resolution
      from another node.
- [ ] **iPhone/iOS — real device**: same flow through the App Store version:
      QR/certificate import, `ca.crt`, lighthouse, VPN permission, and a `ping`
      from a desktop node. Confirm the app version and iOS minimum in the notes.

---

## Where to next?

- **Motivation & history** → [motivation.md](motivation.md)
- **User stories** → [user-stories.md](user-stories.md)
- **Development** → [development.md](development.md)
