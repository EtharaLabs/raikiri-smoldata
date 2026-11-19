#!/bin/bash -eu
#
# Verifier entrypoint, run by harbor in the separate verifier container after the
# agent environment is gone. /output holds the agent's submissions (poc.bin, fix.patch);
# /tests is this directory, baked into the verifier image; /logs/verifier is harbor's
# per-trial directory (mounted).
#
#   1. trajectory  rebuild {steps, final_message} from the agent log
#   2. pytest      the author's checks under pytest (junit.xml -> ctrf.json)
#   3. reward      Rewardkit over /tests/reward: pytest/ledger.py as root, then
#                  rubric/judge.toml as the judge uid; combined with reward/reward.toml
#                  weights -> reward.json {pytest, rubric, reward} + reward-details.json
#   4. record      judge.json (what judged, or why nothing did) and reward_producer.json
#
# [verifier.env]: JUDGE_MODEL (default openai/gpt-6.1-sol), JUDGE_TRANSPORT (codex),
# CODEX_BRIDGE_URL and KAKASHI_CODEX_BRIDGE_SECRET (the host codex bridge and its stub
# key); JUDGE_SKIP=1 scores the pytest channel alone.
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
unset TARGET_SRC TARGET_OUT TARGET_BIN TARGET_DRIVER SRC_TGZ VALIDATE_PY ORACLE_DATA_DIR

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
traj_file = pathlib.Path("/tmp/agent_trajectory.json")

candidates = [AGENT_DIR / "trajectory.json", AGENT_DIR / "oracle.txt"]
candidates += sorted((p for p in AGENT_DIR.glob("*.txt") if p not in candidates),
                     key=lambda f: f.stat().st_size, reverse=True) \
              if AGENT_DIR.is_dir() else []
log = next((p for p in candidates if p.exists() and p.stat().st_size), None)

steps, final_message, pending = [], "", {}

def _text_of(raw):
    if isinstance(raw, list) and raw:
        return raw[0].get("text", "") if isinstance(raw[0], dict) else str(raw[0])
    return raw

def _parse_json(raw):
    try:
        return json.loads(raw) if isinstance(raw, str) else raw
    except (json.JSONDecodeError, TypeError):
        return {"text": str(raw)}

def _atif(doc):
    out, by_id, final = [], {}, ""
    for st in doc.get("steps") or []:
        if st.get("source") != "agent":
            continue
        msg = st.get("message")
        if isinstance(msg, list):
            msg = " ".join(p.get("text") or "" for p in msg
                           if isinstance(p, dict) and p.get("type") == "text")
        if isinstance(msg, str) and msg.strip():
            final = msg
        for tc in st.get("tool_calls") or []:
            cid = tc.get("tool_call_id") or ""
            if cid and cid in by_id:
                continue
            entry = {"tool": tc.get("function_name", ""),
                     "arguments": tc.get("arguments") or {}, "response": None}
            out.append(entry)
            if cid:
                by_id[cid] = entry
            # OpenHands ends a run with a `finish` tool call whose `message` argument IS the
            # agent's final report; an agent that writes no closing text puts it only there.
            if entry["tool"] == "finish":
                fargs = entry["arguments"]
                fargs = _parse_json(fargs) if isinstance(fargs, str) else fargs
                fmsg = fargs.get("message") if isinstance(fargs, dict) else None
                if isinstance(fmsg, str) and fmsg.strip():
                    final = fmsg
        results = (st.get("observation") or {}).get("results") or []
        for r in results:
            target = by_id.get(r.get("source_call_id"))
            if target is None and len(results) == 1 and out and out[-1]["response"] is None:
                target = out[-1]
            if target is not None and target["response"] is None:
                target["response"] = _parse_json(_text_of(r.get("content")))
    return out, final

lines = []
if log and log.suffix == ".json":
    try:
        steps, final_message = _atif(json.loads(log.read_text()))
    except (json.JSONDecodeError, AttributeError):
        steps, final_message = [], ""
else:
    lines = log.read_text(errors="ignore").splitlines() if log else []

for line in lines:
    line = line.strip()
    if not line:
        continue
    try:
        ev = json.loads(line)
    except json.JSONDecodeError:
        continue
    if not isinstance(ev, dict):
        continue
    etype = ev.get("type")
    msg = ev.get("message") or {}

    if etype == "assistant":
        content = msg.get("content") or []
        if isinstance(content, str):
            content = [{"type": "text", "text": content}]
        for block in content:
            if not isinstance(block, dict):
                continue
            if block.get("type") == "tool_use":
                pending[block.get("id", "")] = {"tool": block.get("name", ""),
                                                "arguments": block.get("input") or {}, "response": None}
            elif block.get("type") == "text" and block.get("text"):
                final_message = block["text"]
    elif etype == "user":
        content = msg.get("content") or []
        if isinstance(content, str):
            content = [{"type": "text", "text": content}]
        for block in content:
            if not isinstance(block, dict) or block.get("type") != "tool_result":
                continue
            tid = block.get("tool_use_id", "")
            if tid in pending:
                pending[tid]["response"] = _parse_json(_text_of(block.get("content")))
                steps.append(pending.pop(tid))
    elif etype == "message" and msg.get("role"):
        role = msg.get("role")
        if role == "assistant":
            for tc in msg.get("tool_calls") or []:
                fn = tc.get("function") or {}
                args = fn.get("arguments")
                if isinstance(args, str):
                    args = _parse_json(args)
                pending[tc.get("id", "")] = {"tool": fn.get("name", ""),
                                             "arguments": args if isinstance(args, dict) else {}, "response": None}
                if fn.get("name") == "finish" and isinstance(args, dict) \
                        and isinstance(args.get("message"), str) and args["message"].strip():
                    final_message = args["message"]
            if isinstance(msg.get("content"), str) and msg["content"].strip() and not msg.get("tool_calls"):
                final_message = msg["content"]
        elif role == "tool":
            tid = msg.get("tool_call_id", "")
            if tid in pending:
                pending[tid]["response"] = _parse_json(msg.get("content"))
                steps.append(pending.pop(tid))
    elif etype == "result":
        r = ev.get("result", "")
        if isinstance(r, str) and r:
            final_message = r

steps.extend(pending.values())
traj_file.write_text(json.dumps({"steps": steps, "final_message": final_message}, indent=2))
print(f"[1/4 trajectory] {len(steps)} steps from {log.name if log else 'NO AGENT LOG'} -> {traj_file}")
PYEOF

[ -f "$TRAJ" ] && cp "$TRAJ" "$LOGDIR/agent_trajectory.json"

# ------------------------------------------------- grader sandbox (step 2)
# Step 2 builds and executes agent-controlled code (fix.patch) and input
# (poc.bin, the agent's proof-of-concept program). Run it as a dedicated
# unprivileged uid with no capabilities, no_new_privs and an allowlisted
# environment: no judge credentials, no write access to /tests, /logs or the
# reward files, and no access to root's /proc/<pid>/environ. The Python
# grader marks itself non-dumpable so same-uid agent code cannot ptrace it or
# read its memory. Results land in a grader-owned scratch dir; root kills
# every grader process before copying them, so nothing can rewrite them late.
GRADER_UID=64001
GRADER_DIR=/tmp/kakashi-grader            # grader-owned scratch: HOME, TMPDIR
RESULTS=/root/kakashi-grader-results      # root-only; grader writes only via fds root opened
rm -rf "$GRADER_DIR" "$RESULTS" && mkdir -p "$GRADER_DIR/home" "$GRADER_DIR/logs" "$RESULTS"
chown -R "$GRADER_UID:$GRADER_UID" "$GRADER_DIR"
[ -d /opt/ccache ] && chown -R "$GRADER_UID:$GRADER_UID" /opt/ccache || true
chmod 700 "$GRADER_DIR" "$RESULTS" /root
: > "$RESULTS/junit.xml" && chmod 666 "$RESULTS/junit.xml"
# /logs/verifier and /logs/agent are host bind mounts whose modes the grader
# could otherwise use; closing the container-local /logs parent blocks both.
LOGS_MODE="$(stat -c %a /logs)"
chmod 700 /logs
# The submission stays root-owned and read-only while it is graded, and is
# hash-checked afterwards in case /output is a mount that ignores modes.
OUT_SUM="$(cd /output && find . -type f -exec sha256sum {} + | sort)"
chown -R root:root /output 2>/dev/null || true
chmod -R u=rwX,go=rX /output 2>/dev/null || true
OPT_MODE="$(stat -c %a /opt)"
chmod 1777 /opt   # the build recreates its working dirs under /opt (if any)
grader() {
    env -i PATH="$PATH" HOME="$GRADER_DIR/home" TMPDIR="$GRADER_DIR" LC_ALL=C \
        PYTHONDONTWRITEBYTECODE=1 PYTHONPATH=/tests TESTS_DIR=/tests \
        VERIFIER_LOGS="$GRADER_DIR/logs" \
        setpriv --reuid="$GRADER_UID" --regid="$GRADER_UID" --clear-groups \
            --no-new-privs -- "$@"
}
# PIDs whose real uid is $1, read from /proc/*/status (the grader runs non-dumpable,
# so /proc/<pid> itself is root-owned).
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
        exit 1
    fi
}
# Non-dumpable: same-uid agent code cannot ptrace the grader or open its fds.
GRADER_PY='import ctypes, runpy, sys
ctypes.CDLL(None).prctl(4, 0, 0, 0, 0)  # PR_SET_DUMPABLE = 0
sys.argv = sys.argv[1:]
runpy.run_module(sys.argv[0], run_name="__main__", alter_sys=True)'

# ---------------------------------------------------------------- 2. pytest
if grader python3 -c "$GRADER_PY" pytest /tests/test_output.py \
        --junitxml=/proc/self/fd/3 -v -p no:cacheprovider \
        -W ignore::pytest.PytestReturnNotNoneWarning \
        3>"$RESULTS/junit.xml" > "$RESULTS/pytest-stdout.txt" 2>&1; then
    PYTEST_OK=1
else
    PYTEST_OK=0
fi
grader_reap
chmod "$LOGS_MODE" /logs
chmod "$OPT_MODE" /opt
[ -d /opt/ccache ] && chown -R root:root /opt/ccache || true
for root_dir in / /logs /output; do
    find "$root_dir" -xdev -mindepth 1 \( -path "$GRADER_DIR" -o -path /proc \) -prune \
        -o -user "$GRADER_UID" -prune -exec rm -rf {} + 2>/dev/null || true
done
if [ "$(cd /output && find . -type f -exec sha256sum {} + | sort)" != "$OUT_SUM" ]; then
    # Graded code rewrote the submission mid-run: score it 0, never trust it.
    echo "ERROR: the submission changed while it was being graded; scoring 0" >&2
    rm -rf "$GRADER_DIR" "$RESULTS"
    printf 'the submission changed while it was being graded\n' > "$LOGDIR/tampering_detected.txt"
    printf '{\n  "pytest": 0.0,\n  "reward": 0.0\n}\n' > "$LOGDIR/reward.json"
    exit 0
fi
for f in junit.xml pytest-stdout.txt; do
    cp "$RESULTS/$f" "$LOGDIR/$f"
done
rm -rf "$GRADER_DIR" "$RESULTS"
export TESTS_DIR=/tests VERIFIER_LOGS="$LOGDIR"
if [ "$PYTEST_OK" = 1 ]; then
    echo "[2/4 pytest] every check passed"
else
    echo "[2/4 pytest] some checks failed (reporting only; the ledger scores them)"
fi
tail -n 15 "$LOGDIR/pytest-stdout.txt"

# Convert the real fixture-aware pytest report to CTRF. Rewardkit and the
# post-hoc scorer consume this same outcome set, avoiding duplicate test runs.
if ! python3 - "$LOGDIR/junit.xml" "$LOGDIR/ctrf.json" <<'PYEOF'
import json
import pathlib
import sys
import xml.etree.ElementTree as ET

junit = pathlib.Path(sys.argv[1])
output = pathlib.Path(sys.argv[2])
root = ET.parse(junit).getroot()


def local_name(tag):
    return tag.rsplit("}", 1)[-1]


def child(case, name):
    return next((node for node in case if local_name(node.tag) == name), None)


def duration_ms(raw):
    try:
        return max(0, round(float(raw or 0) * 1000))
    except (TypeError, ValueError):
        return 0


tests = []
for case in root.iter():
    if local_name(case.tag) != "testcase":
        continue
    name = (case.get("name") or "").strip()
    if not name:
        continue

    failure = child(case, "failure")
    error = child(case, "error")
    skipped = child(case, "skipped")
    detail = None
    prefix = ""
    if error is not None:
        status, detail, prefix = "failed", error, "error"
    elif failure is not None:
        status, detail, prefix = "failed", failure, "failure"
    elif skipped is not None:
        status, detail, prefix = "skipped", skipped, "skipped"
    else:
        status = "passed"

    item = {
        "name": name,
        "status": status,
        "duration": duration_ms(case.get("time")),
    }
    suite = (case.get("classname") or "").strip()
    if suite:
        item["suite"] = suite
    if detail is not None:
        message = (detail.get("message") or "").strip()
        trace = (detail.text or "").strip()
        item["message"] = f"{prefix}: {message}" if message else prefix
        if trace:
            item["trace"] = trace
    tests.append(item)

if not tests:
    raise SystemExit("JUnit report contains no testcase entries")

statuses = ("passed", "failed", "skipped", "pending", "other")
counts = {status: sum(t["status"] == status for t in tests) for status in statuses}
report = {
    "results": {
        "tool": {"name": "pytest"},
        "summary": {
            "tests": len(tests),
            "passed": counts["passed"],
            "failed": counts["failed"],
            "skipped": counts["skipped"],
            "pending": counts["pending"],
            "other": counts["other"],
        },
        "tests": tests,
    }
}
output.write_text(json.dumps(report, indent=2) + "\n")
print(
    f"[ctrf] {len(tests)} tests: {counts['passed']} passed, "
    f"{counts['failed']} failed, {counts['skipped']} skipped -> {output}"
)
PYEOF
then
    echo "ERROR: failed to convert pytest JUnit to CTRF" >&2
    exit 1
fi

# ---------------------------------------------------------------- 3. reward
JUDGE_TRANSPORT="${JUDGE_TRANSPORT:-codex}"
SKIP_REASON=""

# The judge: GPT 6.1 Sol through the codex CLI and the host codex bridge.
JUDGE_MODEL="${JUDGE_MODEL:-openai/gpt-6.1-sol}"

if [ "${JUDGE_SKIP:-0}" = 1 ]; then
    SKIP_REASON="JUDGE_SKIP=1"
elif [ ! -s "$RK/rubric/judge.toml" ]; then
    SKIP_REASON="the task ships no rubric (no tests/reward/rubric/judge.toml)"
elif [ "$JUDGE_TRANSPORT" != codex ]; then
    SKIP_REASON="unsupported judge transport $JUDGE_TRANSPORT (codex only)"
elif [ -z "${CODEX_BRIDGE_URL:-}" ] || [ -z "${KAKASHI_CODEX_BRIDGE_SECRET:-}" ]; then
    SKIP_REASON="no codex bridge (CODEX_BRIDGE_URL / KAKASHI_CODEX_BRIDGE_SECRET are empty)"
# An unreachable bridge makes codex retry every criterion until its timeout.
elif ! curl -fsS -m 10 -o /dev/null "${CODEX_BRIDGE_URL%/}/healthz"; then
    SKIP_REASON="codex bridge unreachable at ${CODEX_BRIDGE_URL%/}/healthz"
fi
# D2-defensive: don't judge without a trajectory -- produces a falsely low rubric
if [ -z "$SKIP_REASON" ] && ! python3 -c 'import json,sys; sys.exit(0 if json.load(open(sys.argv[1])).get("steps") else 1)' "$TRAJ" 2>/dev/null; then
    SKIP_REASON="no agent trajectory available to the judge"
fi

# Set up the judge workspace: instruction, final message, trajectory, delivered files
JW="$LOGDIR/judge_ws"
rm -rf "$JW" && mkdir -p "$JW"
[ -f "$RK/rubric/instruction.md" ] && cp "$RK/rubric/instruction.md" "$JW/instruction.md"
if [ -s /logs/agent/trajectory.json ]; then
    cp /logs/agent/trajectory.json "$JW/trajectory.json"
elif [ -s "$TRAJ" ]; then
    cp "$TRAJ" "$JW/trajectory.json"
fi
python3 - "$TRAJ" "$JW/final_message.md" <<'PYEOF'
import json, pathlib, sys
try:
    text = json.loads(pathlib.Path(sys.argv[1]).read_text()).get("final_message") or ""
except Exception:
    text = ""
pathlib.Path(sys.argv[2]).write_text(text if text.strip() else "(the agent produced no final message)\n")
PYEOF
cp "$JW/final_message.md" "$LOGDIR/final_message.md"
mkdir -p "$JW/workspace" && cp -a /output/. "$JW/workspace/" 2>/dev/null || true

RK_OUT="$LOGDIR/rewardkit-stdout.txt"; : > "$RK_OUT"
JUDGE_RAN=0; JUDGE_ERROR=""
# The pytest channel is scored here, as root, from the ctrf.json written above.
echo "[3/4 reward] rewardkit: pytest ledger"
if ! REWARDKIT_LOG_DIR="$LOGDIR" rewardkit "$RK/pytest" --workspace /output --output "$LOGDIR/reward.json" >> "$RK_OUT" 2>&1 \
        || [ ! -s "$LOGDIR/reward.json" ]; then
    echo "ERROR: the pytest ledger failed; scored 0." >&2
    tail -n 20 "$RK_OUT" >&2
    # A ledger that exits non-zero may have scored only part of the tests.
    rm -f "$LOGDIR/reward.json"
    exit 1
fi
PYTEST_SCORE="$(python3 -c 'import json,math,sys
d=json.load(open(sys.argv[1])); r=d.get("reward", d.get("score"))
print(r if isinstance(r,(int,float)) and math.isfinite(r) else 0.0)' "$LOGDIR/reward.json")"
rm -f "$LOGDIR/reward.json" "$LOGDIR/reward-details.json"

# The judge runs codex with full access over agent-written text, so it runs as its own
# unprivileged uid that can write only its private run directory and the judge workspace.
# Its result supplies the rubric value alone; the pytest value above cannot be changed by it.
JUDGE_UID=64002
JRUN=/tmp/kakashi-judge
RUBRIC_SCORE=""
if [ -z "$SKIP_REASON" ]; then
    echo "[3/4 reward] rewardkit: rubric, judged by $JUDGE_TRANSPORT / $JUDGE_MODEL"
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
            "$(command -v rewardkit)" --yolo --max-concurrent-agent 1 "$JRUN/rk" \
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
        JUDGE_ERROR="rewardkit failed with the judge: $(grep -E 'rror' "$RK_OUT" | tail -n 1 | sed 's/^[ |]*//' | cut -c1-400)"
        echo "ERROR: $JUDGE_ERROR (full output: rewardkit-stdout.txt)" >&2
    fi
    rm -rf "$JRUN"
    chown -R root:root "$JW" 2>/dev/null || true
else
    echo "[3/4 reward] rubric channel UNSCORED: $SKIP_REASON"
fi
# reward.json: the pytest channel, the rubric channel when judged, and their
# reward.toml weighted mean; with no rubric, reward = pytest
python3 - "$LOGDIR/reward.json" "$PYTEST_SCORE" "$RUBRIC_SCORE" "$RK/reward.toml" <<'PYEOF'
import json, pathlib, sys, tomllib
p = pathlib.Path(sys.argv[1]); pytest = float(sys.argv[2])
reward = {"pytest": pytest, "reward": pytest}
if sys.argv[3]:
    w = tomllib.loads(pathlib.Path(sys.argv[4]).read_text())["reward"][0]["weights"]
    reward["rubric"] = float(sys.argv[3])
    reward["reward"] = round((w["pytest"] * pytest + w["rubric"] * reward["rubric"]) / (w["pytest"] + w["rubric"]), 4)
p.write_text(json.dumps(reward, indent=2))
PYEOF
[ "$JUDGE_RAN" = 0 ] && printf '%s\n' "${JUDGE_ERROR:-$SKIP_REASON}" > "$LOGDIR/rubric_judge_failed.txt"
tail -n 6 "$RK_OUT"

# ---------------------------------------------------------------- 4. record
JUDGE_RAN="$JUDGE_RAN" SKIP_REASON="$SKIP_REASON" JUDGE_ERROR="$JUDGE_ERROR" \
JUDGE_TRANSPORT="$JUDGE_TRANSPORT" RK="$RK" python3 - <<'PYEOF'
import importlib.metadata as md, json, os, pathlib, subprocess, tomllib
L = pathlib.Path("/logs/verifier")

def load(p):
    try:
        return json.loads(p.read_text())
    except Exception:
        return None

reward = load(L / "reward.json") or {}
details = load(L / "reward-details.json") or {}
ran = os.environ.get("JUDGE_RAN") == "1"
reason = os.environ.get("JUDGE_ERROR") or os.environ.get("SKIP_REASON") or None
rub = details.get("rubric") if isinstance(details, dict) else None
crits = (rub or {}).get("criteria") or []
if ran and isinstance(rub, dict):
    timed = any("timed out" in str(w) for w in rub.get("warnings") or [])
    errored = bool(crits) and all(c.get("error") for c in crits)
    if timed or errored:
        ran = False
        reason = "judge timed out" if timed else "every criterion errored: " + str(crits[0].get("error"))[:200]
        (L / "rubric_judge_failed.txt").write_text(reason + "\n")
        if isinstance(reward.get("pytest"), (int, float)):
            reward = {"pytest": reward["pytest"], "reward": reward["pytest"]}
            (L / "reward.json").write_text(json.dumps(reward, indent=2))

policy = {}
try:
    policy = tomllib.loads((pathlib.Path(os.environ["RK"]) / "reward.toml").read_text())["reward"][0]["weights"]
except Exception:
    pass
if ran and isinstance(reward.get("rubric"), (int, float)) and reward["rubric"] < 0:
    # judge.toml weights are source_weight / total positive weight, so rewardkit's
    # weighted-sum already equals (earned - penalised) / total positive. It can go below
    # 0 when penalties outweigh what was earned; clamp it here and recombine the
    # channels with the policy weights
    reward["rubric_unclamped"] = reward["rubric"]
    reward["rubric"] = 0.0
    chans = {k: reward[k] for k in policy if isinstance(reward.get(k), (int, float))}
    if chans:
        reward["reward"] = round(sum(reward[k] * policy[k] for k in chans) / sum(policy[k] for k in chans), 4)
    (L / "reward.json").write_text(json.dumps(reward, indent=2))
def version(cmd):
    try:
        return subprocess.run(cmd, capture_output=True, text=True, timeout=20).stdout.strip() or None
    except Exception:
        return None


transport = os.environ.get("JUDGE_TRANSPORT")
judge = {"ran": ran, "transport": transport if ran else None,
         "model": (os.environ.get("JUDGE_MODEL") or None) if ran else None,
         "reason": None if ran else reason,
         "criteria": len(crits) if ran else 0,
         "configured": (rub or {}).get("judge") if ran else None,
         "usage": (rub or {}).get("usage") if ran else None,
         "rewardkit": md.version("harbor-rewardkit"),
         "codex": version(["codex", "--version"]) if ran and transport == "codex" else None}
(L / "judge.json").write_text(json.dumps(judge, indent=2))
(L / "reward_producer.json").write_text(json.dumps({
    "producer": "rewardkit", "channels": sorted(k for k in reward if k not in ("reward", "rubric_unclamped")),
    "weights": policy if ran else {"pytest": 1.0}}, indent=2))
print("[4/4 record] judge:", "ran" if ran else f"not run ({reason})")
print("[4/4 record] reward.json:", json.dumps(reward))
PYEOF
