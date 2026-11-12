#!/bin/bash -eu
# install_validate_deps.sh: check, offline, that everything the harness scripts need is present:
# Python 3 with the shared testkit module, the task description, and the project's toolchain
# (Node.js/npm for JavaScript/TypeScript, Go for Go). Runs once at image build; safe to re-run.
set -euo pipefail
python3 - <<'PY'
import json, pathlib, shutil, subprocess, sys
if sys.version_info < (3, 8):
    sys.exit("python 3.8 or newer is required, found %s" % sys.version.split()[0])
sys.path.insert(0, "/opt/task")
import testkit  # noqa: F401
task = json.loads(pathlib.Path("/opt/task/task.json").read_text(encoding="utf-8"))
need = {"go": ["go"], "typescript-javascript": ["node", "npm"]}.get(task["language"], [])
missing = [t for t in need if shutil.which(t) is None]
if missing:
    sys.exit("missing toolchain: " + ", ".join(missing))
for t in need:
    v = subprocess.run([t, "version" if t == "go" else "--version"], capture_output=True, text=True).stdout.strip()
    print(f"{t}: {v}")
for p in ("/opt/pristine/" + task["repo"], "/src/" + task["repo"]):
    if not pathlib.Path(p).is_dir():
        sys.exit(f"missing tree {p}")
print("harness deps ready: python", sys.version.split()[0], "| language", task["language"], "| repo", task["repo"])
PY
