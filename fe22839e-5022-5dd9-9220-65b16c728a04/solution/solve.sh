#!/bin/bash
# Reference solution. Harbor's oracle uploads this directory to /solution and runs
# this script. A repair-mode bundle is graded on the two /output deliverables, so the
# reference publishes both: D2 is solution/fix.patch (the vulnerable-source repair);
# D1 is the withheld regression test, carried base64-encoded because the bundle ships
# no loose solution files.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
UUID="fe22839e-5022-5dd9-9220-65b16c728a04"
mkdir -p /output
cp "$HERE/fix.patch" "/output/${UUID}_D2_repair.patch"
cp "$HERE/poc.bin" "/output/${UUID}_D1_reproducer.patch"
echo "published /output/${UUID}_D1_reproducer.patch and /output/${UUID}_D2_repair.patch"
