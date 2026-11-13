#!/usr/bin/env bash
# GENERATED SECTION. DO NOT HAND-EDIT.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
mkdir -p /output
cp "$HERE/fix.patch" "/output/200ea06b-394e-52f4-9117-ab76aed47caa_D2_repair.patch"
cp "$HERE/poc.bin" "/output/200ea06b-394e-52f4-9117-ab76aed47caa_D1_reproducer.patch"
