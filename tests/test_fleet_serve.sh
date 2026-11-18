#!/usr/bin/env bash
# Test: `fleet serve` - HTTP distribution of a bundle directory (a whole class).
#   * copyparty backend: read-only volume + one login for the class
#   * python backend: plain http.server, and an explicit "no password" warning
#   * a password is generated when a user is given without one
#   * the newest ./fleet-bundles-* is the default directory
#   * --dry-run prints everything and starts no server
set -uo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/helpers.sh"

TEST_LABEL="fleet serve (HTTP)"
harness_init

# Mock copyparty: record the call. It must never actually be started here.
cat > "$SANDBOX/bin/copyparty" <<'MOCK'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${COPYPARTY_LOG:?}"
exit 0
MOCK
chmod +x "$SANDBOX/bin/copyparty"
export COPYPARTY_LOG="$SANDBOX/copyparty.log"; : > "$COPYPARTY_LOG"

dir="$SANDBOX/fleet-bundles-20260101-101010"
mkdir -p "$dir"
: > "$dir/alice.mesh-nebula-bundle.zip"
: > "$dir/bob.mesh-nebula-bundle.zip"

# --- python backend ----------------------------------------------------------
out="$(fleet_serve_cli --dir "$dir" --port 8123 --url-host 10.1.2.3 --backend python --user class --dry-run 2>&1)"
assert_eq "python serve exits 0" "$?" "0"
assert_contains "python command is printed" "$out" "python3 -m http.server 8123"
assert_contains "python command uses the directory" "$out" "--directory $dir"
assert_contains "URL uses the requested host" "$out" "http://10.1.2.3:8123/"
assert_contains "per-file URL is listed" "$out" "http://10.1.2.3:8123/alice.mesh-nebula-bundle.zip"
assert_contains "bundle count is shown" "$out" "2 bundle(s)"
assert_contains "python backend has no password" "$out" "**no password**"
assert_contains "python backend ignores --user" "$out" "--user is ignored with the python backend"
assert_contains "copyparty is suggested" "$out" "pip install --user copyparty"
assert_contains "dry run does not start the server" "$out" "Dry run: the server was not started."
assert_contains "port forwarding is explained" "$out" "forward TCP 8123"
assert_contains "reverse tunnel is explained" "$out" "ssh -R 8123:localhost:8123"
assert_empty_file "python backend never needs copyparty" "$COPYPARTY_LOG"

# --- copyparty backend -------------------------------------------------------
out="$(fleet_serve_cli --dir "$dir" --port 3923 --url-host teach.lan \
        --backend copyparty --user class --password s3cret --dry-run 2>&1)"
assert_eq "copyparty serve exits 0" "$?" "0"
assert_contains "copyparty command is printed" "$out" "copyparty -p 3923"
assert_contains "copyparty account is set" "$out" "-a class:s3cret"
assert_contains "copyparty volume is read-only for the class" "$out" "-v $dir:/bundles:r,class"
assert_contains "login is shown" "$out" "login:    class / s3cret"
assert_contains "copyparty URL is under /bundles" "$out" "http://teach.lan:3923/bundles/"
assert_contains "class notes mention uploads are off" "$out" "no uploads"
assert_empty_file "dry run did not start copyparty" "$COPYPARTY_LOG"

# --- a password is generated when only a user is given ----------------------
out="$(fleet_serve_cli --dir "$dir" --backend copyparty --user class --dry-run 2>&1)"
assert_contains "a password is generated" "$out" "password generated for this run"
assert_contains "the generated password is shown" "$out" "login:    class / "

# --- copyparty without a user warns about the missing password --------------
out="$(fleet_serve_cli --dir "$dir" --backend copyparty --dry-run 2>&1)"
assert_contains "open copyparty volume is read-only" "$out" "-v $dir:/bundles:r"
assert_contains "open copyparty warns about the missing password" "$out" "**no password**"

# --- default directory = newest fleet-bundles-* -----------------------------
newer="$SANDBOX/fleet-bundles-20260202-202020"
mkdir -p "$newer"
: > "$newer/carol.mesh-nebula-bundle.zip"
sleep 1
out="$(cd "$SANDBOX" && fleet_serve_cli --backend python --url-host h --dry-run 2>&1)"
assert_contains "default directory is the newest one" "$out" "fleet-bundles-20260202-202020"
assert_not_contains "default directory is not the older one" "$out" "fleet-bundles-20260101-101010"
assert_contains "default directory lists its bundle" "$out" "carol.mesh-nebula-bundle.zip"

# --- error handling ---------------------------------------------------------
out="$(fleet_serve_cli --dir "$SANDBOX/missing" 2>&1)"; rc=$?
assert_eq "missing directory is rejected" "$rc" "1"
assert_contains "missing directory is named" "$out" "Not a directory"

out="$(fleet_serve_cli --dir "$dir" --backend bogus 2>&1)"; rc=$?
assert_eq "bad backend is rejected" "$rc" "2"
assert_contains "bad backend is named" "$out" "Invalid --backend"

out="$(fleet_serve_cli --dir "$dir" --port abc 2>&1)"; rc=$?
assert_eq "bad port is rejected" "$rc" "2"
assert_contains "bad port is explained" "$out" "--port must be a number"

out="$(cd "$SANDBOX" && rm -rf "$SANDBOX"/fleet-bundles-* && \
        fleet_serve_cli --backend python --dry-run 2>&1)"; rc=$?
assert_eq "no bundle directory is an error" "$rc" "1"
assert_contains "empty state points at fleet bundle" "$out" "nebula-manager fleet bundle"

assert_eq "no sudo used" "$(sudo_count)" "0"

harness_summary
