# Policy cookbook: configs, policies and firewall rules

[← Back to README](../README.md) · [Documentation map](../README.md#documentation-map)

---

This page is for the *decisions*: which firewall/policy to give which machine,
how to name roles, and how a change reaches a node that is already out there.
The mechanical reference is [firewall.md](firewall.md); the commands are also in
[usage.md](usage.md).

## The three artifacts (and why the names changed)

```
certificate workspace (~/keys/nebula)
├── alice.pod01.mesh.crt / .key     identity
├── alice.pod01.mesh.yml            ← THE config for that node (firewall + relay included)
└── ca.crt / ca.key

bundle (what a student receives)
├── alice.pod01.mesh.crt / .key
├── ca.crt
├── config.yml                      ← a copy of the node config above, ready to install
├── install.sh / install.ps1 / README.txt
```

- `<name>.yml` is the **source of truth** for a node. Batches (`cert firewall`,
  `cert relay`) rewrite it, `cert bundle` copies it.
- The bundle file is called **`config.yml`** (it used to be
  `config.yml.template`). It is not a template with placeholders: the installers
  only rewrite the `/etc/nebula` paths when `--dir` is used. Older bundles that
  still contain `config.yml.template` keep working — both installers accept the
  old name.
- A **policy pack** is a named firewall fragment (`firewall:` only). Embedding it
  copies those rules into `<name>.yml`; the pack itself is not needed on the node.

So: *pack → node config → bundle*. Nothing on the node refers back to the pack.

## Groups are roles, not people

A Nebula **group** is a capability stamped into certificates. Rules say “allow
peers with group X”, never “allow 10.100.0.5”. Two consequences:

1. A machine can carry several groups (`instructor,admin`), and the union is what
   it may do.
2. The group name is *public in the certificate* and hard to change later
   (re-signing), so name the **role**, not yourself or your laptop.

Recommended vocabulary:

| Group | Meaning | Typical members |
|---|---|---|
| `admin` | may administer everything (SSH, DNS, metrics, …) | the operator's workstations, the VPS |
| `instructor` | teaching staff access without full admin | staff laptops |
| `pod01` … `podNN` | one student pod: isolated by default | the students' machines of that pod |
| `lighthouse` | the node(s) that do discovery/relay/DNS | the VPS |
| `service-dns`, `service-git`, … | optional: a machine that exposes one service | lab servers |

### “My personal group is called `ulno`”

That happens when the first mesh is built around one person: `ulno` starts as
“my machines”, then doubles as “the admin group”, and later you want a second
admin. Fixing it is a one-liner per direction:

```bash
# Rename the group everywhere (re-signs each certificate; *.crt.bak kept):
nebula-manager cert rename-group ulno admin

# …or keep `ulno` and add a role group to the same nodes (no rename):
nebula-manager group add admin --select group:ulno
```

Prefer **roles from the start**: `admin` (capability) instead of a name
(identity). Personal identity belongs in the certificate *name*
(`ulno-framework.admin.mesh`), which is purely cosmetic for routing.

## Built-in firewall choices

Ask the tool instead of remembering:

```bash
nebula-manager policy explain --mode default
nebula-manager policy explain --mode permissive
nebula-manager policy explain --group pod01,instructor
nebula-manager policy explain home          # a policy pack
nebula-manager policy list                  # one rule line per pack
```

| Choice | What it does |
|---|---|
| `--firewall default` | outbound allow, inbound drop **except ICMP** (any peer may ping) |
| `--firewall permissive` | allow everything in and out (bootstrap only) |
| `--from-group G1[,G2]` | inbound only from those groups **+ ICMP from anyone**; outbound open |
| `--policy PACK` | whatever the pack's `firewall:` says |
| `--firewall host` | copy this host's detected firewall |
| `--firewall skip` | no saved choice; the detected host profile is used at bundle time |

`policy explain` prints the rules in one line (“inbound: group pod01,
icmp from any · outbound: any”) plus the unmatched-traffic action. The same
summary now appears in the batch preview, in the pack menu and in `cert bundle`,
so a pack can be reviewed before it is deployed.

## Recipes

### 1. The lighthouse (VPS)

```bash
nebula-manager relay local --am-relay on                       # forwards for peers
nebula-manager cert firewall --from-group admin --select cert:vps.mesh \
    --include-lighthouse --yes
```

Result: inbound from `admin` only, plus ICMP. Discovery/relay traffic is Nebula
protocol traffic and is **not** filtered by the Nebula firewall, so peers still
find each other. Keep the public UDP port open in the host firewall
(`4545/udp` in the examples).

### 2. A class with isolated pods (recommended)

Every pod sees itself and the teaching staff, nothing else:

```bash
for pod in pod01 pod02 pod03; do
    nebula-manager cert firewall --from-group "$pod,instructor" \
        --select group:"$pod" --yes
done
```

What a `pod01` machine now has:

```yaml
firewall:
  inbound:
    - port: any
      proto: any
      group: "pod01"        # its own pod (OR …)
    - port: any
      proto: any
      group: "instructor"   # … or teaching staff
    - proto: icmp
      host: any             # everyone may ping (diagnostics)
  outbound:
    - port: any
      proto: any
      host: any
```

- Students reach each other inside the pod only. Cross-pod traffic is dropped,
  which is usually what a lab wants (no accidental port scans of the neighbour).
- The staff can join any pod; the lighthouse stays reachable.
- Two groups in one `--from-group` are **OR** (one rule each). Never write
  `groups: [pod01, instructor]` yourself: Nebula AND-s that list.

### 3. One big class group (simplest)

If pods do not need isolation:

```bash
nebula-manager cert firewall --from-group class,instructor --select group:class --yes
```

### 4. Exposing one service from a pod

Use a pack so the extra rule is reviewable and reusable:

```bash
nebula-manager policy new pod01-web --groups pod01,instructor
# edit ~/.config/nebula-manager/policies/pod01-web.yml:
#   inbound:
#     - group pod01        (or port 18080 to the whole pod)
#     - group instructor
#     - proto icmp
nebula-manager policy explain pod01-web          # check it
nebula-manager cert firewall --policy pod01-web --select group:pod01 --yes
```

### 5. A machine that may only be pinged

```bash
nebula-manager cert firewall --firewall default --select cert:printer.mesh --yes
```

### 6. Devices (Android/iOS)

Mobile certificates have no local key and no config: they *dial out*, so they
need no inbound rules. Give them a group (`students`) and let the pods accept
that group if the phone should reach them.

## How a change reaches a node

| Situation | Command | What else is needed |
|---|---|---|
| Node not installed yet | `cert bundle` / `fleet bundle` → hand out | student runs `install.sh` |
| Whole class, one URL | `fleet bundle` + `fleet serve` | nothing |
| One node you can SSH into | `fleet ssh NODE --policy PACK` (or `--relay`) | key login; sudo password is asked once at a terminal, `--no-interactive` for keys-only |
| Several nodes, one after the other | `fleet update --select … --policy PACK` | same; each host prompts only if needed |
| Many existing nodes, new firewall | `cert firewall … --select … --yes` | re-hand-out or push the new config |
| Many existing nodes, new relay | `cert relay … --select … --rebundle` | re-hand-out or push |
| This host only | `policy apply`, `relay local` | service restart (done for you) |
| Files for someone else to install | `policy export --pack … --select …` | they run `yq`/copy + restart |

Rule of thumb: **batch commands change the workspace; nodes only change when
they receive a new config.** `--rebundle` closes that gap for the artifacts,
`fleet ssh` closes it for a node that is already connected.

## Changing a policy later (runbook)

1. Look before you touch: `policy explain <pack>`, `cert list` (relay column),
   `cert firewall --… --dry-run`.
2. Apply to the workspace: `cert firewall … --yes` (store snapshots first).
3. Refresh what you hand out: `cert bundle …` or `fleet bundle … --policy …`.
4. Push to nodes that already exist: `fleet ssh NODE --policy <pack> --yes`.
5. Verify: `firewall explain --nebula-config …`, `nebula -test`, and a `ping`
   from a pod peer (ICMP is on, so a failed ping is a real routing/firewall
   finding, not a policy artifact).

## Menu structure — the current state and a proposal

Today the *Certificate Management* menu mixes three different things: identity
(certs, groups, workspace), policy (firewall for nodes, packs) and distribution
(bundles). *Instance Settings* then repeats part of it for this host. That is why
some screens show too much and others too little.

Near-term improvements already in place:

- every policy choice prints what it allows (`policy explain`, `policy list`,
  menu labels, batch preview, bundle log);
- *Certificates ▸ Policy Packs (what each one allows)…* is the home of packs;
- the batch preview prints the effective rules before writing.

Proposal (tracked in the roadmap):

| Menu | Contains |
|---|---|
| **Certificates** | identity only: list/sign/revoke/expiry, groups, workspace, store history |
| **Policies** | packs (list/explain/edit/new), batch firewall for nodes, relay for nodes |
| **Distribute** | bundle, serve (HTTP), croc, SSH push, probe — all "how does it get there" |
| **This host** | config edit/validate, local firewall, local relay, DNS, service control |

The goal is one question per menu: *who is this node* → *what may it do* → *how
does it get there* → *what does this machine run*.

## Where to next?

- **Rules, flags, packs in detail** → [firewall.md](firewall.md)
- **Relays** → [relay.md](relay.md)
- **Handing bundles out** → [fleet.md](fleet.md), [bundles.md](bundles.md)
- **The class story end to end** → [user-stories.md](user-stories.md)
