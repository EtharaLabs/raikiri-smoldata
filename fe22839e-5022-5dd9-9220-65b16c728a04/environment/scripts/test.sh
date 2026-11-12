#!/bin/bash -eu
# test.sh [patched|vulnerable]: run the project's own test suite on a private copy of the tree,
# offline, with the same runner the grader uses for its regression checks. Also installed as
# `regression.sh`.
#   patched (default): your edited tree /src/<repo>, compared with the unmodified tree. Only
#     failures your change introduced count. Tests that also fail on the unmodified tree fail
#     because of this sandbox (no network, no IPv6, no external services); they are listed
#     separately and do not fail the run. The unmodified tree's result is computed on first use
#     and cached in ~/.cache/regression/.
#   vulnerable: the unmodified tree only, refreshing that cache.
# Exit status: 0 when no new failure, 1 otherwise (or when the suite timed out).
set -euo pipefail
exec python3 - "${1:-patched}" <<'PY'
import hashlib, json, os, pathlib, shutil, subprocess, sys, tempfile
sys.path.insert(0, "/opt/task")
import testkit  # the same classifier and runners the grader uses
T = json.loads(pathlib.Path("/opt/task/task.json").read_text(encoding="utf-8"))
LANG, REPO, TIMEOUT = T["language"], T["repo"], int(T.get("timeout", 900))
PRISTINE, WORK = pathlib.Path("/opt/pristine") / REPO, pathlib.Path("/src") / REPO
CACHE = pathlib.Path(os.environ.get("HOME", "/tmp")) / ".cache" / "regression"
KEY = hashlib.sha256(pathlib.Path("/opt/task/task.json").read_bytes()).hexdigest()[:16]
BASE = CACHE / f"{REPO}-{KEY}.json"
SHOW = 40  # names listed per group


def stage(variant):
    """A private copy of the tree: vulnerable = /opt/pristine/<repo>, patched = /src/<repo> (your edits)."""
    root = pathlib.Path(tempfile.mkdtemp(prefix=f"{variant}-"))
    tree = root / REPO
    shutil.copytree(PRISTINE if variant == "vulnerable" else WORK, tree, symlinks=True)
    return tree


def suite(variant):
    """(timed_out, failing test names, passed count, output tail) for one run of the suite."""
    tree = stage(variant)
    try:
        anchor = {"go": "go.mod", "typescript-javascript": "package.json"}.get(LANG, ".")
        argv, cwd = testkit.suite_command(LANG, tree, anchor, python=T.get("python", "python"),
                                          offline=True, settings=T.get("maven_settings", ""))
        junit = tree.parent / "junit.xml"
        rc, out = testkit.run(testkit.junit_argv(LANG, argv, junit), cwd, TIMEOUT, dict(os.environ))
        res = testkit.outcomes(out, LANG, tree, junit) or {}
        return rc == 124, set(testkit.failed(res)) | set(testkit.errored(res)), len(testkit.passed(res)), out[-4000:]
    finally:
        shutil.rmtree(tree.parent, ignore_errors=True)


def baseline(refresh=False, extra_run=False):
    """Failing tests of the unmodified tree; extra_run adds another run's failures (flaky tests)."""
    old = set()
    if BASE.is_file() and not refresh:
        old = set(json.loads(BASE.read_text())["failing"])
        if not extra_run:
            return old
    print("running the suite on the unmodified tree (baseline) ...", flush=True)
    timed_out, failing, npass, _ = suite("vulnerable")
    if timed_out:
        sys.exit("the suite timed out on the unmodified tree; no baseline to compare with")
    failing |= old
    CACHE.mkdir(parents=True, exist_ok=True)
    BASE.write_text(json.dumps({"failing": sorted(failing)}, indent=0))
    return failing


def listing(title, names):
    names = sorted(names)
    print(f"{title}: {len(names)}")
    for n in names[:SHOW]:
        print(f"  {n}")
    if len(names) > SHOW:
        print(f"  ... and {len(names) - SHOW} more")


variant = sys.argv[1]
if variant not in ("vulnerable", "patched"):
    sys.exit("variant must be 'vulnerable' or 'patched'")
if variant == "vulnerable":
    failing = baseline(refresh=True)
    listing("failing on the unmodified tree (this sandbox's environment)", failing)
    sys.exit(0)

base = baseline()
print("running the suite on your edited tree ...", flush=True)
timed_out, failing, npass, tail = suite("patched")
print(tail)
if timed_out:
    print(f"the suite timed out after {TIMEOUT}s on your edited tree")
    sys.exit(1)
new = failing - base
if new:  # a test that passed in the baseline run may be flaky: one more baseline run settles it
    base = baseline(extra_run=True)
    new = failing - base
print(f"\npassed {npass}, failing {len(failing)}")
listing("also failing on the unmodified tree (environment, not your change)", failing & base)
listing("NEW failures introduced by your change", new)
print("regression check:", "FAIL" if new else "PASS (no new failures)")
sys.exit(1 if new else 0)
PY
