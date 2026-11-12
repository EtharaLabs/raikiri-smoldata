#!/usr/bin/env bash
# GENERATED SECTION. DO NOT HAND-EDIT.
# FORGE-CANARY-BEGIN
# FORGE-CANARY-SLOT-0: 8c794e40c1a131a6a0dc24fdff18c2ba43e92dc933eed04608b34a04f8d0d745
# FORGE-CANARY-SLOT-1: 5ced333b397a9c9b258f5fd7659386b9aa9967b5ce338ee15646d59335e8aab8
# FORGE-CANARY-END
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
mkdir -p /output
cp "$HERE/fix.patch" "/output/200ea06b-394e-52f4-9117-ab76aed47caa_D2_repair.patch"
cp "$HERE/poc.bin" "/output/200ea06b-394e-52f4-9117-ab76aed47caa_D1_reproducer.patch"
