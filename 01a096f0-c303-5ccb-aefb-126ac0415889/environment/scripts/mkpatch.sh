#!/bin/bash -eu
# Produce the unified diff of the working tree against the pinned snapshot.
#
# This exists so the image does not have to ship a Git object database. History
# absence is a screening requirement: a repository inside the graded environment
# is recoverable history, and the only reason one was ever staged here was to
# give the agent a way to produce a diff. The snapshot is already in the image,
# pinned by digest, so the diff is taken against a fresh extraction of it.
#
# This bundle's src.tgz extracts flat into the tree root (no single top-level
# directory), so the snapshot and the working tree are compared directly.
#
# Output is git-apply compatible at -p1, with a/ and b/ prefixes and no
# timestamps. The header rewrite uses awk rather than sed on purpose: BSD sed
# does not honour \t inside a bracket expression, so a path containing the
# letter t would be truncated.
set -euo pipefail

SRC_TGZ=${SRC_TGZ:-/opt/harness/src.tgz}
TREE=${1:-/src}

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
tar xzf "$SRC_TGZ" -C "$tmp"

diff -ru --exclude=.git --exclude=.build "$tmp" "$TREE" | awk -v A="$tmp/" -v B="$TREE/" '
  /^Only in /{ next }
  /^--- /   { sub(/\t.*$/, ""); sub("^--- " A, "--- a/"); print; next }
  /^\+\+\+ /{ sub(/\t.*$/, ""); sub("^\\+\\+\\+ " B, "+++ b/"); print; next }
            { print }
' || true
