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
settings after `nebula.service` starts. Only the mesh suffix is routed to
Nebula, so public DNS keeps working.

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

---

## Where to next?

- **Firewall rules for DNS** → [firewall.md](firewall.md)
- **Troubleshooting** → [operations.md](operations.md)
