#!/bin/bash -eu
# run_poc.sh <vulnerable|patched> [reproducer.patch]: run a D1 reproducer against a staged tree.
#   vulnerable  the untouched tree (/opt/pristine/<repo>): a good reproducer fails here
#   patched     your edited tree (/src/<repo>), with its test files reset to the untouched
#               versions first: a good reproducer passes here once the repair works
# The test-file sections of the patch are applied to a private copy of the tree and the test
# files they add or change are run, the way the grader's reproducer checks run them.
# The default reproducer is /output/<task-uuid>_D1_reproducer.patch (make-deliverables writes it).
# Last line: "verdict: fail" (an assertion fails on this tree) or "verdict: pass".
# Also installed as `run_poc.sh` on PATH.
set -euo pipefail
exec python3 - "${1:-vulnerable}" "${2:-}" <<'PY'
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

variant, patch = sys.argv[1], sys.argv[2]
if not patch:
    found = sorted(pathlib.Path("/output").glob("*_D1_reproducer.patch"))
    if not found:
        sys.exit("no reproducer given and none at /output/*_D1_reproducer.patch (run make-deliverables first)")
    patch = str(found[0])
sections = testkit.diff_sections(pathlib.Path(patch).read_text(encoding="utf-8", errors="replace"))
tests = [s for s in sections if not s["unsafe"] and not s["binary"]
         and (testkit.is_test_path(s["path"], LANG) or testkit.is_test_config(s["path"], LANG))]
for s in sections:
    if s not in tests:
        print(f"ignored, not a test file: {s['path']}")
code = [s["path"] for s in tests if s["new"] not in (None, "/dev/null") and testkit.is_test_code(s["path"], LANG)]
if not code:
    sys.exit("the reproducer adds or changes no runnable test file")
tree = stage(variant)
for s in tests:  # the reproducer's test files start from the untouched versions on either tree
    rel = s["path"]
    if (PRISTINE / rel).is_file():
        (tree / rel).parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(PRISTINE / rel, tree / rel)
    elif (tree / rel).is_file():
        (tree / rel).unlink()
if not testkit.apply_patch(tree, testkit.join_sections(tests)):
    sys.exit(f"the reproducer does not apply to the {variant} tree")
argv, cwd = testkit.scoped_command(LANG, tree, code, python=T.get("python", "python"),
                                   offline=True, settings=T.get("maven_settings", ""))
junit = tree.parent / "junit.xml"
env = dict(os.environ)
if LANG == "python":
    env["PYTHONPATH"] = os.pathsep.join(str(p) for p in (tree / "src", tree) if p.is_dir())
rc, out = testkit.run(testkit.junit_argv(LANG, argv, junit), cwd, TIMEOUT, env)
res = testkit.owned(testkit.outcomes(out, LANG, tree, junit), code, tree, LANG)
print(out[-6000:])
failing = [t for t, (st, msg) in (res or {}).items() if st == "failed" and not testkit.missing_symbol(msg, LANG)]
print(f"exit {rc}; assertion failures on the {variant} tree: {len(failing)}")
for t in failing[:20]:
    print(f"  {t}")
if testkit.errored(res) or (rc not in (0, 124) and not failing):
    print("some tests did not run (collection, compile or import error); the grader does not count those")
print("verdict: fail" if failing else "verdict: pass")
PY
