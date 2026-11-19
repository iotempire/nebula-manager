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
(`ulno`) is accepted as `group:ulno`, and a bare `name:zbook` (no wildcard) that
matches nothing exactly is retried as `name:*zbook*`. Mobile certs (no local
`.key`) are skipped with a note - they are set up with a QR code instead
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
(see [bundles.md](bundles.md#self-contained-installers)).

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

nebula-manager fleet ssh node4 --policy home --yes
nebula-manager fleet ssh node4 --config ./node4-config.yml --dry-run
nebula-manager fleet ssh node4 --from-store --dry-run     # <cert-dir>/<node4>.yml
nebula-manager fleet ssh node4 --firewall-file ./policies/node4/firewall.yml
nebula-manager fleet ssh root@node4.theprof.mesh --firewall permissive --no-restart
```

`--from-store` pushes `<cert-dir>/<name>.yml`, the config the manager wrote next
to the certificate (firewall, relay, lighthouse — everything the store knows
about that node). It is the right choice when you want a node to match what the
workspace says, whereas `--policy`/`--relay` merge a *single* aspect into the
node's existing file and leave everything else alone. `--config FILE` replaces
the remote file with a file you name.

What `fleet ssh` does:

1. probes the candidate names and users (as above); if no key login works it
   offers one interactive user attempt, then prints `ssh-copy-id` guidance;
2. fetches the remote config (`--remote-config`, default `/etc/nebula/config.yml`);
3. merges the change **locally** — a policy pack / firewall mode replaces only
   the `firewall:` section, a `--relay`/`--no-relay` replaces only the `relay:`
   block, or `--config FILE` replaces the whole file; `--firewall-file FILE`
   also accepts a bare firewall mapping (as written by `policy export`);
4. shows a **unified diff** and asks (unless `--yes`);
5. uploads to a `/tmp` file on the remote host, backs up the old config
   (`<config>.bak.YYYYmmdd-HHMMSS`) and moves the new one into place;
6. validates with `nebula -test` and restarts `--service` (default
   `nebula.service`) unless `--no-restart` — and then restarts
   `nebula-manager-resolved.service`, because the new tun device starts without
   the per-link mesh DNS settings (see [dns.md](dns.md); hosts whose hook has
   `PartOf=nebula.service` restart it automatically, this also fixes older
   ones).

Root logins need no `sudo`; other users need `sudo`. For unattended runs
(scripts, cron, CI) everything is key-only and `sudo -n`, so passwordless sudo is
required. When **you** run it at a terminal, the manager asks for passwords when
they are actually needed — see below.

`--dry-run` still fetches (read-only) and prints the exact commands without
changing anything.

### Typing passwords (ssh and remote sudo)

**Nothing to add for normal use.** The decision is automatic:

| Situation | Behaviour |
|---|---|
| You run it in a terminal (`NEBULA_NO_PROMPT` unset) | keys first; if that fails, one password attempt; if sudo needs a password, it is asked once |
| Script, cron, CI, or `NEBULA_NO_PROMPT=1` | keys only, `sudo -n`; a sudo password is an error |
| `--interactive` | always allow password prompts |
| `--no-interactive` (alias `--batch`) | never prompt, even in a terminal |

When prompts are allowed:

- **ssh** may use a password (`publickey,password,keyboard-interactive`). If the
  key login does not work, the manager tries one password login for the most
  likely account, then offers to try a different user;
- a **shared connection** (`ControlMaster`) is opened **only when that login
  itself needed a password**, so the ssh password is asked once. With key auth
  none is opened: it would save nothing (sudo's timestamp is per TTY) and a
  master that dies fails every later step with “Shared connection … closed”;
- **sudo** is classified once and the summary line names the case:
  `passwordless sudo`, `sudo (TTY)` (a sudoers `requiretty`, no password), or
  `sudo password (per session)`; the login mode is shown next to it
  (`key auth`, `key auth, prompts allowed`, `password login`);

**Why sudo can ask twice.** sudo caches its timestamp **per TTY**
(`timestamp_type=tty`, the default) and every `ssh -tt` allocates a fresh pty,
so `sudo -v` in one session cannot authorize the next one — the manager never
“warms” it. The probe classifies sudo **without prompting**, and the work is
grouped into as few TTY sessions as possible:

1. one TTY session **stages a user-readable copy** of the remote config
   (`sudo cp -p … && sudo chown "$(id -u)"`), which is where the password is
   first asked — so a typo fails before anything is written. The copy is then
   read with a plain `cat` and removed. Reading with `sudo cat > file` would
   *not* work: with a TTY the prompt is part of the session's stdout, so it
   would be written into the file and sudo would wait for input you cannot see;
2. one further privileged TTY session does the **backup, write, `nebula -test`
   and start/restart together** (the config travels base64-encoded inside that
   session).

So sudo asks at most **twice** for a whole `fleet ssh`, never once per command.
If your sudoers uses `timestamp_type=global`, the second session reuses the
timestamp and you type the password only once.

The apply script itself travels as a base64 **argument**, never through the
manager's stdin: with `ssh -tt` the remote sudo prompt reads the remote tty,
and that tty is fed by whatever we hand ssh's stdin — a piped script would
silently become the answer to “`[sudo] password`”. If there is no terminal at
all (no stdin tty and no `/dev/tty`), the manager refuses up front instead of
waiting for a password nobody can type.

The remote temp file (`/tmp/nebula-manager-config.<pid>.yml`) is always written
by you, and only the final copy is elevated.

```bash
# force prompts (e.g. inside a pipeline where stdin is not a terminal)
nebula-manager fleet ssh node4 --policy home --interactive
# force keys-only in a terminal (testing that keys/sudoers really work)
nebula-manager fleet ssh node4 --policy home --no-interactive
```

### Updating several nodes, one after the other

```bash
# every node of a group, in mesh-name order, one SSH session per host
nebula-manager fleet update --select group:lab01 --policy lab01 --interactive

# short host names (node instead of node.pod.mesh) when your local DNS knows them
nebula-manager fleet update --select name:router* --short --no-relay --yes

# one node, but with an explicit host (useful when only the IP is known)
nebula-manager fleet update --select cert:ulno-ge75.ulno.mesh \
    --host root@10.20.30.44 --relay 10.100.0.1 --dry-run
```

`fleet update` resolves the target from the **certificate name** (the full mesh
hostname by default), runs `fleet ssh` for each match with the same options, and
prints a summary:

```
=== 2/5  bob.lab01.mesh  ->  bob.lab01.mesh ===
…diff…
[+] Installed config on bob.lab01.mesh (backup: /etc/nebula/config.yml.bak.20261119-101500)
```

```
Fleet update summary:
  Node                                     Result
  alice.lab01.mesh                         updated
  bob.lab01.mesh                           updated
  phone.lab01.mesh                         skipped
3 updated, 0 failed, 1 skipped
```

- `--host` forces one host for every selected node; otherwise each certificate
  name is used (`--short` = first label only). The probe still tries
  `<name>.<domain>`, `.netbird.cloud`, `.local` and the bare name, so a
  locally-reachable host works without extra flags.
- Authentication follows the same automatic rule as `fleet ssh` (prompts when you
  are at a terminal, keys-only in scripts); `--interactive` / `--no-interactive`
  force one behaviour for the whole run.
- Device certificates (no local key) are skipped.
- Failures do not stop the run; the summary lists them and the exit code is
  non-zero.
- **TUI:** *Fleet ▸ Update node(s) over SSH* walks through: nodes → host name
  (full/short/custom) → login user (current/root/user/other) → keys or
  `--interactive` → what to change: a policy pack, a built-in mode, the relay,
  relay + pack, **each node's stored `<name>.yml`**, or another config file you
  name (the prompt already suggests the stored config of the node you selected).

---

## Where to next?

- **Build the bundles first** → [bundles.md](bundles.md)
- **Choose the firewall inside them** → [firewall.md](firewall.md)
- **Scripted CLI details** → [usage.md](usage.md)
