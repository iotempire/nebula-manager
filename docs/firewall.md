# Firewall

[← Back to README](../README.md) · [Documentation map](../README.md#documentation-map)

---

Nebula's firewall is **per host** and default-deny. Rules match on peer
certificate attributes (`host`, `group`, `groups`, `cidr`). This chapter covers
the three practical ways to manage it:

- **this host** — edit `/etc/nebula/config.yml` with a group picker and diff;
- **node configs** — apply a policy to one or many `<name>.yml` files;
- **policy packs** — reusable, group-targeted firewall fragments.

> `groups: [a, b]` is **AND** in Nebula (a peer must carry both). To allow any of
> several groups, emit one `group:` rule per group. The batch command does this
> for you.

## Managing firewall rules

### Firewall for groups

Nebula firewalls are **per host**, and rule `groups:` refer to the **peer's
certificate groups**. nebula-manager therefore provides four layers:

**1. Edit this host's rules with a group picker.**
**Instance Settings ▸ Edit Firewall ▸ Inbound/Outbound rules ▸ add/edit** opens a
checkbox list of every group found in the certificate workspace, with member
counts (`home (3 cert(s))`). Current groups are pre-checked; you can uncheck,
combine groups, or pick *Type a group name manually…* for a group that has no
certificates yet. No free-text group syntax to remember.

**2. Add common rules from templates.**
**Instance Settings ▸ Edit Firewall ▸ Add a group-based rule from a template:**

| Template | Result |
|---|---|
| Allow all from a group (inbound) | `port: any`, `proto: any`, `group: NAME` |
| Allow a TCP/UDP port from a group | needs port + protocol |
| Allow SSH (tcp/22) from a group | fixed 22/tcp |
| Allow all outbound to a group | the same, in `outbound` |
| Restrict inbound to one group | the allow rule **plus** `inbound_action: drop` |

> **Multi-group caveat.** Nebula **AND**-s a `groups:` list: a peer must carry
> every listed group. To allow *any* of several groups, add one `group:` rule per
> group. The per-host editor's multi-select currently still writes a single
> `groups:` list (tracked in the [Roadmap](roadmap.md)); the batch node firewall
> emits one rule per group correctly.

**3. See what the policy actually does.**
**Instance Settings ▸ Edit Firewall ▸ Show the effective policy** (or
`firewall explain`) prints a readable summary and flags rule groups that no
certificate carries (usually a typo):

```text
Nebula firewall: /etc/nebula/config.yml
Inbound default:  drop
Outbound default: accept

Inbound rules (1):
  #0  any      any     groups [home] -> 3 cert(s) match

Outbound rules (1):
  #0  any      any     any peer

Groups in workspace:
  admin                1 cert(s)
  home                 3 cert(s)
```

Before saving, the editor shows a **unified diff of the firewall section** and
asks for confirmation; declining leaves the config untouched. Validation
(`nebula -test`) and the timestamped backup still run on commit.

```bash
nebula-manager firewall explain [--nebula-config FILE] [--cert-dir DIR]
nebula-manager firewall groups  [--cert-dir DIR]
```

**4. Change many node configs at once.**
**Certificates ▸ Firewall for Nodes (Batch)…** applies one firewall to the
stored per-node configs of a selection. Lighthouses are **skipped by default**
(they must accept connections from everyone); add `--include-lighthouse` when
you really mean them.

```bash
# Every node except the lighthouse: accept inbound only from group 'home'.
./nebula-manager cert firewall --from-group home --select all --yes

# Preview only:
./nebula-manager cert firewall --from-group home --select all --dry-run

# Students only, permissive, from a policy pack:
./nebula-manager cert firewall --firewall permissive --select group:students --yes
./nebula-manager cert firewall --policy home --select group:home --yes
```

The generated rule is the Nebula equivalent of “only these peers may connect
in”, while outbound stays open:

```yaml
firewall:
  inbound:
    - port: any
      proto: any
      group: "home"
    # Several groups? Emit one rule per group: Nebula AND-s a `groups:` list
    # (a peer would have to carry all of them), so do not use groups: here.
    # - port: any
    #   proto: any
    #   group: "admin"
  outbound:
    - port: any
      proto: any
      host: any
```

`--from-group home,admin` therefore produces two inbound rules (OR semantics).

`--from-group` also creates (or reuses) a policy pack named `group-home` under
`~/.config/nebula-manager/policies/`, and remembers it per certificate, so
bundles and later regenerations keep the same policy. Existing hand edits are
snapshotted (git or `backups/`) before `--force` regeneration. Use
`--select`/`--exclude` (same grammar as group batch) to narrow the target set.

### Policy packs (fleet)

A **policy pack** is a named firewall fragment stored user-side (no root):

```text
${XDG_CONFIG_HOME:-~/.config}/nebula-manager/policies/<name>.yml
```

```yaml
name: home
description: Home machines
groups: [home]          # suggestion metadata, not a firewall rule
firewall:
  inbound_action: drop
  inbound:
    - port: any
      proto: any
      groups: [home]
  outbound:
    - port: any
      proto: any
      host: any
```

**Create one from this host's firewall** (reads it once with the usual
one-time-sudo path if it is service-owned):

```bash
nebula-manager policy new home --groups home --description "Home machines"
nebula-manager policy list
nebula-manager policy show home
nebula-manager policy edit home
nebula-manager policy validate home
```

**Bundles:** when a certificate's groups intersect a pack's `groups`, the bundle
flow **offers** that pack. Headless runs only print a hint — nothing is embedded
unless you ask:

```bash
nebula-manager cert bundle theprof-ge75.theprof.mesh --policy home
nebula-manager cert bundle theprof-ge75.theprof.mesh --policy none   # opt out
```

The generated `config.yml.template` then carries the pack's `firewall:` section
(and a `# Firewall policy pack: home` header) instead of the detected rules.

**Existing fleet:** render the pack for every matching certificate. Each host
gets its own directory with the firewall fragment and copy/paste instructions:

```bash
nebula-manager policy export --pack home --select group:home --out ./policies/
# ./policies/theprof-ge75.theprof.mesh/firewall.yml
# ./policies/theprof-ge75.theprof.mesh/README.txt
```

Actual distribution stays explicit (scp/ansible/whatever you use).

**Apply here** (working copy, diff confirmation, validation):

```bash
nebula-manager policy apply --pack home --nebula-config /etc/nebula/config.yml
nebula-manager policy apply --pack home --yes        # scripted
```

In the TUI, packs live under **Instance Settings ▸ Edit Firewall ▸ Policy packs**,
where a pack can also be applied to the config currently being edited (the
firewall diff/confirm still applies on the way out), shown, edited or deleted.

---

## Where to next?

- **Per-node configs** → [certificates.md](certificates.md#per-node-client-configs-nameyml-next-to-the-certificate)
- **DNS / name resolution** → [dns.md](dns.md)
- **Push a policy to remote nodes** → [fleet.md](fleet.md)
