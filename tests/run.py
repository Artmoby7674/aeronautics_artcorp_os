#!/usr/bin/env python3
"""Local test driver (no system Lua needed): syntax-sweeps every Lua file
through a real Lua runtime via lupa, then runs tests/run_all.lua.

    python3 tests/run.py          # from the repo root
"""
import os
import sys

try:
    from lupa import LuaRuntime
except ImportError:
    sys.exit("lupa not installed: pip install --user --break-system-packages lupa")

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
os.chdir(ROOT)

lua = LuaRuntime(unpack_returned_tuples=True)
load_ok = lua.eval(
    "function(src, name) local f, e = load(src, name); "
    "if f then return true, '' else return false, tostring(e) end end"
)

# --- 1. syntax sweep -------------------------------------------------
targets = []
for dirpath, dirs, files in os.walk("."):
    dirs[:] = [d for d in dirs if d != ".git"]
    for f in files:
        if f.endswith(".lua"):
            targets.append(os.path.join(dirpath, f))
for extra in ("startup", "kbd.lua", "install.lua", "ship.lua", "mkconfig.lua"):
    if extra not in targets and os.path.exists(extra):
        targets.append(extra)

bad = 0
for path in sorted(set(targets)):
    with open(path, "r", encoding="utf-8", errors="replace") as fh:
        src = fh.read()
    ok, err = load_ok(src, "@" + path)
    if not ok:
        bad += 1
        print(f"SYNTAX FAIL {path}: {err}")
print(f"syntax sweep: {len(set(targets))} files, {bad} failed")
if bad:
    sys.exit(1)

# --- 2. unit + regression tests -------------------------------------
lua.execute('package.path = "./?.lua;" .. package.path')
try:
    lua.execute('dofile("tests/run_all.lua")')
except Exception as exc:  # Lua error propagates as LuaError
    print(f"TESTS FAILED: {exc}")
    sys.exit(1)
print("run.py: ALL OK")
