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
      ready-to-hand-out `dist/<group>/` directory; `fleet croc` can then serve it.
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
- [ ] **Firewall editor multi-group semantics** – the per-host rule editor still
      writes `groups: [a,b]` when several groups are picked. Nebula AND-s that
      list, so “allow from any of these groups” must emit one `group:` rule per
      selection (as the batch path now does).
- [x] **Certificate-store history** – action log, datestamped backups, optional
      git snapshots (private keys always excluded).
- [x] **Remote fleet push** – `fleet ssh` fetches the remote config, merges a
      policy/firewall locally, shows a diff, uploads with a timestamped backup,
      validates and restarts. `fleet croc` serves self-contained bundles with one
      code per node (the recommended classroom mass-deployment path).
- [ ] **Real-network confirmation for fleet** – run `fleet croc` between two
      machines over croc's relay (including behind eduroam/NAT) and run
      `fleet ssh` against a node with key auth + passwordless sudo.
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
