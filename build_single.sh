#!/usr/bin/env bash
#
# build_single.sh - assemble dist/nebula-manager (one self-contained executable)
# ==============================================================================
# lib/ stays the canonical source tree: this script only reads it and splices
# the modules between the BUNDLE:MODULES markers in the entrypoint. The runtime
# assets (config template + client-bundle installers/README) are embedded as
# quoted here-docs and materialised into the user cache on first run.
#
# Usage:
#   ./build_single.sh [OUTPUT_PATH]
#
# Defaults to dist/nebula-manager and also writes dist/nebula-manager.sha256.
# The generated artifact is a release asset; keep it out of git.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
OUT="${1:-$REPO_ROOT/dist/nebula-manager}"
OUT_DIR="$(dirname "$OUT")"
ENTRY="$REPO_ROOT/nebula-manager"

MODULES=(ui pki select bench system import policy store fleet)
ASSETS=(nebula-manager.conf.template bundle/install.sh bundle/install.ps1 bundle/README.txt)

START_MARK='# >>> BUNDLE:MODULES >>>'
END_MARK='# <<< BUNDLE:MODULES <<<'
# Must not occur in any embedded asset (checked below); deliberately not "EOF".
DELIM='NEBULA_MANAGER_SINGLE_FILE_ASSET_EOF'

die() { printf 'build_single: %s\n' "$*" >&2; exit 1; }

[[ -r "$ENTRY" ]] || die "entrypoint not found: $ENTRY"
grep -Fq -- "$START_MARK" "$ENTRY" || die "missing start marker in $ENTRY"
grep -Fq -- "$END_MARK" "$ENTRY" || die "missing end marker in $ENTRY"

MANAGER_VERSION="$(sed -n 's/^MANAGER_VERSION="\([^"]*\)"$/\1/p' "$ENTRY" | head -n1)"
[[ -n "$MANAGER_VERSION" ]] || die "could not read MANAGER_VERSION from $ENTRY"
ASSET_ID="$(for asset in "${ASSETS[@]}"; do cat "$REPO_ROOT/lib/$asset"; done | sha256sum | cut -c1-12)"
[[ -n "$ASSET_ID" ]] || die "could not hash the embedded assets"

for module in "${MODULES[@]}"; do
    f="$REPO_ROOT/lib/$module.sh"
    [[ -r "$f" ]] || die "missing module: $f"
    if grep -Fq -- "$START_MARK" "$f" || grep -Fq -- "$END_MARK" "$f"; then
        die "module $f contains a BUNDLE marker"
    fi
done
for asset in "${ASSETS[@]}"; do
    f="$REPO_ROOT/lib/$asset"
    [[ -s "$f" ]] || die "missing or empty asset: $f"
    if grep -Fq -- "$DELIM" "$f"; then
        die "asset $f contains the here-doc delimiter '$DELIM'"
    fi
done

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT
replacement="$tmpdir/replacement"
spliced="$tmpdir/nebula-manager"

# ---------------------------------------------------------------------------
# Block that replaces the BUNDLE:MODULES section.
# ---------------------------------------------------------------------------
{
    printf '%s\n' '###################################################################'
    printf '%s\n' '# Single-file release build: modules and assets are embedded.'
    printf '%s\n' '# The modular source tree in lib/ remains canonical.'
    printf '%s\n' '###################################################################'
    printf 'nebula_manager_single_file_materialize_assets() {\n'
    printf '    local root="${XDG_CACHE_HOME:-$HOME/.cache}/nebula-manager/single-file-assets/%s-%s"\n' "$MANAGER_VERSION" "$ASSET_ID"
    printf '%s\n' '    local marker="$root/.complete"'
    printf '%s\n' '    if [[ -f "$marker" ]]; then'
    printf '%s\n' '        MANAGER_LIB_DIR="$root"'
    printf '%s\n' '        export MANAGER_LIB_DIR'
    printf '%s\n' '        return 0'
    printf '%s\n' '    fi'
    printf '%s\n' '    if ! mkdir -p "$root/bundle" 2>/dev/null; then'
    printf '%s\n' '        # Read-only home or a restricted cache: use a private temp dir.'
    printf '%s\n' '        root="$(mktemp -d "${TMPDIR:-/tmp}/nebula-manager-assets.XXXXXX")" || {'
    printf '%s\n' '            echo "nebula-manager: cannot create an asset directory" >&2'
    printf '%s\n' '            return 1'
    printf '%s\n' '        }'
    printf '%s\n' '        mkdir -p "$root/bundle" || {'
    printf '%s\n' '            echo "nebula-manager: cannot create $root/bundle" >&2'
    printf '%s\n' '            return 1'
    printf '%s\n' '        }'
    printf '%s\n' '    fi'
    for asset in "${ASSETS[@]}"; do
        f="$REPO_ROOT/lib/$asset"
        printf '    cat > "$root/%s" <<%s\n' "$asset" "'$DELIM'"
        cat "$f"
        if [[ "$(tail -c 1 "$f" | wc -l)" -eq 0 ]]; then
            printf '\n'
        fi
        printf '%s\n' "$DELIM"
    done
    printf '%s\n' '    for f in "$root/nebula-manager.conf.template" "$root/bundle/install.sh" "$root/bundle/install.ps1" "$root/bundle/README.txt"; do'
    printf '%s\n' '        [[ -s "$f" ]] || { echo "nebula-manager: missing embedded asset $f" >&2; return 1; }'
    printf '%s\n' '    done'
    printf '%s\n' '    : > "$marker"'
    printf '%s\n' '    MANAGER_LIB_DIR="$root"'
    printf '%s\n' '    export MANAGER_LIB_DIR'
    printf '%s\n' '}'
    printf '\n'
    printf '%s\n' '# Single-file mode: no lib/ tree; assets live in the user cache.'
    printf '%s\n' 'NEBULA_MANAGER_SINGLE_FILE=1'
    printf '%s\n' 'export NEBULA_MANAGER_SINGLE_FILE'
    printf '%s\n' 'nebula_manager_single_file_materialize_assets || exit 1'
    for module in "${MODULES[@]}"; do
        f="$REPO_ROOT/lib/$module.sh"
        printf '\n# ===== concatenated from lib/%s.sh =====\n' "$module"
        cat "$f"
        if [[ "$(tail -c 1 "$f" | wc -l)" -eq 0 ]]; then
            printf '\n'
        fi
    done
} > "$replacement"

# Replace everything between the markers (exclusive) with the generated block.
awk -v start="$START_MARK" -v end="$END_MARK" -v repl="$replacement" '
    $0 == start {
        print
        while ((getline line < repl) > 0) print line
        close(repl)
        skipping = 1
        next
    }
    skipping {
        if ($0 == end) { skipping = 0; print }
        next
    }
    { print }
' "$ENTRY" > "$spliced"

bash -n "$spliced" || die "generated script failed bash -n"

mkdir -p "$OUT_DIR"
cp "$spliced" "$OUT"
chmod +x "$OUT"

# Checksum beside the executable. The updater looks for a line whose second
# field is "nebula-manager", so keep the basename portable.
( cd "$OUT_DIR" && sha256sum -- "$(basename "$OUT")" > "$(basename "$OUT").sha256" )

printf 'built %s\n' "$OUT"
printf 'wrote %s\n' "$OUT.sha256"
