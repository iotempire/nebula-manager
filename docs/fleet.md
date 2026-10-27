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

- Selection uses the usual grammar: `group:G`, `without:G`, `name:GLOB`,
  `ip:CIDR`, `cert:NAME`, or `all` (repeatable). Mobile certs (no local `.key`)
  are skipped with a note.
- Firewall: `--policy PACK` (e.g. the class policy) or `--firewall
  host|permissive|default|pack:NAME|skip`. Without either, each node's saved
  choice from certificate creation (or the last choice) is used, else the
  detected host firewall.
- `--out DIR` (default `./fleet-bundles-<timestamp>`, which is git-ignored
  along with its `.croc-*.log` / `.bundle-*.log` files because the archives
  contain private keys), `--code-prefix TEXT`, `--timeout SECONDS` (default:
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
