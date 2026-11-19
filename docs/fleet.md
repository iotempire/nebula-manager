# Fleet deployment

[← Back to README](../README.md) · [Documentation map](../README.md#documentation-map)

---

Three ways to get a client onto another machine, in priority order:

| Path | Use it for | Needs |
|---|---|---|
| **`fleet serve`** (HTTP) | a whole class, everybody at once | one open port (or a reverse tunnel) |
| **`fleet croc`** | one student at a time, NAT/eduroam, no port | nothing but `croc` on both sides |
| **`fleet ssh`** | changing a node you already administer | key login + passwordless sudo |

All three start from the same artifact: a **bundle** (`fleet bundle`) - the
certificate, its private key, `ca.crt`, the rendered client config, `install.sh`,
`install.ps1` and a `README.txt`.

> **Relays.** If some of these nodes cannot reach each other directly (two peers
> behind one NAT, CGNAT, no IPv6), add the `relay:` block before exporting:
> `nebula-manager cert relay --select group:students --relay 10.100.0.1 --rebundle`,
> and `nebula-manager relay local --am-relay on` on the lighthouse. Bundles then
> carry it automatically. Details and the topology rule: [relay.md](relay.md).

**TUI:** **Main Menu ▸ Fleet** shows the three steps in that order: *Prepare
bundles*, *Serve bundles over HTTP*, *Share one bundle via croc*.

> **Why not croc for the whole class?** croc's public relay limits admissions per
> source IP, and a lab full of students is one NAT address. Field test: three
> simultaneous senders, one refused with `relay admission rejected` while the
> other two worked. Running your own relay fixes it, but a password-protected
> HTTP directory is simpler and gives students something they can bookmark. croc
> stays useful for the one-off case.

## Step 1 - prepare the bundles

```bash
nebula-manager fleet bundle --select group:students --policy students
```

```
Bundles ready (/home/theprof/fleet-bundles-20261025-101500):
  Node                             Archive
  ----                             -------
  alice.theprof.mesh               alice.theprof.mesh-nebula-bundle.zip
  bob.theprof.mesh                 bob.theprof.mesh-nebula-bundle.zip

Hand them out:
  whole class (HTTP):   nebula-manager fleet serve --dir "/home/theprof/fleet-bundles-20261025-101500"
  one at a time:        nebula-manager fleet croc --dir "/home/theprof/fleet-bundles-20261025-101500"
  node already set up:  nebula-manager fleet ssh NODE --policy PACK --yes
```

Selection uses the usual grammar: `group:G`, `without:G`, `name:GLOB`,
`ip:CIDR`, `cert:NAME`, or `all` (repeatable); a bare existing group name
(`ulno`) is accepted as `group:ulno`. Mobile certs (no local `.key`) are skipped
with a note - they are set up with a QR code instead
([mobile.md](mobile.md)).

The **firewall** in every generated config comes from, in order: `--policy PACK`,
`--firewall MODE`, the node's saved choice from certificate creation, the last
choice used in the TUI, and finally the detected local host config. The rendered
config is also stored next to the certificate, so the bundle and the store never
disagree.

Nothing is transferred by this command. `fleet-bundles-*` directories are
git-ignored (they contain private keys); `.bundle-<node>.log` holds any build
warnings.

## Step 2a - serve the directory (recommended for a class)

```bash
nebula-manager fleet serve --dir fleet-bundles-20261025-101500 --user class
```

```
Serving fleet-bundles-20261025-101500 (28 bundle(s)) over HTTP
  URL:      http://10.20.30.40:8000/
  login:    class / 6Wq3hJ8tRy2nLpKd
            (password generated for this run)
```

With [copyparty](https://github.com/9001/copyparty) installed, `fleet serve` runs
it read-only with one login for the class:

```bash
copyparty -p 8000 -i 0.0.0.0 -a class:PASS -v /path/fleet-bundles:/bundles:r,class
```

Students open the URL, log in once, and download the archive with their name -
all at the same time, resumable, no codes to pass around. Without copyparty the
command falls back to `python3 -m http.server`, which serves the same files but
**without a password**:

```bash
python3 -m http.server 8000 --directory fleet-bundles-20261025-101500 --bind 0.0.0.0
```

Install it once with `python3 -m pip install --user copyparty` (single file, no
service, no config).

Options: `--port N` (default 8000), `--bind ADDR`, `--user NAME` (a password is
generated when `--password` is missing), `--backend auto|copyparty|python`,
`--url-host HOST` (what to print in the URLs - useful when you know the external
name), `--dry-run` (print command and URLs, start nothing).

### Making it reachable

The URL above only works inside your network. Three options, cheapest first:

```bash
# a) same LAN / lab VLAN: nothing to do
# b) port forward on the router: TCP 8000 -> 10.20.30.40:8000
# c) reverse tunnel from a host with a public address (no router change):
ssh -R 8000:localhost:8000 vps.example.org
#    then hand out http://vps.example.org:8000/  (keep the ssh session open)
# and open the local firewall if one is active:
sudo ufw allow 8000/tcp
```

**Treat the URL as a classroom secret.** The archives contain client private
keys. `--user`/`--password` keeps strangers out; the CA key is never in a bundle,
so a leak costs you the affected node certificates, not the whole mesh. If a
password leaks, recreate the bundles with `--force`-new certificates
(`cert sign`) rather than reusing them.

## Step 2b - share one bundle with croc (one receiver at a time)

For a single student, a demo, or a machine behind NAT with no reachable port:

```bash
nebula-manager fleet croc --select cert:alice.theprof.mesh
# or, reusing what step 1 produced:
nebula-manager fleet croc --dir fleet-bundles-20261025-101500
# or exactly one archive:
nebula-manager fleet croc --bundle fleet-bundles-*/alice.theprof.mesh-nebula-bundle.zip
```

```
=== Sharing 1/2: alice.theprof.mesh ===
Archive: /home/theprof/fleet-bundles-20261025-101500/alice.theprof.mesh-nebula-bundle.zip

Sending 'alice.theprof.mesh-nebula-bundle.zip' (12.9 kB)
Code is: tacit-camera-panda
...
[✔] Delivered alice.theprof.mesh (croc code tacit-camera-panda)

=== Sharing 2/2: bob.theprof.mesh ===
```

- **croc picks the code**, and the manager shows it exactly as croc prints it -
  nothing to pre-compute, and the bundle README keeps a `<CROC-CODE>`
  placeholder because the code does not exist before the send starts.
- Transfers run **one after the other** (`=== Sharing 1/2 ===`): with several
  nodes selected, the next code only appears when the previous student is done.
  The final table lists every node with its code and result, and anything that
  was not delivered is printed as a ready-to-run `fleet croc --bundle …` line.
- **Ctrl-C** aborts the current transfer and stops; the remaining nodes are
  listed, so you can run them again later.
- `--local` keeps croc inside the LAN (multicast discovery + local relay, no
  internet); `--relay HOST[:PORT]` (`CROC_RELAY`) uses your own relay, and both
  sides must pass it. `--dry-run` lists what would be shared and starts nothing.
- A refusal is a failure, not a delivery: croc exits `0` when the relay says
  `relay admission rejected`, so the manager greps its log and reports
  `croc's relay refused the transfer`, suggesting `--local` or `fleet serve`.

Students receive it with:

```bash
croc tacit-camera-panda
unzip '*.zip'
sudo bash install.sh
```

On Windows: `Expand-Archive` the archive and run `install.ps1` in PowerShell
(see [windows.md](windows.md)).

## Step 2c - push a change to a node you already run (SSH)

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
