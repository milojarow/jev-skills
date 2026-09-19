#!/bin/sh
# Live authentication and two obvious controls; not domain calibration.
set -eu
scriptDir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
exec python3 - "$scriptDir/../skills/jev-skill/bin/jev" <<'PY'
import json
import math
import os
import subprocess
import sys

cli = sys.argv[1]
env = os.environ.copy()
# This gate always exercises the real endpoint, even after local fake tests.
env["JEV_API_BASE"] = "https://api.typesafe.ai"


def run(label, args, expected=0, childEnv=None):
    try:
        result = subprocess.run([cli] + args, env=childEnv or env, capture_output=True, text=True, timeout=180)
    except (OSError, subprocess.TimeoutExpired):
        print("check-live: FAIL " + label + " (process failure or deadline)", file=sys.stderr)
        sys.exit(1)
    if result.returncode != expected:
        print("check-live: FAIL " + label + " (exit " + str(result.returncode) + ", expected " + str(expected) + ")", file=sys.stderr)
        sys.exit(1)
    print("check-live: PASS " + label + " (exit " + str(result.returncode) + ")")
    return result.stdout


run("models authentication", ["models"])
question = "Does the message explicitly ask to stop receiving promotional messages?"
for label, message, positive in (
    ("positive control", "Stop sending me promotional messages. Unsubscribe me now.", True),
    ("negative control", "Please subscribe me to your promotional messages. I want to receive your offers.", False),
):
    output = run(label, ["noul", question, "--state", message, "--plain"])
    try:
        value = json.loads(output)
        passed = type(value) in (int, float) and math.isfinite(value) and 0 <= value <= 1
        passed = passed and (value > 0.9 if positive else value < 0.1)
    except ValueError:
        passed = False
    if not passed:
        print("check-live: FAIL " + label + " threshold", file=sys.stderr)
        sys.exit(1)
    print("check-live: PASS " + label + " threshold (noul=" + str(value) + ")")
invalidEnv = env.copy()
invalidEnv["TYPESAFE_API_KEY"] = "apikey_relleno"
run("invalid credential", ["models"], expected=3, childEnv=invalidEnv)
print("check-live: PASS")
PY
