#!/usr/bin/env bash
# Deploy ArtCorpOS to the in-game computers.
#
# Standing rule: computer 5 = MAIN flight computer, computer 10 = KEYBOARD.
# This script encodes that split so it can never be got wrong by hand.
#
#   computer 5  (main)   : lib/*.lua, startup, install.lua, mkconfig.lua
#   computer 10 (keyboard): kbd.lua  ONLY
#
# Footgun this script deliberately avoids: computer 10 has its OWN tiny
# `startup` (a 2-line launcher that just runs `kbd`). The repo's `startup`
# is the MAIN OS (flight loop, 20 Hz timer, lib/*). Deploying the repo
# `startup` to computer 10 would replace the keyboard launcher with the
# flight OS and break the keyboard, so the KBD list is kbd.lua alone and
# we never touch computer 10's startup or E.lua.
#
# config/ is NEVER touched: each computer owns its live config (e.g.
# config/ArtAtlas.lua with custom ship name/fuel). Only edit those by hand.
#
# Usage:  ./deploy.sh [-n]        ( -n = dry run, show what would change )
# Env:    ATLAS_COMPUTERCRAFT=<path>  to override the computers directory

set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE="${ATLAS_COMPUTERCRAFT:-$HOME/.var/app/com.modrinth.ModrinthApp/data/ModrinthApp/profiles/Create Aeronautics/saves/Atlas Warmachine World/computercraft/computer}"
MAIN="$BASE/5"
KBD="$BASE/10"

DRY=0
[ "${1:-}" = "-n" ] && DRY=1

# Pick a Lua syntax checker if one is available (optional; we warn and skip
# the check if none is found rather than blocking the deploy).
LUAC=""
for c in luac5.4 luac; do
  if command -v "$c" >/dev/null 2>&1; then LUAC="$c"; break; fi
done
if [ -z "$LUAC" ] && [ -x /tmp/luaenv/usr/bin/luac5.4 ]; then
  LUAC=/tmp/luaenv/usr/bin/luac5.4
fi
[ -z "$LUAC" ] && echo "note: no luac found; skipping Lua syntax pre-check" >&2

STAMP="$(date +%Y%m%d-%H%M%S)"
DEPLOYED=0; VERIFIED=0; SKIPPED=0

syntax_check() { # $1 = source .lua path
  [ -n "$LUAC" ] || return 0
  case "$1" in *.lua) "$LUAC" -p "$1" || { echo "SYNTAX ERROR: $1" >&2; return 1; };; esac
}

# deploy_file <src> <dst> <label>
deploy_file() {
  local src="$1" dst="$2" label="$3"
  if [ ! -f "$src" ]; then echo "  skip (missing src): $label"; SKIPPED=$((SKIPPED+1)); return 0; fi
  syntax_check "$src" || return 1
  if [ -f "$dst" ] && cmp -s "$src" "$dst"; then
    echo "  up-to-date: $label"; SKIPPED=$((SKIPPED+1)); return 0
  fi
  if [ "$DRY" = "1" ]; then
    echo "  WOULD DEPLOY: $label"; DEPLOYED=$((DEPLOYED+1)); return 0
  fi
  mkdir -p "$(dirname "$dst")"
  if [ -f "$dst" ]; then
    local bak="$BASE/.backup_${STAMP}/${label//\//_}"
    mkdir -p "$(dirname "$bak")"
    cp -p "$dst" "$bak"
  fi
  cp -p "$src" "$dst"
  # verify byte-identical
  if cmp -s "$src" "$dst"; then
    echo "  deployed + verified: $label"; DEPLOYED=$((DEPLOYED+1)); VERIFIED=$((VERIFIED+1))
  else
    echo "  ERROR: verify FAILED after copy: $label" >&2; return 1
  fi
}

echo "Deploying ArtCorpOS from $REPO"
echo "  main  (computer 5) : $MAIN"
echo "  kbd   (computer 10): $KBD"
[ "$DRY" = "1" ] && echo "  (DRY RUN — nothing written)"
echo

# --- MAIN: computer 5 ---
echo "computer 5 (main):"
for f in "$REPO"/lib/*.lua; do
  deploy_file "$f" "$MAIN/lib/$(basename "$f")" "lib/$(basename "$f")"
done
for f in startup install.lua mkconfig.lua; do
  deploy_file "$REPO/$f" "$MAIN/$f" "$f"
done
echo

# --- KBD: computer 10 (kbd.lua only — never its startup/E.lua) ---
echo "computer 10 (keyboard):"
deploy_file "$REPO/kbd.lua" "$KBD/kbd.lua" "kbd.lua"
echo "  (computer 10 startup/E.lua intentionally left alone)"
echo

echo "Summary: $DEPLOYED deployed, $VERIFIED verified, $SKIPPED unchanged/missing"
[ "$DEPLOYED" -gt 0 ] && [ "$DRY" = "0" ] && echo "Backups (if any overwritten): $BASE/.backup_${STAMP}/"
echo "Restart the affected in-game computer(s) to load the new code."
