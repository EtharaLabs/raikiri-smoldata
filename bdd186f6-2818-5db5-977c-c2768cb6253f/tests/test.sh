#!/bin/bash -eu
# Verifier entrypoint (reference grading contract + reference grader sandbox),
# observation step adapted to the staging D1/D2 model (validate.py collect).
set -u
LOGDIR=/logs/verifier
mkdir -p "$LOGDIR"
# Every exit leaves a reward: a step that aborts before the reward is written scores 0.
rm -f "$LOGDIR/reward.json"
fail_closed() {
    [ -s "$LOGDIR/reward.json" ] && return 0
    echo "the verifier exited before writing a reward; scored 0" > "$LOGDIR/reward_fail_closed.txt"
    printf '{\n  "pytest": 0.0,\n  "reward": 0.0\n}\n' > "$LOGDIR/reward.json"
}
trap fail_closed EXIT
unset LD_PRELOAD LD_LIBRARY_PATH LD_AUDIT DYLD_INSERT_LIBRARIES PYTHONPATH PYTHONHOME PYTHONSTARTUP
# Route the codex CLI to the host codex bridge. Rewardkit gives codex a fresh
# CODEX_HOME per judge call and codex ignores OPENAI_BASE_URL, so the provider goes
# in the system-wide managed config. The bridge swaps the stub key for the ChatGPT
# subscription token; the bridge serves the Responses API over HTTP only.
write_codex_bridge_config() {
    mkdir -p /etc/codex
    cat > /etc/codex/managed_config.toml <<EOF
model_provider = "codex-bridge"

[model_providers.codex-bridge]
name = "codex bridge"
base_url = "${CODEX_BRIDGE_URL%/}/v1"
env_key = "CODEX_API_KEY"
wire_api = "responses"
supports_websockets = false
EOF
}
cd "$(dirname "$0")"
RK=/tests/reward

# ---------------------------------------------------------------- 1. trajectory
TRAJ=/tmp/agent_trajectory.json
python3 - <<'PYEOF'
import json, pathlib
AGENT_DIR = pathlib.Path("/logs/agent")
tf = pathlib.Path("/tmp/agent_trajectory.json")
steps, final = [], ""
log = None
if AGENT_DIR.is_dir():
    for c in [AGENT_DIR/"trajectory.json"] + sorted(AGENT_DIR.glob("*.txt")):
        if c.exists() and c.stat().st_size:
            log = c; break
if log and log.suffix == ".json":
    try:
        doc = json.loads(log.read_text())
        for st in doc.get("steps") or []:
            m = st.get("message")
            if isinstance(m, str) and m.strip(): final = m
            for tc in st.get("tool_calls") or []:
                # A closing message may be delivered as the `finish` tool's
                # argument rather than as a plain assistant message.
                if tc.get("function_name") == "finish":
                    fin = (tc.get("arguments") or {}).get("message")
                    if isinstance(fin, str) and fin.strip(): final = fin
                steps.append({"tool": tc.get("function_name",""), "arguments": tc.get("arguments") or {}})
    except Exception:
        pass
tf.write_text(json.dumps({"steps": steps, "final_message": final}, indent=2))
print(f"[1/5 trajectory] {len(steps)} steps")
PYEOF
[ -f "$TRAJ" ] && cp "$TRAJ" "$LOGDIR/agent_trajectory.json" || true

# ------------------------------------------------- grader sandbox (observations + pytest)
# Runs agent-supplied D1/D2 patches, so it runs as a dedicated unprivileged uid with
# no caps, no_new_privs, a scrubbed env, a non-dumpable interpreter, reaped after use,
# with /logs closed and a submission tamper check (the reference model, run as root).
GRADER_UID=64001
GRADER_DIR=/tmp/kakashi-grader
RESULTS=/root/kakashi-grader-results
rm -rf "$GRADER_DIR" "$RESULTS" && mkdir -p "$GRADER_DIR/home" "$GRADER_DIR/logs" "$RESULTS"
chown -R "$GRADER_UID:$GRADER_UID" "$GRADER_DIR"
# The staging grader resets a git work tree under /grade; give the grader uid ownership
# (reference chowns its agent-controlled build dirs the same way before dropping).
[ -d /grade ] && chown -R "$GRADER_UID:$GRADER_UID" /grade || true
chmod 700 "$GRADER_DIR" "$RESULTS" /root
: > "$RESULTS/junit.xml" && chmod 666 "$RESULTS/junit.xml"
LOGS_MODE="$(stat -c %a /logs)"; chmod 700 /logs
OUT_SUM="$(cd /output && find . -type f -exec sha256sum {} + | sort)"
chown -R root:root /output 2>/dev/null || true
chmod -R u=rwX,go=rX /output 2>/dev/null || true
# Offline toolchain settings for the grader. `env -i` below scrubs the image ENV, so
# pass through only the build settings the verifier image itself sets (never secrets),
# give the grader uid a GOCACHE it owns, and let it traverse (o+x: not list, not
# write) the directories above the image's read-only module cache.
GRADER_TOOL_ENV=()
for v in GOFLAGS GOMODCACHE GOPATH GOPROXY GOTOOLCHAIN GOSUMDB GONOSUMDB GOPRIVATE CGO_ENABLED; do
    [ -n "${!v+x}" ] && GRADER_TOOL_ENV+=("$v=${!v}")
done
if [ -n "${GOMODCACHE:-}" ]; then
    GRADER_TOOL_ENV+=("GOCACHE=$GRADER_DIR/gocache")
    d="$GOMODCACHE"
    while [ "$d" != / ] && [ -n "$d" ]; do
        if [ -d "$d" ]; then chmod o+x "$d" 2>/dev/null || true; fi
        d="$(dirname "$d")"
    done
fi
grader() {
    env -i PATH="$PATH" HOME="$GRADER_DIR/home" TMPDIR="$GRADER_DIR" LC_ALL=C \
        PYTHONDONTWRITEBYTECODE=1 PYTHONPATH=/tests TESTS_DIR=/tests \
        GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null \
        STAGES_FD="${STAGES_FD:-}" \
        VERIFIER_LOGS="$GRADER_DIR/logs" VERIFIER_LOG_DIR="$GRADER_DIR/logs" \
        "${GRADER_TOOL_ENV[@]+"${GRADER_TOOL_ENV[@]}"}" \
        setpriv --reuid="$GRADER_UID" --regid="$GRADER_UID" --clear-groups \
            --no-new-privs -- "$@"
}
# Same drop-privilege wrapper, but points the oracle at the root-owned trusted
# observations ($TRUSTED, created below) which the grader uid can read but not
# rewrite.
grader_trusted() {
    env -i PATH="$PATH" HOME="$GRADER_DIR/home" TMPDIR="$GRADER_DIR" LC_ALL=C \
        PYTHONDONTWRITEBYTECODE=1 PYTHONPATH=/tests TESTS_DIR=/tests \
        GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null \
        VERIFIER_LOGS="$TRUSTED" VERIFIER_LOG_DIR="$TRUSTED" \
        "${GRADER_TOOL_ENV[@]+"${GRADER_TOOL_ENV[@]}"}" \
        setpriv --reuid="$GRADER_UID" --regid="$GRADER_UID" --clear-groups \
            --no-new-privs -- "$@"
}
# PIDs whose real uid is $1, read from /proc/*/status (the image has no procps; the
# grader runs non-dumpable, so /proc/<pid> itself is root-owned).
uid_pids() {
    awk -v u="$1" '/^Uid:/ { if ($2 == u) { split(FILENAME, f, "/"); print f[3] }; nextfile }' \
        /proc/[0-9]*/status 2>/dev/null
}
reap_uid() {
    local pids
    for _ in 1 2 3 4 5; do
        pids="$(uid_pids "$1")"; [ -z "$pids" ] && return 0
        kill -KILL $pids 2>/dev/null || true; sleep 1
    done
    [ -z "$(uid_pids "$1")" ]
}
grader_reap() {
    if ! reap_uid "$GRADER_UID"; then
        echo "ERROR: grader processes survived; refusing to trust their results" >&2
        echo "grader processes survived the reap" > "$LOGDIR/reward_fail_closed.txt"
        printf '{\n  "pytest": 0.0,\n  "reward": 0.0\n}\n' > "$LOGDIR/reward.json"; exit 0
    fi
}
GRADER_PY='import ctypes, runpy, sys
ctypes.CDLL(None).prctl(4, 0, 0, 0, 0)  # PR_SET_DUMPABLE = 0
sys.argv = sys.argv[1:]
runpy.run_module(sys.argv[0], run_name="__main__", alter_sys=True)'

# 2. observations: validate.py collect -> stages.json, written through a fd root
# opened on a root-only file so the grader uid (which runs the agent's D1/D2
# code) cannot reopen or race-overwrite the oracle's inputs.
TRUSTED=/tmp/kakashi-trusted
rm -rf "$TRUSTED" && mkdir -p "$TRUSTED" && chmod 755 "$TRUSTED"   # root-owned; grader reads, cannot write
grader git config --global --add safe.directory '*' 2>/dev/null || true
exec 4>"$RESULTS/stages.json"
STAGES_FD=4 grader python3 -c "import ctypes, runpy, sys
ctypes.CDLL(None).prctl(4, 0, 0, 0, 0)
sys.argv = ['validate.py', 'collect']
runpy.run_path('/tests/validate.py', run_name='__main__')" > "$RESULTS/grade-stdout.txt" 2>&1 || true
exec 4>&-
# Reap every grader process BEFORE trusting stages.json, so no backgrounded
# agent process can rewrite the observations between collect and the oracle.
grader_reap
cp "$RESULTS/stages.json" "$TRUSTED/stages.json" 2>/dev/null || true
chmod 644 "$TRUSTED/stages.json" 2>/dev/null || true
cp "$TRUSTED/stages.json" "$LOGDIR/stages.json" 2>/dev/null || true

# 3. pytest the weighted oracle against the ROOT-OWNED trusted stages.json -> junit via fd 3
if grader_trusted python3 -c "$GRADER_PY" pytest /tests/test_output.py \
        --junitxml=/proc/self/fd/3 -v -p no:cacheprovider \
        -W ignore::pytest.PytestReturnNotNoneWarning \
        3>"$RESULTS/junit.xml" > "$RESULTS/pytest-stdout.txt" 2>&1; then
    PYTEST_OK=1
else
    PYTEST_OK=0
fi
grader_reap
chmod "$LOGS_MODE" /logs
for root_dir in / /logs /output; do
    find "$root_dir" -xdev -mindepth 1 \( -path "$GRADER_DIR" -o -path /proc \) -prune \
        -o -user "$GRADER_UID" -prune -exec rm -rf {} + 2>/dev/null || true
done
if [ "$(cd /output && find . -type f -exec sha256sum {} + | sort)" != "$OUT_SUM" ]; then
    echo "the submission changed while it was being graded" > "$LOGDIR/tampering_detected.txt"
    printf '{\n  "pytest": 0.0,\n  "reward": 0.0\n}\n' > "$LOGDIR/reward.json"; exit 0
fi
for f in grade-stdout.txt junit.xml pytest-stdout.txt; do cp "$RESULTS/$f" "$LOGDIR/$f" 2>/dev/null || true; done
rm -rf "$GRADER_DIR" "$RESULTS"
export TESTS_DIR=/tests VERIFIER_LOGS="$LOGDIR" VERIFIER_LOG_DIR="$LOGDIR"
tail -n 10 "$LOGDIR/pytest-stdout.txt" 2>/dev/null || true

# JUnit -> CTRF
python3 - "$LOGDIR/junit.xml" "$LOGDIR/ctrf.json" <<'PYEOF' || echo "[ctrf] junit.xml unreadable; the reward step scores the missing results" >&2
import json, pathlib, sys, xml.etree.ElementTree as ET
junit, out = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])
root = ET.parse(junit).getroot()
ln = lambda t: t.rsplit("}",1)[-1]
def child(c,n): return next((x for x in c if ln(x.tag)==n), None)
tests=[]
for case in root.iter():
    if ln(case.tag)!="testcase": continue
    name=(case.get("name") or "").strip()
    if not name: continue
    f,e,s=child(case,"failure"),child(case,"error"),child(case,"skipped")
    status="failed" if (f is not None or e is not None) else ("skipped" if s is not None else "passed")
    tests.append({"name":name,"status":status,"duration":0})
rep={"results":{"tool":{"name":"pytest"},"summary":{"tests":len(tests),
     "passed":sum(t["status"]=="passed" for t in tests),
     "failed":sum(t["status"]=="failed" for t in tests),
     "skipped":sum(t["status"]=="skipped" for t in tests),"pending":0,"other":0},"tests":tests}}
out.write_text(json.dumps(rep,indent=2)+"\n")
print(f"[ctrf] {len(tests)} tests -> {out}")
PYEOF

# 4. reward: pytest ledger (+ rubric judge when configured), else pytest alone
# The judge: GPT 6.1 Sol through the codex CLI and the host codex bridge.
JUDGE_TRANSPORT="${JUDGE_TRANSPORT:-codex}"
JUDGE_MODEL="${JUDGE_MODEL:-openai/gpt-6.1-sol}"
SKIP_REASON=""
if [ "${JUDGE_SKIP:-0}" = 1 ]; then SKIP_REASON="JUDGE_SKIP=1"
elif [ ! -s "$RK/rubric/judge.toml" ]; then SKIP_REASON="no rubric"
elif [ "$JUDGE_TRANSPORT" != codex ]; then SKIP_REASON="unsupported judge transport $JUDGE_TRANSPORT (codex only)"
elif [ -z "${CODEX_BRIDGE_URL:-}" ] || [ -z "${KAKASHI_CODEX_BRIDGE_SECRET:-}" ]; then
  SKIP_REASON="no codex bridge (CODEX_BRIDGE_URL / KAKASHI_CODEX_BRIDGE_SECRET are empty)"
# An unreachable bridge makes codex retry every criterion until its timeout.
elif ! curl -fsS -m 10 -o /dev/null "${CODEX_BRIDGE_URL%/}/healthz"; then
  SKIP_REASON="codex bridge unreachable at ${CODEX_BRIDGE_URL%/}/healthz"
fi
if [ -z "$SKIP_REASON" ] && ! python3 -c 'import json,sys; sys.exit(0 if json.load(open(sys.argv[1])).get("steps") else 1)' "$TRAJ" 2>/dev/null; then
  SKIP_REASON="no agent trajectory available to the judge"
fi
JW="$LOGDIR/judge_ws"; rm -rf "$JW"; mkdir -p "$JW/workspace"
[ -f "$RK/rubric/instruction.md" ] && cp "$RK/rubric/instruction.md" "$JW/instruction.md"
# the judge reads the full run (messages, tool calls, results); the reduced list is the fallback
if [ -s /logs/agent/trajectory.json ]; then
    cp /logs/agent/trajectory.json "$JW/trajectory.json"
elif [ -s "$TRAJ" ]; then
    cp "$TRAJ" "$JW/trajectory.json"
fi
cp -a /output/. "$JW/workspace/" 2>/dev/null || true
RK_OUT="$LOGDIR/rewardkit-stdout.txt"; : > "$RK_OUT"

# The pytest channel is scored here, as root, from the ctrf.json written above.
# A ledger that exits non-zero may have scored only part of the tests, so it scores 0.
if ! /opt/rewardkit/.venv/bin/rewardkit "$RK/pytest" --workspace /output --output "$LOGDIR/reward.json" >> "$RK_OUT" 2>&1; then
  echo "the pytest ledger exited non-zero; pytest scored 0" > "$LOGDIR/ledger_failed.txt"
  rm -f "$LOGDIR/reward.json"
fi
PYTEST_SCORE="$(python3 - "$LOGDIR/reward.json" <<'PYEOF'
import json,math,sys
try: d=json.load(open(sys.argv[1]))
except Exception: d={}
r=d.get("reward", d.get("score"))
print(r if isinstance(r,(int,float)) and math.isfinite(r) else 0.0)
PYEOF
)"
rm -f "$LOGDIR/reward.json" "$LOGDIR/reward-details.json"

# The judge runs codex with full access over agent-written text, so it runs as its own
# unprivileged uid that can write only its private run directory and the judge workspace.
# Its result supplies the rubric value alone; the pytest value above cannot be changed by it.
JUDGE_UID=64002
JRUN=/tmp/kakashi-judge
JUDGE_RAN=0
RUBRIC_SCORE=""
if [ -z "$SKIP_REASON" ]; then
  write_codex_bridge_config
  rm -rf "$JRUN" && mkdir -p "$JRUN/rk" "$JRUN/home" "$JRUN/tmp" "$JRUN/out" "$JRUN/logs"
  cp -a "$RK/rubric" "$JRUN/rk/rubric"
  chown -R "$JUDGE_UID:$JUDGE_UID" "$JRUN" "$JW"
  chmod 700 "$JRUN"
  # Rewardkit hands OPENAI_API_KEY to codex as CODEX_API_KEY; here it is the bridge's stub.
  if env -i PATH="$PATH" HOME="$JRUN/home" TMPDIR="$JRUN/tmp" LC_ALL=C.UTF-8 \
        OPENAI_API_KEY="$KAKASHI_CODEX_BRIDGE_SECRET" REWARDKIT_JUDGE="$JUDGE_TRANSPORT" \
        REWARDKIT_MODEL="$JUDGE_MODEL" REWARDKIT_LOG_DIR="$JRUN/logs" \
        LITELLM_LOCAL_MODEL_COST_MAP=True \
        setpriv --reuid="$JUDGE_UID" --regid="$JUDGE_UID" --clear-groups --no-new-privs -- \
        /opt/rewardkit/.venv/bin/rewardkit --yolo --max-concurrent-agent 1 "$JRUN/rk" \
        --workspace "$JW" --output "$JRUN/out/reward.json" >> "$RK_OUT" 2>&1; then
    RUBRIC_SCORE="$(python3 -c 'import json,math,sys
d=json.load(open(sys.argv[1])); r=d.get("rubric")
print(r if isinstance(r,(int,float)) and math.isfinite(r) else "")' "$JRUN/out/reward.json" 2>/dev/null || true)"
  fi
  reap_uid "$JUDGE_UID" || true
  if [ -n "$RUBRIC_SCORE" ]; then
    JUDGE_RAN=1
    cp "$JRUN/out/reward-details.json" "$LOGDIR/reward-details.json" 2>/dev/null || true
    for f in "$JRUN"/logs/trajectory.*; do [ -f "$f" ] && cp "$f" "$LOGDIR/"; done
  else
    SKIP_REASON="the judge failed: $(grep -E 'rror' "$RK_OUT" | tail -n 1 | cut -c1-400)"
  fi
  rm -rf "$JRUN"
  chown -R root:root "$JW" 2>/dev/null || true
fi
[ "$JUDGE_RAN" = 0 ] && echo "[reward] rubric channel UNSCORED: $SKIP_REASON" | tee -a "$RK_OUT" > "$LOGDIR/rubric_judge_failed.txt"
# record step: negative-rubric floor and 0.5/0.5 combine; with no rubric, reward = pytest
python3 - "$LOGDIR/reward.json" "$PYTEST_SCORE" "$RUBRIC_SCORE" <<'PYEOF'
import json,sys,pathlib
p=pathlib.Path(sys.argv[1])
pytest=float(sys.argv[2])
reward={"pytest":pytest}
if sys.argv[3]:
    rubric=float(sys.argv[3])
    if rubric<0:
        reward["rubric_unclamped"]=rubric
        rubric=0.0
    reward["rubric"]=rubric
    reward["reward"]=round(0.5*pytest+0.5*rubric,4)
else:
    reward["reward"]=pytest
p.write_text(json.dumps(reward,indent=2))
PYEOF
# emit judge.json (judge provenance for delivery tooling) derived from reward-details
python3 - "$LOGDIR/reward-details.json" "$LOGDIR/judge.json" <<'PYEOF'
import json,sys,pathlib
try: d=json.loads(pathlib.Path(sys.argv[1]).read_text())
except Exception: sys.exit(0)
rub=(d or {}).get("rubric") or {}
j=rub.get("judge") or {}; crits=rub.get("criteria") or []
if j or crits:
    pathlib.Path(sys.argv[2]).write_text(json.dumps({
        "ran": True, "transport": j.get("agent"), "model": j.get("model"),
        "reason": None, "criteria": len(crits), "configured": j,
        "usage": rub.get("usage") or {},
    }, indent=2)+"\n")
PYEOF
echo "[reward] $(cat "$LOGDIR/reward.json")"
