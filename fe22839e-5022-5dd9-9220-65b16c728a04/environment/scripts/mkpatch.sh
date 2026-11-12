#!/bin/bash -eu
# mkpatch.sh [tree]: print the unified diff of your edited tree (default /src/<repo>) against the
# untouched copy /opt/pristine/<repo>, with a/ and b/ prefixes and build output skipped.
# make-deliverables splits the same changes into the D1 reproducer and the D2 repair.
# Also installed as `mkpatch.sh` on PATH.
set -euo pipefail
exec python3 - "${1:-}" <<'PY'
import json, os, pathlib, shutil, subprocess, sys, tempfile
sys.path.insert(0, "/opt/task")
import testkit  # the same classifier and runners the grader uses
T = json.loads(pathlib.Path("/opt/task/task.json").read_text(encoding="utf-8"))
LANG, REPO, TIMEOUT = T["language"], T["repo"], int(T.get("timeout", 900))
PRISTINE, WORK = pathlib.Path("/opt/pristine") / REPO, pathlib.Path("/src") / REPO


def stage(variant, dest=None):
    """A private copy of the tree: vulnerable = /opt/pristine/<repo>, patched = /src/<repo> (your edits)."""
    if variant not in ("vulnerable", "patched"):
        sys.exit("variant must be 'vulnerable' or 'patched'")
    root = pathlib.Path(dest) if dest else pathlib.Path(tempfile.mkdtemp(prefix=f"{variant}-"))
    tree = root / REPO
    if tree.exists():
        shutil.rmtree(tree)
    shutil.copytree(PRISTINE if variant == "vulnerable" else WORK, tree, symlinks=True)
    return tree

import difflib
tree = pathlib.Path(sys.argv[1]) if sys.argv[1] else WORK
skip = set(testkit.BUILD_OUTPUT_DIRS) | {".git"}


def files(root):
    out = {}
    for p in root.rglob("*"):
        rel = p.relative_to(root)
        if any(x in skip or x.endswith(".egg-info") for x in rel.parts):
            continue
        if p.is_file() and not p.is_symlink():
            out[rel.as_posix()] = p
    return out


old, new = files(PRISTINE), files(tree)
for rel in sorted(set(old) | set(new)):
    a, b = old.get(rel), new.get(rel)
    da, db = (a.read_bytes() if a else b""), (b.read_bytes() if b else b"")
    if da == db:
        continue
    if b"\\0" in da[:8192] or b"\\0" in db[:8192]:
        print(f"Binary files a/{rel} and b/{rel} differ")
        continue
    la = da.decode("utf-8", "replace").splitlines(keepends=True)
    lb = db.decode("utf-8", "replace").splitlines(keepends=True)
    print(f"diff --git a/{rel} b/{rel}")
    sys.stdout.writelines(difflib.unified_diff(la, lb, f"a/{rel}" if a else "/dev/null", f"b/{rel}" if b else "/dev/null"))
PY
