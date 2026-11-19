# Relays

[← Back to README](../README.md) · [Documentation map](../README.md#documentation-map)

---

A **relay** is a third node that forwards packets between two peers that cannot
build a direct path. Nebula tries direct connections first (NAT traversal,
`punchy`, IPv6); a relay is the fallback when that fails.

Two things are always true and worth stating up front:

- **The relay never sees plaintext.** The payload is end-to-end encrypted between
  the two peers; the relay forwards opaque ciphertext.
- **The relay carries the traffic volume.** Every packet between those two peers
  goes through it, adding a hop (latency) and consuming its bandwidth and CPU.
  A relay belongs on the node with the best uplink — in this tool's topology,
  the lighthouse.

## When you need one

| Situation | Relay? |
|---|---|
| Two peers behind **the same NAT** (home router, lab router) | yes — hairpin NAT usually fails |
| **CGNAT** / carrier-grade NAT (mobile, some campus networks) | yes |
| **IPv4 only**, no working UDP hole punching | yes |
| Both peers have a public address or working STUN/punch | no |
| **Two machines on the same LAN/VLAN** | **no** — let them talk over their local addresses |

> **Topology rule.** A relay is a fallback for the *underlay*, not a way to
> organise the overlay. Peers that sit on one segment should connect directly
> (same LAN, same lab, same datacentre); only reach across a relay for the pairs
> that genuinely cannot see each other. A mesh where everything is relayed works,
> but it is slow and funnels all traffic through one host.

## The two shapes

Client/peer — "peers that want to reach **me** may use this relay":

```yaml
relay:
  am_relay: false
  use_relays: true
  relays:
    - 10.100.0.1
```

Relay host (normally the lighthouse) — "I forward traffic for peers that list me":

```yaml
relay:
  am_relay: true
```

Defaults worth knowing (Nebula ≥ 1.6): `am_relay` is **false**, `use_relays` is
**true**. So `relays:` is the only thing a peer usually needs, and the list is
advertised to the lighthouse and handed to the peers that ask for it.

A relay must be **reachable like a lighthouse**: a public address and inbound UDP
(`listen.port`, usually 4242 or the forwarded port). `nebula -test` accepts
`am_relay: true` on any host, but a relay nobody can reach is dead weight — which
is why this tool refuses to enable it on a host whose
`lighthouse.am_lighthouse` is not `true`.

## Doing it with nebula-manager

### One host: the lighthouse

```bash
# is this host a relay, and does it use relays?
nebula-manager relay local --show

# become a relay for the class (refused unless am_lighthouse: true)
nebula-manager relay local --am-relay on

# or point this host at a relay as well
nebula-manager relay local --relay 10.100.0.1
```

Each change writes a timestamped backup (`config.yml.bak.YYYYmmdd-HHMMSS`),
validates with `nebula -test`, and restarts `--service` (default
`nebula.service`). If validation fails the backup is restored automatically.
`--nebula-config FILE` targets a non-default config, `--no-restart` validates
only, `--dry-run` prints the diff.

**TUI:** *Instance Settings ▸ Local relay (am_relay)*.

### The class: every peer

```bash
# all students use the lighthouse as their relay
nebula-manager cert relay --select group:students --relay 10.100.0.1

# the routers keep connecting directly: no block at all
nebula-manager cert relay --select name:router* --no-relay

# what is set right now?
nebula-manager cert relay --select all --show
```

The setting is stored per certificate and remembered, so

- `<name>.yml` (the stored node config) is rewritten,
- `nebula-manager cert bundle <name>` and `nebula-manager fleet bundle|croc`
  carry the block automatically,
- a later re-sign keeps it.

`--dry-run` prints the exact diffs, `--yes` runs unattended, and `--rebundle`
refreshes the bundle exports in the same invocation:

```bash
nebula-manager cert relay --select group:students --relay 10.100.0.1 --rebundle
```

Two-step equivalent (also fine):

```bash
nebula-manager cert relay --select group:students --relay 10.100.0.1 --yes
nebula-manager fleet bundle --select group:students --policy students
```

### One default for everything

Instead of setting the relay per certificate, set it **once** for the whole
workspace. Every node config and every bundle without a per-node setting is then
born with the block:

```bash
nebula-manager relay default 10.100.0.1      # store it in the manager config
nebula-manager relay default --show          # what is set, and where it comes from
nebula-manager relay default --clear         # back to "no block unless asked"
```

```
$ nebula-manager relay default 10.100.0.1
[✔] Default relay for client configs: 10.100.0.1 (/home/you/.config/nebula-manager/nebula-manager.conf)
```

- Stored as `relay=10.100.0.1` in the `[global]` section of the manager config
  (`nebula-manager config path`), so it survives new shells and applies to every
  later `sign`, `cert config generate`, `cert bundle`, `fleet bundle` and
  `fleet croc`.
- `NEBULA_RELAY=10.100.0.1` overrides it for a single run.
- A **per-node setting always wins**: `cert relay --relay …` / `--no-relay` (and
  `sign --relay`) keep their own value; `off` suppresses the default for that
  node.
- Existing `<name>.yml` files are **not** rewritten by setting the default — the
  default is applied when a config is rendered. To apply it to the current
  fleet in one go:

  ```bash
  nebula-manager cert relay --select all --relay 10.100.0.1 --rebundle
  ```

  (`--rebundle` also refreshes the exported archives, so the next handout is
  immediately correct.)
- `cert list` shows `auto:<ip>` for certificates that inherit the default.

**TUI:** *Manager Setup ▸ Default relay for client configs*.

### New certificates

```bash
nebula-manager sign --name alice.theprof.mesh --ip 10.100.10.11/16 \
    --groups lab01 --relay 10.100.0.1
```

`--relay` is repeatable (several addresses render as a list) and the address must
belong to a certificate in the workspace — a typo is refused with the closest
matches, because "the relay is not in the mesh" is the most common relay bug.

### Nodes you already run

```bash
nebula-manager fleet ssh node4 --relay 10.100.0.1 --yes
nebula-manager fleet ssh node4 --no-relay --yes
```

`fleet ssh` fetches the remote config, merges only the `relay:` block, shows a
diff, uploads with a timestamped backup, validates and restarts — exactly like
`--policy`/`--firewall-file`.

### Inspection

```bash
nebula-manager relay local --show     # this host, incl. use_relays
nebula-manager diag                   # Relay: am_relay: off, use_relays: on, relays: …
nebula-manager firewall explain       # same line, plus rule/groups context
```

Both flag a relay address that is **not** a certificate in the workspace or whose
certificate has **expired** (an expired relay certificate silently stops working
for new handshakes).

## Verifying by hand

```bash
# the config is accepted and the relay is read
sudo nebula -test -config /etc/nebula/config.yml
# look for: msg="Read relay from config" relay=10.100.0.1
journalctl -u nebula.service -n 20 | grep -i relay
```

On the relay host, `am_relay: true` plus a reachable UDP port is all that is
needed; the relay logs nothing per packet.

## Troubleshooting

| Symptom | Cause |
|---|---|
| `relay 10.9.9.9 is not a certificate` | typo, or the relay certificate lives in a different workspace |
| peers connect but nothing flows | relay not reachable on UDP, or `am_relay` not enabled there |
| `relay admission`/handshake errors after a while | relay certificate expired — re-sign it, then `cert relay` again |
| everything is relayed and slow | the topology rule above: split peers by segment, and check `local_cidr`/`unsafe_routes` before adding a relay |
| `am_relay` refused | the host is not a lighthouse (`lighthouse.am_lighthouse: false`); enable the relay on the lighthouse |

## Where to next?

- **Firewall and groups** → [firewall.md](firewall.md)
- **Handing bundles to the class** → [fleet.md](fleet.md)
- **Certificates and workspaces** → [certificates.md](certificates.md)
