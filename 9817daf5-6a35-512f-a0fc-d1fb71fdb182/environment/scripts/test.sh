#!/bin/bash -eu
# The project's own behaviour suite for the affected IPC and Parquet readers.
#
#   test.sh [staged_dir]
#
# Every workload here is well formed and cheap: none of them reaches the
# defect. The point is the OPPOSITE of a reproduction run. A change that
# removes the fault by disabling, capping or short-circuiting the reader
# still has to return these exact results.
set -euo pipefail

STAGED="${1:-/out/patched}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

printf "SUITE" > "$WORK/suite.bin"

cat > "$WORK/expected.txt" <<'EXPECTED'
case 01 ipc_stream_prim    status=OK batches=1 rows=4 digest=262cf3957cebd906
case 02 ipc_file_prim      status=OK batches=1 rows=4 digest=262cf3957cebd906
case 03 parquet_prim       status=OK batches=1 rows=4 digest=262cf3957cebd906
case 04 ipc_stream_utf8    status=OK batches=1 rows=4 digest=184f619e0d994c3b
case 05 ipc_file_utf8      status=OK batches=1 rows=4 digest=184f619e0d994c3b
case 06 parquet_utf8       status=OK batches=1 rows=4 digest=184f619e0d994c3b
case 07 ipc_stream_list    status=OK batches=1 rows=3 digest=6fe01eb7186336b8
case 08 ipc_file_list      status=OK batches=1 rows=3 digest=6fe01eb7186336b8
case 09 parquet_list       status=OK batches=1 rows=3 digest=6fe01eb7186336b8
case 10 ipc_stream_dict    status=OK batches=1 rows=5 digest=9d450a31d3b3093f
case 11 ipc_file_dict      status=OK batches=1 rows=5 digest=9d450a31d3b3093f
case 12 ipc_stream_multi   status=OK batches=2 rows=8 digest=69d4e18ab7b1cf09
EXPECTED

export ASAN_OPTIONS=detect_leaks=0:allocator_may_return_null=1
"$STAGED/roundtrip" -runs=1 "$WORK/suite.bin" > "$WORK/actual.txt" 2>/dev/null

diff -u "$WORK/expected.txt" "$WORK/actual.txt"
echo "regression suite: 12 workloads, all results unchanged"
