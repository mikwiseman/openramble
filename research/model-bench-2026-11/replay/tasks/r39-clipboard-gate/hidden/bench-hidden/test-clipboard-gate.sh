#!/bin/bash
# The clipboard check has to run: green and silent on the tree as it is, red on
# a planted plain clearContents(), green again once the line is removed.
set -u
cd "$(dirname "$0")/.."
fail() { echo "FAIL: $1"; exit 1; }

out=$(./scripts/check-network-surface.sh 2>&1) || fail "the gate is red on the unchanged tree: $out"
grep -q "unbound variable" <<<"$out" && fail "the gate still reads an unset variable"

planted=apps/macos/OpenRamble/BenchPlanted.swift
trap 'rm -f "$planted"' EXIT
printf 'import AppKit\n\nfunc benchPlanted() {\n    NSPasteboard.general.clearContents()\n}\n' > "$planted"
if out=$(./scripts/check-network-surface.sh 2>&1); then
  fail "a plain clearContents() passes the gate"
fi
grep -q "BenchPlanted.swift" <<<"$out" || fail "the gate is red, but not for the planted line: $out"

rm -f "$planted"
./scripts/check-network-surface.sh > /dev/null 2>&1 || fail "the gate stays red after the planted line is removed"
echo "PASS: the clipboard check runs"
