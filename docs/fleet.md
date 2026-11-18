# Fleet deployment

[← Back to README](../README.md) · [Documentation map](../README.md#documentation-map)

---

Two paths, in priority order: **croc** for a classroom (no open ports, works
behind NAT/eduroam) and **SSH** for one node you can already log into with a key.

## Two deployment paths

Two paths, in priority order. **croc** is the recommended classroom path (no open
ports, works behind eduroam/NAT); **ssh** is for a single node you can already
log into with a key.

**TUI:** **Main Menu ▸ Fleet**

### Mass deployment with croc (classes)

```bash
nebula-manager fleet croc --select group:students --policy students
```

This renders one **self-contained bundle** per selected certificate (cert/key/CA,
config template, `install.sh`, `install.ps1`, `README.txt`), starts **one `croc
send` process per bundle** with a code chosen by nebula-manager, and prints:

```text
Bundles for your fleet (/home/you/fleet-bundles-20261025-101500):
Node                           croc code                      Bundle
alice.theprof.mesh             alice-theprof-mesh-3f9a1c2b    alice.theprof.mesh-nebula-bundle.zip
bob.theprof.mesh               bob-theprof-mesh-7c2e44d1      bob.theprof.mesh-nebula-bundle.zip

Students run:
  croc alice-theprof-mesh-3f9a1c2b    # alice.theprof.mesh
  croc bob-theprof-mesh-7c2e44d1      # bob.theprof.mesh
```

The command keeps waiting (one transfer per code) and reports `Delivered …` as
each student receives. **Ctrl-C** stops the remaining senders. Per-transfer logs
are written next to the bundles as `.croc-<node>.log`.

> **The two waits are different.** Before the table appears, the bundles are
> rendered for every selected certificate (a moment per node). If the local
> `/etc/nebula/config.yml` is service-owned and unreadable, the tool asks there —
> **visibly** — whether it may read it once with temporary sudo; batch prompts are
> routed to the terminal even though each bundle's stderr goes to
> `.bundle-<node>.log`. After the table it waits for students by design; that
> second wait is not a hang.

#### Relays: the public one can refuse you

croc's public relay rate-limits admissions. A class starting at the same moment
can hit `relay admission rejected` / `could not connect`, and the transfer fails
(croc exits `0` in that case — the tool now reports it as a failure). Run your
own relay on a host with a reachable IP (the VPS, or a machine in the lab) and
use it on **both** sides:

```bash
# once, on the relay host (TCP 9009-9013; 9009 is the main port)
croc relay --host 0.0.0.0 --ports 9009,9010,9011,9012,9013

# teacher: serve every bundle through that relay
nebula-manager fleet croc --relay vps.theprof.demo:9009 --select group:students

# student: same relay, then the code
croc --relay vps.theprof.demo:9009 CODE
```

`CROC_RELAY=host:9009` works as a default for the manager, and the printed
“Students run” lines already include `--relay …` when one is set. Only a relay the
students can reach is useful — on a lab LAN, the teacher's machine is often the
fastest relay and needs no internet at all.

#### Three levers against the rate limit

In order of usefulness:

1. **A relay you control** (above). This is the fix. The public pool limits
   admissions per *source IP*, and a whole lab shares the campus NAT address, so
   every student looks like one impatient client.
2. **`--local`** for a lab LAN: croc uses multicast discovery plus a relay on the
   teacher's machine and never contacts the internet. Works only inside one
   broadcast domain — the lab VLAN yes, eduroam-to-lab no.

   ```bash
   nebula-manager fleet croc --local --select group:students
   ```

   The printed receive command then starts with `croc --local`, so students on
   the same LAN can receive without any relay.
3. **`--delay SECONDS`** spaces the senders apart (`--delay 5`): thirty joins
   become a slow ramp instead of a burst. It lowers the chance of hitting the
   limit, it does not remove it — every sender still waits for its own student, so
   with `--delay 5` the last code only starts after two and a half minutes.

If all of that is still awkward, plain HTTP is a perfectly good classroom server
and needs no protocol at all — publish the output directory and hand out the URL:

```bash
python3 -m http.server 8000 --directory fleet-bundles-20261025-101500
```

A student then runs `wget http://TEACHER-IP:8000/alice.theprof.mesh-nebula-bundle.zip`.
On a shared/untrusted network that also means the archives are readable by
anyone on that network — the ZIP **does** contain the client private key, so use
it on a lab LAN, not on eduroam. (The bundles are protected by the fact that the
file name is only known to the class, which is not a security boundary; the CA key
is never in a bundle.)

#### Why there is no single bundle for the whole class

`croc store --downloads N --expiration 1d` exists (one upload, N downloads, plus a
browser link) and looks like the obvious answer, but it does not fit here:

- **A bundle is bound to one certificate.** Sharing one archive means every
  machine installs the same certificate and therefore the same overlay IP. Two
  such hosts on one mesh fight over the address.
- **Public stored transfers are rate limited too:** five upload creations per hour
  and two unfinished uploads per source IP by default. Thirty per-node uploads do
  not fit, and a self-hosted store (`croc store --url`) is yet another service to
  run.

The workable “download once, everybody gets it” shape is one **class pack**: a
single archive holding one folder per node (`alice.theprof.mesh/{*.crt,*.key,*.yml,
install.sh}`), distributed by `croc store`, HTTP or copyparty; each student
unpacks their own folder. It is on the roadmap (`fleet pack`).

- Selection uses the usual grammar: `group:G`, `without:G`, `name:GLOB`,
  `ip:CIDR`, `cert:NAME`, or `all` (repeatable). A bare existing group name
  (`ulno`) is accepted as `group:ulno`. Mobile certs (no local `.key`)
  are skipped with a note.
- Firewall: `--policy PACK` (e.g. the class policy) or `--firewall
  host|permissive|default|pack:NAME|skip`. Without either, each node's saved
  choice from certificate creation (or the last choice) is used, else the
  detected host firewall.
- `--out DIR` (default `./fleet-bundles-<timestamp>`, which is git-ignored
  along with its `.croc-*.log` / `.bundle-*.log` files because the archives
  contain private keys), `--relay HOST[:PORT]` (own croc relay; both sides must
  use it), `--local` (LAN only, no public relay), `--delay SECONDS` (pause
  between senders), `--code-prefix TEXT`, `--timeout SECONDS` (default:
  wait forever), `--dry-run` (create bundles and print codes/commands, start no
  senders).
- Each student runs the code, extracts the archive and runs the installer:
  `croc CODE`, then `unzip '*.zip'` / `Expand-Archive`, then
  `sudo bash install.sh` (or `install.ps1`). The bundle's `README.txt` contains
  the exact lines.
- Senders use croc's secure mode (`CROC_SECRET=<code> croc send …`). Croc 11.x
  rejects the older `send --code` form by printing a usage notice and exiting
  `0`; the tool recognises that and reports it as an error instead of
  `Delivered`.

### SSH push to one node

First probe, then push:

```bash
nebula-manager fleet probe node4
nebula-manager fleet probe node4 --domain theprof.net --domain netbird.cloud
# name expansion: node4.<your-cert-domain>, node4.netbird.cloud,
#                 node4.local, node4  (first open port 22 wins)
# Tailscale MagicDNS needs its tailnet suffix: --host node4.<tailnet>.ts.net
# login candidates: current user, root, user (or --user/--host)
# requires key-based SSH; non-root also needs passwordless sudo

nebula-manager fleet ssh node4 --policy home --yes
nebula-manager fleet ssh node4 --config ./node4-config.yml --dry-run
nebula-manager fleet ssh node4 --firewall-file ./policies/node4/firewall.yml
nebula-manager fleet ssh root@node4.theprof.mesh --firewall permissive --no-restart
```

What `fleet ssh` does:

1. probes the candidate names and users (as above); if no key login works it
   offers one interactive user attempt, then prints `ssh-copy-id` guidance;
2. fetches the remote config (`--remote-config`, default `/etc/nebula/config.yml`);
3. merges the change **locally** — a policy pack / firewall mode replaces only
   the `firewall:` section, or `--config FILE` replaces the whole file;
   `--firewall-file FILE` also accepts a bare firewall mapping (as written by
   `policy export`);
4. shows a **unified diff** and asks (unless `--yes`);
5. uploads with a timestamped remote backup (`<config>.bak.YYYYmmdd-HHMMSS`);
6. validates with `nebula -test` and restarts `--service` (default
   `nebula.service`) unless `--no-restart`.

Root logins need no `sudo`; other users must have passwordless sudo for
unattended changes. `--dry-run` still fetches (read-only) and prints the exact
commands without changing anything.

---

## Where to next?

- **Build the bundles first** → [bundles.md](bundles.md)
- **Choose the firewall inside them** → [firewall.md](firewall.md)
- **Scripted CLI details** → [usage.md](usage.md)
