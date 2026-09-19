#!/bin/sh
# Offline behavioral checks; all HTTP traffic targets the local fake server.
set -eu
scriptDir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
exec python3 - "$scriptDir/.." <<'PY'
import email.utils
import http.server
import json
import os
from pathlib import Path
import socket
import subprocess
import sys
import tempfile
import threading
import time
import uuid

repo = Path(sys.argv[1]).resolve()
cli = str(repo / "skills/jev-skill/bin/jev")
fakeKey = "fixture-" + uuid.uuid4().hex
otherKey = "fallback-" + uuid.uuid4().hex
state = {"requests": [], "responses": [], "key": fakeKey, "process": None, "argvSeen": False}
failures = []
checks = 0


def require(condition, label):
    global checks
    checks += 1
    if not condition:
        failures.append(label)


def checkArgv(process):
    command = Path(f"/proc/{process.pid}/cmdline").read_bytes()
    require(cli.encode() in command, "argv positive control sees the running CLI")
    require(fakeKey.encode() not in command and otherKey.encode() not in command, "CLI argv excludes credentials")
    children = Path(f"/proc/{process.pid}/task/{process.pid}/children").read_text().strip()
    require(not children, "CLI creates no child processes")
    argvClean = True
    for path in Path("/proc").glob("[0-9]*/cmdline"):
        try:
            command = path.read_bytes()
        except (FileNotFoundError, ProcessLookupError, PermissionError):
            continue
        argvClean = argvClean and fakeKey.encode() not in command and otherKey.encode() not in command
    require(argvClean, "visible process argv excludes credentials")
    state["argvSeen"] = True


def handleRequest(handler):
    try:
        length = int(handler.headers.get("Content-Length", "0"))
        body = json.loads(handler.rfile.read(length)) if length else None
        state["requests"].append((handler.path, body, time.monotonic(), dict(handler.headers)))
        require(handler.headers.get("Authorization") == "Bearer " + state["key"], "Authorization reaches the server")
        if state["process"] is not None:
            checkArgv(state["process"])
        reply = state["responses"].pop(0) if state["responses"] else {"status": 200}
        if reply.get("disconnect"):
            handler.connection.shutdown(socket.SHUT_RDWR)
            handler.connection.close()
            return
        if body is None:
            result = {"models": [{"name": "fixture-model", "description": "Local fixture", "release_date": "2026-01-01"}]}
        else:
            require(handler.headers.get("Content-Type") == "application/json", "POST uses JSON content type")
            answers = {}
            for key, question in body["questions"].items():
                kind = question["type"]
                if kind == "noul":
                    answer = {"type": kind, "noul": 0.97}
                elif kind == "choice":
                    keys = list(question["criteria"])
                    answer = {"type": kind, "choice": keys[0], "probabilities": {k: float(i == 0) for i, k in enumerate(keys)}, "confidence": 1.0}
                else:
                    keys = [str(i) for i in range(len(question["criteria"]))]
                    answer = {"type": kind, "score": 0.25, "probabilities": {k: 0.75 if i == 0 else 0.25 if i == 1 else 0.0 for i, k in enumerate(keys)}, "legend": dict(zip(keys, question["criteria"])), "confidence": 0.5}
                answers[key] = answer
            result = {"model": "fixture-model", "usage": {"input_tokens": 8, "output_tokens": 2}, "answers": answers}
        if "json" in reply:
            result = reply["json"]
        raw = reply.get("raw", json.dumps(result).encode())
        handler.send_response(reply["status"])
        if "retryAfter" in reply:
            handler.send_header("Retry-After", reply["retryAfter"])
        if "location" in reply:
            handler.send_header("Location", reply["location"])
        handler.send_header("Content-Length", str(len(raw)))
        handler.end_headers()
        handler.wfile.write(raw)
    except Exception:
        failures.append("fake server failed while processing a request")


http.server.BaseHTTPRequestHandler.do_GET = handleRequest
http.server.BaseHTTPRequestHandler.do_POST = handleRequest
http.server.BaseHTTPRequestHandler.log_message = lambda *args: None


def run(label, args, expected=0, inputText=None, changes=None, watch=False, returnError=False, timeout=20):
    state["process"] = None
    childEnv = env.copy()
    childEnv.update(changes or {})
    childEnv = {k: v for k, v in childEnv.items() if v is not None}
    process = subprocess.Popen([cli] + args, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, env=childEnv)
    if watch:
        # Input blocks the CLI until the parent has made its PID visible to the server.
        state["process"] = process
    try:
        stdout, stderr = process.communicate(inputText, timeout=timeout)
    except subprocess.TimeoutExpired:
        process.kill()
        stdout, stderr = process.communicate()
        failures.append(label + ": subprocess deadline exceeded")
    finally:
        state["process"] = None
    require(process.returncode == expected, label + ": exit " + str(expected))
    require(all(secret not in stdout + stderr for secret in (fakeKey, otherKey)), label + ": no credential in output")
    if expected:
        require(stdout == "", label + ": stdout is empty on error")
        require(len(stderr.splitlines()) == 1, label + ": one stderr line")
    else:
        require(stderr == "", label + ": stderr is empty on success")
    return stderr if returnError else stdout


def decodeOutput(text):
    try:
        return json.loads(text)
    except ValueError:
        failures.append("success output must be valid JSON")
        return {}


with tempfile.TemporaryDirectory(prefix="jev-cli-") as temp:
    testHome = Path(temp)
    env = {k: v for k, v in os.environ.items() if not k.lower().endswith("_proxy")}
    env.update({"HOME": str(testHome), "TYPESAFE_API_KEY": fakeKey, "NO_PROXY": "*", "PYTHONDONTWRITEBYTECODE": "1"})
    with http.server.HTTPServer(("127.0.0.1", 0), http.server.BaseHTTPRequestHandler) as server:
        env["JEV_API_BASE"] = "http://127.0.0.1:" + str(server.server_port)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            questions = {
                "present": {"type": "noul", "instructions": "Does the message request help?"},
                "route": {"type": "choice", "instructions": "Which team?", "criteria": {"support": "Help", "none": "No match"}},
                "severity": {"type": "score", "instructions": "How severe?", "criteria": ["Cosmetic", "Blocking"]},
            }
            questionFile = testHome / "questions.json"
            questionFile.write_text(json.dumps(questions))
            stateFile = testHome / "state.json"
            stateFile.write_text('{"message":"Ayúdame, por favor."}')
            config = testHome / ".secrets/environment.d/11-secrets.conf"
            config.parent.mkdir(parents=True)
            config.write_text("# Fixture only\nTYPESAFE_API_KEY='" + otherKey + "'\n")

            require(run("version", ["--version"]).strip() == "jev 0.1.0", "CLI version")
            run("help", ["--help"])
            run("models", ["models"])
            full = decodeOutput(run("batch full", ["ask", "--questions", str(questionFile), "--state-file", str(stateFile), "--full", "--model", "fixture-pin"]))
            require(full.get("model") == "fixture-model" and "usage" in full, "full response includes model and usage")
            require(state["requests"][-1][1]["model"] == "fixture-pin", "model override sent")
            require(state["requests"][-1][1]["state"] == {"message": "Ayúdame, por favor."}, "state file parsed as object")
            require(set(full.get("answers", {})) == set(questions), "mixed batch answers retain IDs")
            answers = decodeOutput(run("batch answers", ["ask", "--questions", str(questionFile)], inputText='["one","two"]', watch=True))
            require(set(answers) == set(questions), "ask defaults to answers only")
            require(state["requests"][-1][1]["state"] == ["one", "two"], "stdin parsed as array")
            require(state["argvSeen"], "argv checked while the authenticated request is alive")
            run("questions stdin", ["ask", "--questions", "-", "--state", "help"], inputText=json.dumps(questions))
            run("forced text", ["noul", "Help requested?", "--state", '{"message":"help"}', "--state-text"])
            require(state["requests"][-1][1]["state"] == '{"message":"help"}', "state-text preserves JSON source")
            run("plain text", ["noul", "Help requested?", "--state-file", "-"], inputText="Please help.")
            require(state["requests"][-1][1]["state"] == "Please help.", "non-JSON stays text")
            for scalar in ("42", "true", "null", '"quoted text"', '  "texto"\n', "  texto libre\n"):
                run("JSON scalar stays text", ["noul", "Question?", "--state", scalar])
                require(state["requests"][-1][1]["state"] == scalar, "only JSON objects and arrays are converted")
            run("forced array text", ["noul", "Question?", "--state-text"], inputText=' ["one"]\n')
            require(state["requests"][-1][1]["state"] == ' ["one"]\n', "state-text preserves arrays and whitespace")
            output = run("noul scalar", ["noul", "Help requested?", "--true", "Requests help", "--false", "No request", "-p"], inputText="help")
            require(output == "0.97\n", "noul plain returns probability")
            require(state["requests"][-1][1]["questions"]["answer"]["criteria"] == {"true": "Requests help", "false": "No request"}, "noul criteria transmitted")
            output = run("choice scalar", ["choice", "Which route?", "-o", "support=Help=needed", "-o", "none=No match", "--state", "help", "--plain"])
            require(output == "support\n", "choice plain returns unquoted key")
            require(state["requests"][-1][1]["questions"]["answer"]["criteria"]["support"] == "Help=needed", "option splits only first equals sign")
            output = run("score scalar", ["score", "How severe?", "-l", "Cosmetic", "-l", "Blocking", "--state", "help", "-p"])
            require(output == "0.25\n", "score plain returns fractional value")
            output = decodeOutput(run("single answer", ["choice", "Which route?", "-o", "support=Help", "-o", "none=No match", "--state", "help"]))
            require(output.get("type") == "choice" and "answers" not in output, "sugar defaults to one answer object")
            state["key"] = otherKey
            run("file fallback", ["models"], changes={"TYPESAFE_API_KEY": None})
            run("empty environment fallback", ["models"], changes={"TYPESAFE_API_KEY": ""})
            state["key"] = fakeKey
            run("environment precedence", ["models"])
            noKeyHome = testHome / "empty-home"
            noKeyHome.mkdir()
            run("missing key", ["models"], 3, changes={"TYPESAFE_API_KEY": None, "HOME": str(noKeyHome)})

            invalidCases = [
                ("missing command", [], None),
                ("unknown argument", ["models", "--unknown", "invalid"], None),
                ("stdin collision", ["ask", "--questions", "-"], json.dumps(questions)),
                ("conflicting state", ["noul", "Question?", "--state", "x", "--state-file", str(stateFile)], None),
                ("duplicate option", ["choice", "Question?", "-o", "same=a", "-o", "same=b", "--state", "x"], None),
                ("bad option", ["choice", "Question?", "-o", "bad", "--state", "x"], None),
                ("one score level", ["score", "Question?", "-l", "Only one", "--state", "x"], None),
                ("bad questions JSON", ["ask", "--questions", "-", "--state", "x"], "{"),
                ("empty questions", ["ask", "--questions", "-", "--state", "x"], "{}"),
                ("duplicate question IDs", ["ask", "--questions", "-", "--state", "x"], '{"a":{},"a":{}}'),
                ("bad question type", ["ask", "--questions", "-", "--state", "x"], '{"a":{"type":"text","instructions":"Q"}}'),
                ("missing input file", ["ask", "--questions", str(testHome / "absent"), "--state", "x"], None),
                ("plain full conflict", ["noul", "Question?", "--state", "x", "--plain", "--full"], None),
            ]
            count = len(state["requests"])
            for label, args, inputText in invalidCases:
                run(label, args, 2, inputText=inputText)
            require(len(state["requests"]) == count, "invalid input never contacts API")
            run("invalid base", ["models"], 2, changes={"JEV_API_BASE": "file:///unusable"})

            for status, code in ((401, 3), (403, 3), (422, 5), (400, 4)):
                count = len(state["requests"])
                state["responses"] = [{"status": status, "raw": ("secret echo: " + fakeKey + "\nsecond line").encode()}]
                stderr = run("HTTP " + str(status), ["models"], code, returnError=True)
                require(len(state["requests"]) == count + 1, "non-retryable response tried once")
                if status == 422:
                    require("secret echo:" in stderr and "[REDACTED]" in stderr, "422 preserves sanitized text detail")
                else:
                    require("secret echo:" not in stderr and "second line" not in stderr, "other errors suppress remote bodies")

            detail = [{"loc": ["body", "questions", "present", "criteria"], "msg": "Invalid criteria " + fakeKey + "\n\t\x00\x1b\x85\u2028\u202e; use a map"}]
            state["responses"] = [{"status": 422, "json": {"detail": detail}}]
            stderr = run("422 JSON detail", ["models"], 5, returnError=True)
            require("present" in stderr and "criteria" in stderr and "Invalid criteria" in stderr, "422 names the API validation location and message")
            require("[REDACTED]" in stderr and all(c.isprintable() for c in stderr.rstrip("\n")), "422 redacts key and removes control characters")
            escapedKey = "".join("\\u" + format(ord(c), "04x") for c in fakeKey)
            state["responses"] = [{"status": 422, "raw": ('{"detail":"Invalid field ' + escapedKey + '"}').encode()}]
            stderr = run("422 escaped credential", ["models"], 5, returnError=True)
            require("Invalid field" in stderr and "[REDACTED]" in stderr, "422 decodes escaped JSON before redacting")
            state["responses"] = [{"status": 422, "json": {"detail": "Invalid criteria: " + "x" * 420 + fakeKey + "y" * 600}}]
            stderr = run("422 bounded detail", ["models"], 5, returnError=True)
            require("Invalid criteria:" in stderr and len(stderr.rstrip("\n")) <= 500, "422 stderr bounded to 500 characters")
            require(fakeKey[:16] not in stderr, "422 redaction precedes truncation")

            for retryAfter in ("3600", "30.0001", "9" * 400, email.utils.formatdate(time.time() + 3600, usegmt=True)):
                count = len(state["requests"])
                state["responses"] = [{"status": 429, "retryAfter": retryAfter}]
                started = time.monotonic()
                stderr = run("excessive Retry-After", ["models"], 4, returnError=True, timeout=3)
                require(time.monotonic() - started < 3, "excessive Retry-After fails without waiting")
                require(len(state["requests"]) == count + 1, "excessive Retry-After makes one attempt")
                require("Retry-After" in stderr and "seconds" in stderr and "30" in stderr, "excessive Retry-After reports the limit")
                if retryAfter == "3600":
                    require("3600" in stderr, "excessive Retry-After reports requested seconds")

            for status in (429, 529, 503):
                count = len(state["requests"])
                state["responses"] = [{"status": status, "retryAfter": "1"}, {"status": 200}]
                run("retry HTTP " + str(status), ["models"])
                requests = state["requests"][count:]
                require(len(requests) == 2, "retryable status recovers on second attempt")
                require(len(requests) == 2 and requests[1][2] - requests[0][2] >= 1, "Retry-After seconds honored")
            deadline = int(time.time()) + 3
            state["responses"] = [{"status": 429, "retryAfter": email.utils.formatdate(deadline, usegmt=True)}, {"status": 200}]
            run("HTTP-date Retry-After", ["models"])
            require(time.time() >= deadline, "Retry-After HTTP-date honored")
            count = len(state["requests"])
            state["responses"] = [{"status": 503}] * 3
            run("retry exhaustion", ["models"], 4)
            requests = state["requests"][count:]
            require(len(requests) == 3, "three attempts maximum")
            require(len(requests) == 3 and requests[1][2] - requests[0][2] >= 1 and requests[2][2] - requests[1][2] >= 2, "exponential backoff without header")
            state["responses"] = [{"status": 200, "disconnect": True}, {"status": 200}]
            run("network recovery", ["models"])
            count = len(state["requests"])
            state["responses"] = [{"status": 200, "disconnect": True}] * 3
            run("network exhaustion", ["models"], 4)
            require(len(state["requests"]) == count + 3, "network failure limited to three attempts")
            count = len(state["requests"])
            state["responses"] = [{"status": 302, "location": env["JEV_API_BASE"] + "/redirect-target"}]
            run("redirect refused", ["models"], 4)
            require(len(state["requests"]) == count + 1, "Authorization never follows redirects")
            state["responses"] = [{"status": 200, "raw": b"not JSON"}]
            run("malformed response", ["models"], 4)
            state["responses"] = [{"status": 200, "json": {"answers": {}}}]
            stderr = run("missing answers", ["noul", "Question?", "--state", "x"], 4, returnError=True)
            require("'answer'" in stderr and "answers" in stderr, "missing response names the caller's question")
            responseCases = [
                ("present", "noul", "invalid remote value"),
                ("present", "noul", 10 ** 400),
                ("present", "type", "invalid remote value"),
                ("route", "choice", "invalid remote value"),
                ("route", "confidence", 2),
                ("route", "probabilities", {"support": -0.1, "none": 1.1}),
                ("severity", "score", "invalid remote value"),
                ("severity", "legend", "invalid remote value"),
            ]
            for questionId, field, invalidValue in responseCases:
                malformed = json.loads(json.dumps(full))
                malformed["answers"][questionId][field] = invalidValue
                state["responses"] = [{"status": 200, "json": malformed}]
                stderr = run("invalid answer " + field, ["ask", "--questions", str(questionFile), "--state", "x"], 4, returnError=True)
                require(repr(questionId) in stderr and field in stderr, "response error names question and invalid field")
                require("invalid remote value" not in stderr, "response error does not echo malformed field content")
            malformed = json.loads(json.dumps(full))
            malformed["answers"]["unexpected remote ID"] = malformed["answers"]["present"]
            state["responses"] = [{"status": 200, "json": malformed}]
            stderr = run("unexpected answer ID", ["ask", "--questions", str(questionFile), "--state", "x"], 4, returnError=True)
            require("answers" in stderr and "unexpected remote ID" not in stderr, "response error hides remote-only question IDs")
            unsafeId = "caller\n\x1b\u202e" + fakeKey
            questionText = json.dumps({unsafeId: questions["present"]})
            malformed = {"model": "fixture-model", "usage": {}, "answers": {unsafeId: {"type": "noul", "noul": "invalid remote value"}}}
            state["responses"] = [{"status": 200, "json": malformed}]
            stderr = run("unsafe caller ID", ["ask", "--questions", "-", "--state", "x"], 4, inputText=questionText, returnError=True)
            require("caller" in stderr and "noul" in stderr and "[REDACTED]" in stderr, "caller ID is actionable and credential-redacted")
            require(all(c.isprintable() for c in stderr.rstrip("\n")), "caller ID cannot inject terminal controls")
            state["responses"] = [{"status": 200, "json": {"models": [{"name": fakeKey}]}}]
            run("success credential echo", ["models"])
            require(not state["responses"], "all scripted responses consumed")
        finally:
            server.shutdown()
            thread.join(timeout=5)
            require(not thread.is_alive(), "fake server stopped")

if failures:
    for failure in failures:
        print("FAIL: " + failure, file=sys.stderr)
    sys.exit(1)
print("check-cli: PASS (" + str(checks) + " assertions; local HTTP only)")
PY
