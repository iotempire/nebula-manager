# Name resolution (Nebula DNS)

[← Back to README](../README.md) · [Documentation map](../README.md#documentation-map)

---

Nebula can serve DNS from a lighthouse and route a suffix such as
`theprof.mesh` to the overlay. This is separate from the host firewall and from
public DNS.

## How it works

Nebula does not change your OS resolver automatically. Name resolution has two
halves:

**On the lighthouse** (`am_lighthouse: true`): **Instance Settings ▸ Name resolution
(Nebula DNS)** sets `lighthouse.serve_dns: true`, `lighthouse.dns.host` (the
overlay IP), `dns.port: 53`, and adds an inbound firewall rule for UDP/53. It
offers to restart the service.

**On a client:** the same menu shows the detected values and offers explicit
actions:

```text
Resolver DNS: <not configured>
DNS suffix:   <not configured>
Boot hook:    not installed

Client DNS actions
  1. Apply now (until reboot)
  2. Apply now + install boot hook (recommended)
  3. Back
```

Applying runs:

```bash
sudo resolvectl dns nebula1 10.100.0.1
sudo resolvectl domain nebula1 '~theprof.mesh'
```

Option 2 also installs `nebula-manager-resolved.service`, which reapplies the
settings after `nebula.service` starts **and after every restart**: the unit has
`PartOf=nebula.service`, so systemd restarts it together with Nebula. Only the
mesh suffix is routed to Nebula, so public DNS keeps working.

**Why this matters.** `resolvectl dns`/`domain` attach to the interface, not to
the resolver. Every Nebula start creates a new `nebula1` device, so any restart
(`systemctl restart nebula.service`, a firewall push, `relay local`, an update)
would silently drop mesh name resolution — `ping vps.ulno.mesh` then fails with
`Name or service not known` while the overlay itself keeps working (`ping
10.100.0.1` succeeds). Hosts whose hook was installed before v2.1.1 have no
`PartOf=`; `nebula-manager fleet ssh`/`fleet update` restart the hook explicitly
after a service restart, and `nebula-manager dns persist` rewrites the unit.

### Bundles set it up on install

A client bundle carries `nebula-dns.conf` (mesh suffix + lighthouse overlay
IPs). `install.sh` applies the two `resolvectl` commands and installs the boot
hook, so a fresh client resolves mesh names without running nebula-manager.
Use `--no-dns` to skip it; `--no-start` also skips it, because DNS needs the
interface to be up.

```bash
nebula-manager dns status       # role, interface, lighthouse IPs, resolver/hook
nebula-manager dns setup        # interactive action menu
nebula-manager dns apply        # client: apply now (until reboot)
nebula-manager dns persist      # client: apply + install the boot hook
nebula-manager dns lighthouse   # lighthouse: serve_dns + firewall UDP/53
```

Use the certificate name (`vps.theprof.mesh`) for overlay lookups; `vps.theprof.demo`
is the public endpoint and stays with public DNS.

Limitations: the lighthouse only answers for hosts it has seen since it started;
automatic client setup requires `systemd-resolved` (`resolvectl`). Without it,
configure the lighthouse overlay IP as DNS for the Nebula interface manually.

### ⚠️ Debian: enabling `systemd-resolved` can break DNS

`apt install systemd-resolved` repoints `/etc/resolv.conf` at the stub
(`127.0.0.53`). If nothing configures an upstream server for it, every lookup
fails — including Nebula's `static_host_map` hostname resolution, which shows up
as `DNS resolution failed for static_map host … server misbehaving` and a tunnel
that never handshakes.

Before relying on it, check `resolvectl status` (a DNS server must be listed) or
set `DNS=` in `/etc/systemd/resolved.conf` and restart the unit. On servers that
do not manage DNS dynamically, adding the handful of mesh names to `/etc/hosts`
is the safer option. The bundle installer therefore only touches the resolver
when `systemd-resolved` is installed **and running**.

---

## Where to next?

- **Firewall rules for DNS** → [firewall.md](firewall.md)
- **Troubleshooting** → [operations.md](operations.md)
