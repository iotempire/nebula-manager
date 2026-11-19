#!/usr/bin/env bash
# Test: fleet SSH probing and config/firewall push (mocked ssh/nc).
#   * name expansion tries the cert domain first, then NetBird/local/bare
#   * port 22 is probed before login attempts
#   * users are tried (current, root, user) and the first key login wins
#   * a policy pack is merged locally, diffed, uploaded with a backup, tested
#   * root needs no sudo; non-root requires passwordless sudo
#   * --dry-run changes nothing; unreachable targets fail with guidance
set -uo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/helpers.sh"

TEST_LABEL="fleet SSH deployment"
harness_init
require_cmd nebula-cert
require_cmd jq
require_cmd yq

keys="$SANDBOX/keys"
export CERT_DIR_OVERRIDE="$keys"
CA_NAME="test-ca" CERT_DIR="$keys" pki_ca_create >/dev/null 2>&1 || {
    echo "SKIP: cannot create a CA with the installed nebula-cert"; exit 77; }
SIGN_NAME="alice.theprof.mesh" SIGN_IP="10.92.0.2/24" SIGN_GROUPS="home" \
    CERT_DIR="$keys" pki_sign >/dev/null 2>&1

mkdir -p "$(policy_dir)"
cat > "$(policy_dir)/home.yml" <<'YAML'
name: home
groups: [home]
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
YAML

# Fake remote config and a "new" config for the --config path.
cat > "$SANDBOX/remote.yml" <<'YAML'
pki:
  ca: /etc/nebula/ca.crt
firewall:
  inbound_action: reject
  inbound: []
  outbound:
    - port: any
      proto: any
      host: any
YAML
cp "$SANDBOX/remote.yml" "$SANDBOX/push.yml"
printf '\n# pushed directly\n' >> "$SANDBOX/push.yml"
export FAKE_REMOTE_CFG="$SANDBOX/remote.yml"
export SSH_LOG="$SANDBOX/ssh.log" NC_LOG="$SANDBOX/nc.log"
: > "$SSH_LOG"; : > "$NC_LOG"

# Mock nc: only node4.theprof.mesh:22 is open.
cat > "$SANDBOX/bin/nc" <<'MOCK'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${NC_LOG:?}"
for a in "$@"; do
    [[ "$a" == "node4.theprof.mesh" || "$a" == "node5.theprof.net" ]] && exit 0
done
exit 1
MOCK
chmod +x "$SANDBOX/bin/nc"

# Mock ssh: key login always succeeds; sudo is passwordless; serve the fake
# remote config, consume uploads and accept the validation/restart commands.
# It also emulates a ControlMaster socket (-M -S path -N), so the interactive
# path can reuse one connection.
cat > "$SANDBOX/bin/ssh" <<'MOCK'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${SSH_LOG:?}"
cmd="" sock="" prev=""
for a in "$@"; do
    case "$a" in *@*) target="$a" ;; esac
    [[ "$prev" == "-S" ]] && sock="$a"
    [[ "$a" == "-N" ]] && master=1
    prev="$a"
    cmd="$a"
done
if [[ "${master:-0}" == 1 ]]; then
    [[ -n "$sock" ]] && : > "$sock"
    exit 0
fi
case "$cmd" in
    true)
        # SSH_KEY_FAILS: no key, only a password login works
        [[ "${SSH_KEY_FAILS:-0}" == 1 && "$*" == *BatchMode=yes* ]] && exit 255
        exit 0 ;;
    "sudo -n true")
        # SUDO_NO_CACHE: per-TTY timestamps only (sudo -v never helps later calls)
        [[ "${SUDO_NO_CACHE:-0}" == 1 ]] && exit 1
        # SUDO_REQUIRE_TTY: passwordless sudo that needs a remote pty
        if [[ "${SUDO_REQUIRE_TTY:-0}" == 1 ]]; then
            [[ "$*" == *"-tt"* ]] && exit 0
            exit 1
        fi
        [[ -f "${HOME}/.sudo-warm" ]] && exit 0
        [[ "${SUDO_NEEDS_PASSWORD:-0}" == 1 ]] && exit 1
        exit 0 ;;
    *"sudo -v"*) : > "${HOME}/.sudo-warm"; exit 0 ;;
    *"| bash"*) exit 0 ;;
    *cat*) cat "${FAKE_REMOTE_CFG:?}"; exit $? ;;
    *"command -v nebula"*) echo /usr/bin/nebula; exit 0 ;;
    *tee*) cat >/dev/null; exit 0 ;;
    *"cp -p"*) exit 0 ;;
    *"-test -config"*) exit 0 ;;
    *"systemctl restart"*) exit 0 ;;
    *) exit 0 ;;
esac
MOCK
chmod +x "$SANDBOX/bin/ssh"

# --- probe: name expansion + user discovery --------------------------------
out="$(fleet_probe node4 --cert-dir "$keys" 2>&1)"; rc=$?
assert_eq "probe succeeds" "$rc" "0"
assert_contains "probe expands the cert domain" "$out" "SSH port 22 is open on node4.theprof.mesh"
assert_contains "probe reports the chosen login" "$out" "Using $(id -un)@node4.theprof.mesh:22"
assert_contains "probe found passwordless sudo" "$out" "passwordless sudo"
assert_contains "nc probed the cert domain" "$(cat "$NC_LOG")" "node4.theprof.mesh"

# --- explicit --domain candidate --------------------------------------------
out="$(fleet_probe node5 --domain theprof.net --cert-dir "$keys" 2>&1)"; rc=$?
assert_eq "probe with --domain succeeds" "$rc" "0"
assert_contains "--domain candidate is used" "$out" "node5.theprof.net"

# --- push a policy pack -----------------------------------------------------
: > "$SSH_LOG"
out="$(fleet_ssh_cli node4 --policy home --yes --no-restart --cert-dir "$keys" 2>&1)"; rc=$?
assert_eq "policy push exits 0" "$rc" "0"
assert_contains "push shows the diff" "$out" "inbound_action: drop"
assert_contains "push installed the config" "$out" "Installed config on node4.theprof.mesh"
assert_contains "push validated with nebula" "$out" "nebula -test passed"
assert_contains "push backed up the old config" "$(cat "$SSH_LOG")" ".bak."
assert_contains "push uploaded via tee" "$(cat "$SSH_LOG")" "tee"
assert_contains "push tested the config" "$(cat "$SSH_LOG")" "-test -config"
assert_not_contains "no restart with --no-restart" "$(cat "$SSH_LOG")" "systemctl restart"

# --- a restart reapplies mesh DNS -------------------------------------------
: > "$SSH_LOG"
out="$(fleet_ssh_cli node4 --policy home --yes --cert-dir "$keys" 2>&1)"; rc=$?
assert_eq "push with restart exits 0" "$rc" "0"
assert_contains "the service is restarted" "$out" "Restarted nebula.service"
assert_contains "the DNS hook is restarted with the service" \
    "$(cat "$SSH_LOG")" "systemctl restart nebula-manager-resolved.service"
assert_contains "the DNS reapply is reported" "$out" "Reapplied mesh DNS"

# --- --from-store pushes each node's own stored config ----------------------
printf 'tun:\n  dev: nebula9\n' > "$keys/alice.theprof.mesh.yml"
out="$(fleet_ssh_cli alice.theprof.mesh --host node4.theprof.mesh --from-store \
    --cert-dir "$keys" --dry-run 2>&1)"; rc=$?
assert_eq "--from-store dry-run exits 0" "$rc" "0"
assert_contains "--from-store pushes the stored node config" "$out" "nebula9"

out="$(fleet_update_cli --select cert:alice.theprof.mesh --host node5.theprof.net \
    --from-store --cert-dir "$keys" --dry-run --yes 2>&1)"; rc=$?
assert_eq "fleet update forwards --from-store" "$rc" "0"
assert_contains "fleet update renders the per-node config" "$out" "nebula9"

rm -f "$keys/alice.theprof.mesh.yml"
out="$(fleet_ssh_cli alice.theprof.mesh --host node4.theprof.mesh --from-store \
    --cert-dir "$keys" --dry-run 2>&1)"; rc=$?
assert_ne "--from-store without a stored config fails" "$rc" "0"
assert_contains "the missing store config is explained" "$out" "cert config generate"

# --- root login: no sudo anywhere ------------------------------------------
: > "$SSH_LOG"
out="$(fleet_ssh_cli node4 --user root --config "$SANDBOX/push.yml" --dry-run --cert-dir "$keys" 2>&1)"; rc=$?
assert_eq "root dry-run exits 0" "$rc" "0"
assert_contains "root dry-run shows the plan" "$out" "Dry run: would upload"
assert_not_contains "root needs no sudo" "$out" "sudo -n"
assert_not_contains "root SSH calls need no sudo" "$(cat "$SSH_LOG")" "sudo -n true"

# --- bare firewall fragment (as written by policy export) -------------------
cat > "$SANDBOX/firewall-fragment.yml" <<'YAML'
inbound_action: drop
inbound:
  - port: 22
    proto: tcp
    host: any
outbound: []
YAML
out="$(fleet_ssh_cli node4 --firewall-file "$SANDBOX/firewall-fragment.yml" --dry-run --cert-dir "$keys" 2>&1)"; rc=$?
assert_eq "bare firewall fragment dry-run exits 0" "$rc" "0"
assert_contains "bare firewall fragment is merged" "$out" "port: 22"

# --- unreachable target ----------------------------------------------------
out="$(fleet_probe nowhere --cert-dir "$keys" 2>&1)"; rc=$?
assert_ne "unreachable target fails" "$rc" "0"
assert_contains "explains the candidates" "$out" "Could not reach any candidate"
assert_contains "suggests an explicit host" "$out" "--host"

assert_eq "no local sudo used" "$(sudo_count)" "0"

# --- interactive auth: password allowed, no shared session with key auth ----
: > "$SSH_LOG"
out="$(SUDO_NEEDS_PASSWORD=1 fleet_ssh_cli node4 --policy home --interactive --dry-run 2>&1)"; rc=$?
assert_eq "interactive dry-run exits 0" "$rc" "0"
assert_contains "interactive allows password auth" "$(cat "$SSH_LOG")" "password,keyboard-interactive"
assert_contains "interactive explains what it uses" "$out" "key auth, prompts allowed"
assert_not_contains "no shared session for a key login" "$(cat "$SSH_LOG")" "-M -S "
assert_not_contains "no sudo warm-up (per-TTY timestamps)" "$(cat "$SSH_LOG")" "sudo -v"
assert_contains "interactive announces the sudo password" "$out" "sudo will ask for your password"
stage_line="$(grep "cp -p '/etc/nebula/config.yml'" "$SSH_LOG" | tail -n1)"
assert_contains "the privileged read of the config runs in a TTY session" "$stage_line" "-tt"
read_line="$(grep "cat '/tmp/nm-read" "$SSH_LOG" | tail -n1)"
assert_contains "the content is read back from a staged copy" "$read_line" "nm-read"
assert_not_contains "the read-back is no TTY session (its prompt would be hidden)" "$read_line" "-tt"
assert_contains "the staged copy is removed" "$read_line" "rm -f"

# --- ssh password login: one shared session, verified and reused -------------
: > "$SSH_LOG"
out="$(SSH_KEY_FAILS=1 fleet_ssh_cli node4 --policy home --yes --interactive --dry-run 2>&1)"; rc=$?
assert_eq "password-login dry-run exits 0" "$rc" "0"
assert_contains "a password login opens one shared session" "$(cat "$SSH_LOG")" "-M -S "
assert_contains "the shared session is announced" "$out" "Opening one shared SSH session"
assert_contains "the login mode is reported" "$out" "password login"
fetch_line="$(grep "cat '/etc/nebula/config.yml'" "$SSH_LOG" | tail -n1)"
assert_contains "the fetch reuses the shared session" "$fetch_line" "-S /tmp/nm-ssh"

# Without --interactive, a sudo password is an actionable error.
rm -f "$HOME/.sudo-warm"
out="$(SUDO_NEEDS_PASSWORD=1 fleet_ssh_cli node4 --policy home --dry-run 2>&1)"; rc=$?
assert_ne "passwordless sudo is required without --interactive" "$rc" "0"
assert_contains "the error suggests --interactive" "$out" "--interactive"

# --- fleet update: serial over a selection, short host names ----------------
CERT_DIR="$keys" SIGN_NAME="bob.theprof.mesh" SIGN_IP="10.92.0.3/24" SIGN_GROUPS="home" pki_sign >/dev/null 2>&1
CERT_DIR="$keys" SIGN_NAME="phone.theprof.mesh" SIGN_IP="10.92.0.4/24" SIGN_GROUPS="home" pki_sign >/dev/null 2>&1
rm -f "$keys/phone.theprof.mesh.key"      # device certificate: no local key
cat > "$SANDBOX/bin/nc" <<'MOCK'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${NC_LOG:?}"
for a in "$@"; do
    case "$a" in
        node4.theprof.mesh|node5.theprof.net|alice|bob|alice.theprof.mesh|bob.theprof.mesh) exit 0 ;;
    esac
done
exit 1
MOCK
chmod +x "$SANDBOX/bin/nc"

: > "$SSH_LOG"
out="$(fleet_update_cli --select cert:alice.theprof.mesh --host node5.theprof.net \
    --policy home --yes --dry-run 2>&1)"; rc=$?
assert_eq "single-host update exits 0" "$rc" "0"
assert_contains "single-host update names the node" "$out" "alice.theprof.mesh  ->  node5.theprof.net"
assert_contains "single-host update prints a summary" "$out" "Fleet update summary"
assert_contains "single-host update reports the result" "$out" "updated"

assert_eq "fleet update without a change is refused" \
    "$(fleet_update_cli --select all >/dev/null 2>&1; echo $?)" "2"

out="$(fleet_update_cli --select group:home --short --policy home --dry-run --yes 2>&1)"; rc=$?
assert_eq "serial update exits 0" "$rc" "0"
assert_contains "serial update counts the nodes" "$out" "2 updated"
assert_contains "serial update lists the second node" "$out" "bob.theprof.mesh  ->  bob"
assert_contains "serial update skips device certificates" "$out" "device certificate"
assert_contains "serial update reports the skip count" "$out" "2 updated, 0 failed, 1 skipped"

# --- how the auth mode is decided ------------------------------------------
assert_eq "interactive mode: forced on" \
    "$(FLEET_INTERACTIVE_MODE=on; _fleet_want_interactive; echo $?)" "0"
assert_eq "interactive mode: forced off" \
    "$(FLEET_INTERACTIVE_MODE=off; _fleet_want_interactive; echo $?)" "1"
assert_eq "interactive mode: auto is key-only when prompts are disabled" \
    "$(FLEET_INTERACTIVE_MODE=auto; NEBULA_NO_PROMPT=1; _fleet_want_interactive; echo $?)" "1"

rm -f "$HOME/.sudo-warm"
out="$(SUDO_NEEDS_PASSWORD=1 fleet_ssh_cli node4 --policy home \
    --interactive --no-interactive --dry-run 2>&1)"; rc=$?
assert_ne "--no-interactive wins over --interactive" "$rc" "0"
assert_contains "forced key-only explains the requirement" "$out" "passwordless sudo"

out="$(SUDO_NEEDS_PASSWORD=1 fleet_update_cli --select cert:alice.theprof.mesh \
    --host node5.theprof.net --policy home --yes --no-interactive --dry-run 2>&1)"; rc=$?
assert_eq "fleet update forwards --no-interactive" "$rc" "1"
assert_contains "fleet update reports the failed host" "$out" "1 failed"

# --- sudo password (per-TTY timestamps): one privileged session -------------
: > "$SSH_LOG"
out="$(SUDO_NO_CACHE=1 fleet_ssh_cli node4 --policy home --yes --interactive 2>&1)"; rc=$?
assert_eq "sudo-password apply exits 0" "$rc" "0"
assert_contains "the password mode is announced" "$out" "sudo password (per session)"
assert_contains "the apply runs as one script session" "$(cat "$SSH_LOG")" "| bash"
assert_contains "the apply payload is not piped through our stdin" "$(grep '| bash' "$SSH_LOG" | tail -n1)" "printf %s"
assert_contains "the install is reported" "$out" "Installed config on"
assert_contains "the validation is reported" "$out" "nebula -test passed"
assert_contains "the restart is reported" "$out" "Restarted nebula.service"
assert_eq "no separate upload step" "$(grep -c "tee '/tmp" "$SSH_LOG")" "0"
assert_contains "sudo is prompted for at most twice" "$out" "sudo will ask for your password"
assert_not_contains "no sudo warm-up in password mode" "$(cat "$SSH_LOG")" "sudo -v"
payload_b64="$(grep '| bash' "$SSH_LOG" | tail -n1 | sed -n "s/.*printf %s '\([^']*\)'.*/\1/p")"
payload="$(printf '%s' "$payload_b64" | base64 -d 2>/dev/null)"
assert_contains "the privileged apply restarts the DNS hook" "$payload" "nebula-manager-resolved.service"
assert_contains "the backup is only made once (retry-safe)" "$payload" "test -e"
assert_contains "the validation is guarded" "$payload" "nebula -test FAILED"

# passwordless sudo that only works with a TTY (sudoers requiretty)
: > "$SSH_LOG"
out="$(SUDO_REQUIRE_TTY=1 fleet_ssh_cli node4 --policy home --yes --interactive 2>&1)"; rc=$?
assert_eq "requiretty apply exits 0" "$rc" "0"
assert_contains "requiretty uses a TTY for sudo" "$(cat "$SSH_LOG")" "-tt"
assert_eq "requiretty does not enter password mode" \
    "$(printf '%s' "$out" | grep -c 'sudo password')" "0"

# --- helpers ----------------------------------------------------------------
assert_eq "full host helper" "$(_fleet_host_for a.b.mesh 0)" "a.b.mesh"
assert_eq "short host helper" "$(_fleet_host_for a.b.mesh 1)" "a"

harness_summary
