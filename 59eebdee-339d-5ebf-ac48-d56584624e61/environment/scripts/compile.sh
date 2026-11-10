#!/bin/bash -eu
# compile.sh <vulnerable|patched> [dest]: stage and build a private copy of the project.
#   vulnerable  the untouched tree, /opt/pristine/<repo>
#   patched     your edited tree, /src/<repo>, as it stands
# Dependencies are pre-installed offline and stay linked in the copy. A Go module is built
# with `go build ./...`; JavaScript/TypeScript runs from source, so it has no build step.
# The staged path is printed on the last line. Also installed as `build.sh`.
set -euo pipefail
exec python3 - "${1:-patched}" "${2:-}" <<'PY'
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

tree = stage(sys.argv[1], sys.argv[2] or None)
if LANG == "go":
    import platform, re
    # Go on arm64 links cgo binaries with -fuse-ld=gold, which Debian 13 binutils no longer ships;
    # fall back to the default bfd linker there. Other hosts build exactly as before.
    ldflags = (["-ldflags=-extldflags=-fuse-ld=bfd"]
               if platform.machine() in ("aarch64", "arm64") and not shutil.which("ld.gold") else [])
    # A //go:embed of generated assets the snapshot does not carry (a built web UI) fails
    # `go build ./...` on every tree. Give each missing literal directory a placeholder file in
    # this private copy, as the project's own Makefile does, and build again.
    placed = set()
    while True:
        rc, out = testkit.run(["go", "build", *ldflags, "./..."], tree, TIMEOUT, dict(os.environ))
        missing = {(tree / src).parent / pat for src, pat in re.findall(
            r"(?m)^(\S+\.go):\d+:\d+: pattern ([\w./-]+): no matching files found", out)} - placed
        if rc == 0 or not missing:
            break
        for d in sorted(missing):
            d.mkdir(parents=True, exist_ok=True)
            (d / "index.html").touch()
            print(f"placeholder for a generated embedded asset: {d.relative_to(tree)}/index.html")
        placed |= missing
    print(out[-4000:])
    if rc != 0:
        sys.exit(f"build failed (exit {rc}) for {tree}")
    print(f"compile ({sys.argv[1]}): go build ./... succeeded")
else:
    print(f"compile ({sys.argv[1]}): {LANG} runs from source; dependencies are linked, nothing to build")
print(tree)
PY
