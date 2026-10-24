#!/usr/bin/env bash
# Test: plain-text menu navigation.
#   * Enter with no input selects the bold Back (submenu) or Exit (top level)
#   * b/back/.. and q leave a submenu; m jumps to the main menu
#   * /keyword filters the current menu and the global menu index
#   * bare "/" asks for a keyword; "?" prints the key help; hints are shown
set -uo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/helpers.sh"

TEST_LABEL="plain menu navigation"
harness_init
# The entrypoint defines the menu-level actions referenced by the search index
# (main_menu/server_menu/setup_menu/...). It is guarded, so sourcing is safe.
# shellcheck source=/dev/null
source "$REPO_ROOT/nebula-manager"

menu_title=(Test)

# --- Enter selects Exit at the top level ------------------------------------
menu_labels=("Do nothing" "Exit")
menu_actions=("echo ACTION_RAN" "echo DEFAULT_EXIT")
out="$(printf '\n' | dynamic_menu menu_title menu_labels menu_actions 0 "" "Menu hint text" 2>&1)"
assert_contains "Enter selects Exit at the top level" "$out" "DEFAULT_EXIT"
assert_not_contains "Enter does not run a normal item" "$out" "ACTION_RAN"
assert_contains "menu hint is displayed" "$out" "Menu hint text"

# --- Enter selects Back in a submenu ----------------------------------------
menu_labels=("Do nothing")
menu_actions=("touch $SANDBOX/should_not_exist")
printf '\n' | dynamic_menu menu_title menu_labels menu_actions 1 "" "hint" >/dev/null 2>&1
assert_no_file "Enter selects Back in a submenu" "$SANDBOX/should_not_exist"

# --- back keys ---------------------------------------------------------------
for key in b back .. q quit; do
    printf '%s\n' "$key" | dynamic_menu menu_title menu_labels menu_actions 1 "" "hint" >/dev/null 2>&1
    assert_no_file "back key '$key' leaves the submenu" "$SANDBOX/should_not_exist"
done

# --- numeric selection still runs the action --------------------------------
menu_actions=("touch $SANDBOX/one")
printf '1\n' | dynamic_menu menu_title menu_labels menu_actions 1 "" "hint" >/dev/null 2>&1
assert_file "numeric selection runs the action" "$SANDBOX/one"

# --- local search: /firewall picks a matching entry -------------------------
menu_labels=("Zap firewall" "Do nothing")
menu_actions=("echo PICKED_FW" "echo OTHER")
out="$(printf '/firewall\n1\nq\n' | dynamic_menu menu_title menu_labels menu_actions 1 "" "hint" 2>/dev/null)"
assert_contains "search shows its matches" "$out" "Matches for 'firewall'"
assert_contains "search runs the chosen match" "$out" "PICKED_FW"

# --- global search: /firewall finds Instance Settings > Edit Firewall -------
menu_labels=("Do nothing")
menu_actions=("echo OTHER")
out="$(printf '/firewall\n0\nq\n' | dynamic_menu menu_title menu_labels menu_actions 1 "" "hint" 2>/dev/null)"
assert_contains "global search finds Edit Firewall" "$out" "Instance Settings ▸ Edit Firewall"
assert_contains "global search lists all menus" "$out" "Matches for 'firewall'"

out="$(printf '/fir\n0\nq\n' | dynamic_menu menu_title menu_labels menu_actions 1 "" "hint" 2>/dev/null)"
assert_contains "search is a substring match" "$out" "Edit Firewall"

# --- bare "/" asks for a keyword -------------------------------------------
out="$(printf '/\nfirewall\n0\nq\n' | dynamic_menu menu_title menu_labels menu_actions 1 "" "hint" 2>&1)"
assert_contains "bare / then keyword finds the entry" "$out" "Edit Firewall"

# --- help and invalid input -------------------------------------------------
out="$(printf '?\nq\n' | dynamic_menu menu_title menu_labels menu_actions 1 "" "hint" 2>/dev/null)"
assert_contains "help lists the slash shortcut" "$out" "/keyword"
assert_contains "help lists the back keys" "$out" "b, back"

out="$(printf 'zzz\nq\n' | dynamic_menu menu_title menu_labels menu_actions 1 "" "hint" 2>&1)"
assert_contains "invalid input is reported" "$out" "Invalid option"

# --- m jumps back to the main menu from a nested menu ----------------------
inner_title=(Inner)
inner_labels=("Do nothing")
inner_actions=("echo INNER_ACTION")
outer_title=(Outer)
outer_labels=("Open inner menu" "Exit")
outer_actions=("dynamic_menu inner_title inner_labels inner_actions 1 '' 'inner hint'" "echo OUTER_EXIT")
out="$(printf '1\nm\n\n' | dynamic_menu outer_title outer_labels outer_actions 0 '' 'outer hint' 2>/dev/null)"
assert_contains "m unwinds to the main menu" "$out" "OUTER_EXIT"
assert_not_contains "m does not run an inner action" "$out" "INNER_ACTION"

# --- the index only references known actions -------------------------------
missing=""
while IFS='|' read -r path kw target; do
    [[ -n "$path" ]] || continue
    if ! declare -F "$target" >/dev/null; then
        missing+="$target (${path}) "
    fi
done < <(menu_search_index)
assert_eq "global search index targets exist" "$missing" ""

harness_summary
