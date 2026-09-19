#!/bin/sh
# Offline behavioral checks. Optional argument: a historical CLI to challenge.
set -eu
scriptDir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
exec python3 - "$scriptDir/.." "$@" <<'PY'
import email.utils
import http.client
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
if len(sys.argv) > 3:
    sys.exit("usage: check-cli.sh [CLI]")
cli = str(Path(sys.argv[2]).resolve() if len(sys.argv) == 3 else repo / "skills/jev-skill/bin/jev")
fakeKey = "fixture-" + uuid.uuid4().hex
otherKey = "fallback-" + uuid.uuid4().hex
keyringKey = "keyring-" + uuid.uuid4().hex
fixtureKeys = (fakeKey, otherKey, keyringKey)
state = {"requests": [], "responses": [], "key": fakeKey, "process": None, "argvSeen": False}
failures = []
checks = 0
networkGuard = """
import runpy, sys
cli, auditPath = sys.argv[1:3]
sys.argv = [cli] + sys.argv[3:]
def rejectNetwork(event, args):
    if event in ('socket.getaddrinfo', 'socket.connect', 'socket.sendto'):
        with open(auditPath, 'a') as audit:
            audit.write(event + '\\n')
        raise OSError('Network attempt blocked by offline test')
sys.addaudithook(rejectNetwork)
runpy.run_path(cli, run_name='__main__')
"""
missingHomeGuard = """
import os, pwd, runpy, sys
from pathlib import Path
cli = sys.argv[1]
sys.argv = [cli] + sys.argv[2:]
assert 'HOME' not in os.environ, 'Fixture must remove HOME'
def missingUser(uid):
    raise KeyError(uid)
pwd.getpwuid = missingUser
try:
    Path.home()
except RuntimeError:
    pass
else:
    raise AssertionError('Fixture must make Path.home() raise RuntimeError')
runpy.run_path(cli, run_name='__main__')
"""
errorStreamGuard = """
import os, runpy, sys
cli, mode, code = sys.argv[1:]
namespace = runpy.run_path(cli)
if mode == 'buffered pipe':
    sys.stderr.reconfigure(line_buffering=False, write_through=False)
elif mode in ('bad descriptor', 'closed stream'):
    sys.stderr = open(os.devnull, 'w')
    if mode == 'bad descriptor':
        os.close(sys.stderr.fileno())
    else:
        sys.stderr.close()
elif mode == 'absent stream':
    sys.stderr = None
namespace['fail'](int(code), 'fixture diagnostic')
"""


def require(condition, label):
    global checks
    checks += 1
    if not condition:
        failures.append(label)


def checkArgv(process):
    command = Path(f"/proc/{process.pid}/cmdline").read_bytes()
    require(cli.encode() in command, "argv positive control sees the running CLI")
    require(all(secret.encode() not in command for secret in fixtureKeys), "CLI argv excludes credentials")
    children = Path(f"/proc/{process.pid}/task/{process.pid}/children").read_text().strip()
    require(not children, "CLI creates no child processes")
    argvClean = True
    for path in Path("/proc").glob("[0-9]*/cmdline"):
        try:
            command = path.read_bytes()
        except (FileNotFoundError, ProcessLookupError, PermissionError):
            continue
        argvClean = argvClean and all(secret.encode() not in command for secret in fixtureKeys)
    require(argvClean, "visible process argv excludes credentials")
    state["argvSeen"] = True


def handleRequest(handler):
    try:
        if getattr(handler.server, "proxyRequests", None) is not None:
            handler.server.proxyRequests.append((handler.command, handler.path, dict(handler.headers)))
            raw = b'{"models":[]}'
            handler.send_response(502 if handler.command == "CONNECT" else 200)
            handler.send_header("Content-Length", str(len(raw)))
            handler.end_headers()
            handler.wfile.write(raw)
            return
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
http.server.BaseHTTPRequestHandler.do_CONNECT = handleRequest
http.server.BaseHTTPRequestHandler.log_message = lambda *args: None


def run(label, args, expected=0, inputText=None, changes=None, watch=False, returnError=False, timeout=20, networkLog=None, missingHome=False):
    state["process"] = None
    childEnv = env.copy()
    childEnv.update(changes or {})
    childEnv = {k: v for k, v in childEnv.items() if v is not None}
    command = [cli] + args
    if networkLog is not None:
        command = [sys.executable, "-c", networkGuard, cli, str(networkLog)] + args
    elif missingHome:
        command = [sys.executable, "-c", missingHomeGuard, cli] + args
    process = subprocess.Popen(command, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=childEnv)
    inputBytes = inputText.encode("utf-8") if isinstance(inputText, str) else inputText
    if watch:
        # Input blocks the CLI until the parent has made its PID visible to the server.
        state["process"] = process
    try:
        stdout, stderr = process.communicate(inputBytes, timeout=timeout)
    except subprocess.TimeoutExpired:
        process.kill()
        stdout, stderr = process.communicate()
        failures.append(label + ": subprocess deadline exceeded")
    finally:
        state["process"] = None
    stdout = stdout.decode("utf-8", errors="replace")
    stderr = stderr.decode("utf-8", errors="replace")
    require(process.returncode == expected, label + ": expected exit " + str(expected) + ", got " + str(process.returncode))
    require(all(secret not in stdout + stderr for secret in fixtureKeys), label + ": no credential in output")
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


def checkKeySources(testHome):
    primary = "TYPESAFE_API_KEY='" + otherKey + "'\n"
    keyring = '# Fixture only\nTYPESAFE_API_KEY="' + keyringKey + '"\n'
    relativePaths = (".secrets/environment.d/11-secrets.conf", ".config/typesafe/keyring.env")
    cases = [
        ("R8-a keyring only", None, keyring, None, keyringKey),
        ("R8-b first file wins", primary, keyring, None, otherKey),
        ("R8-c first file lacks variable", "UNRELATED=ignored\n# " + primary, keyring, None, keyringKey),
        ("R8-d export in keyring", None, keyring.replace("TYPESAFE_API_KEY=", "export TYPESAFE_API_KEY="), None, keyringKey),
        ("R8-d export in first file", "  export " + primary, keyring, None, otherKey),
        ("R8-e no credential", None, None, None, None),
        ("R8-f environment wins both files", primary, keyring, fakeKey, fakeKey),
        ("R8 empty first file value", "TYPESAFE_API_KEY=\n", keyring, None, keyringKey),
        ("R8 final empty first file value", primary + "export TYPESAFE_API_KEY=''\n", keyring, None, keyringKey),
        ("R8 empty environment", primary, keyring, "", otherKey),
        ("R8 empty environment and first file", 'TYPESAFE_API_KEY=""\n', keyring, "", keyringKey),
        ("R8 last assignment in first file", keyring + primary, None, None, otherKey),
        ("R8 last assignment in keyring", None, primary + keyring, None, keyringKey),
        ("R8 bare keyring assignment", None, "TYPESAFE_API_KEY=" + keyringKey + "\n", None, keyringKey),
        ("R8 single quoted keyring", None, "export TYPESAFE_API_KEY='" + keyringKey + "'\n", None, keyringKey),
        ("R8 final empty keyring value", None, keyring + 'TYPESAFE_API_KEY=""\n', None, None),
        ("R8 invalid environment stops lookup", primary, keyring, fakeKey + " invalid", None),
        ("R8 invalid first file stops lookup", "TYPESAFE_API_KEY='" + otherKey + " invalid'\n", keyring, None, None),
        ("R8 invalid keyring value", None, "TYPESAFE_API_KEY='" + keyringKey + "\tinvalid'\n", None, None),
        ("R9 BOM keyring only", None, b"\xef\xbb\xbfTYPESAFE_API_KEY=" + keyringKey.encode() + b"\n", None, keyringKey),
        ("R9 BOM first file wins", b"\xef\xbb\xbfTYPESAFE_API_KEY=" + otherKey.encode() + b"\n", keyring, None, otherKey),
    ]
    for index, (label, first, second, envKey, expectedKey) in enumerate(cases):
        keyHome = testHome / ("key-source-" + str(index))
        for relativePath, content in zip(relativePaths, (first, second)):
            if content is not None:
                path = keyHome / relativePath
                path.parent.mkdir(parents=True, exist_ok=True)
                if isinstance(content, bytes):
                    path.write_bytes(content)
                    require(path.read_bytes().startswith(b"\xef\xbb\xbfTYPESAFE_API_KEY="),
                            label + ": fixture starts with BOM bytes and an assignment")
                else:
                    path.write_text(content, encoding="utf-8")
                path.chmod(0o600)
        changes = {"HOME": str(keyHome), "TYPESAFE_API_KEY": envKey}
        state["key"] = expectedKey or fakeKey
        state["argvSeen"] = False
        count = len(state["requests"])
        stderr = run(label, ["noul", "Help requested?"], 0 if expectedKey else 3,
                     inputText="Please help.", changes=changes, watch=True, returnError=True)
        requests = state["requests"][count:]
        if expectedKey:
            require(len(requests) == 1 and requests[0][3].get("Authorization") == "Bearer " + expectedKey,
                    label + ": exactly one request with the expected credential")
            require(state["argvSeen"], label + ": process argv inspected during the request")
        else:
            require(not requests, label + ": no API request")
            require("TYPESAFE_API_KEY" in stderr, label + ": diagnostic names the variable")
        if first is None and second is None and envKey is None:
            for relativePath in relativePaths:
                require("~/" + relativePath in stderr, label + ": diagnostic names " + relativePath)

    # A directory guarantees a read OSError even when the checker runs as root.
    for unavailableIndex in (0, 1):
        keyHome = testHome / ("unreadable-source-" + str(unavailableIndex))
        unreadable = keyHome / relativePaths[unavailableIndex]
        unreadable.mkdir(parents=True)
        fallback = keyHome / relativePaths[1]
        if unavailableIndex == 0:
            fallback.parent.mkdir(parents=True)
            fallback.write_text(keyring, encoding="utf-8")
            fallback.chmod(0o600)
        state["key"] = keyringKey
        count = len(state["requests"])
        run("R8 unreadable source " + str(unavailableIndex), ["models"], 0 if unavailableIndex == 0 else 3,
            changes={"HOME": str(keyHome), "TYPESAFE_API_KEY": None})
        require(len(state["requests"]) == count + int(unavailableIndex == 0), "R8 unreadable source request count")

    # Echo the newly loaded key through both output paths to exercise redaction.
    changes = {"HOME": str(testHome / "key-source-0"), "TYPESAFE_API_KEY": None}
    state["key"] = keyringKey
    for status, expected, reply in ((200, 0, {"models": [{"name": keyringKey}]}),
                                    (422, 5, {"detail": "Invalid fixture field " + keyringKey})):
        state["responses"] = [{"status": status, "json": reply}]
        output = run("R8 keyring credential redaction " + str(status), ["models"], expected,
                     changes=changes, returnError=bool(expected))
        require("[REDACTED]" in output, "R8 keyring echo is redacted for HTTP " + str(status))
        require(not state["responses"], "R8 keyring echo response consumed")
        state["responses"] = []
    state["key"] = fakeKey

    for envKey in (None, "", fakeKey):
        label = "R9 unavailable home " + ("with environment key" if envKey else "without environment key")
        count = len(state["requests"])
        stderr = run(label, ["noul", "Help requested?"], 0 if envKey else 3, inputText="Please help.",
                     changes={"HOME": None, "TYPESAFE_API_KEY": envKey}, watch=True,
                     returnError=True, missingHome=True)
        requests = state["requests"][count:]
        if envKey:
            require(len(requests) == 1 and requests[0][3].get("Authorization") == "Bearer " + fakeKey,
                    label + ": environment still authenticates without a home directory")
        else:
            require(not requests, label + ": no API request")
            require("missing TYPESAFE_API_KEY" in stderr, label + ": missing credential diagnostic")
            for relativePath in relativePaths:
                require("~/" + relativePath in stderr, label + ": diagnostic names " + relativePath)


def checkErrorStreams():
    for mode in ("pipe", "merged pipe", "buffered pipe", "bad descriptor", "closed stream", "absent stream"):
        for code, status, args in ((2, None, []), (3, 401, ["models"]), (5, 422, ["models"])):
            label = "R5 stderr " + mode + " preserves exit " + str(code)
            direct = mode in ("pipe", "merged pipe")
            state["responses"] = [{"status": status, "json": {"detail": "Invalid fixture field"}}] if direct and status else []
            count = len(state["requests"])
            command = [cli] + args if direct else [sys.executable, "-c", errorStreamGuard, cli, mode, str(code)]
            writeFd = None
            if mode in ("pipe", "merged pipe", "buffered pipe"):
                readFd, writeFd = os.pipe()
                # Close before spawning: no race with a reader such as head -c 0.
                os.close(readFd)
            try:
                process = subprocess.Popen(command, stdin=subprocess.DEVNULL,
                                           stdout=writeFd if mode == "merged pipe" else subprocess.PIPE,
                                           stderr=writeFd if writeFd is not None else subprocess.PIPE, env=env)
            finally:
                if writeFd is not None:
                    os.close(writeFd)
            try:
                stdout, stderr = process.communicate(timeout=10)
            except subprocess.TimeoutExpired:
                process.kill()
                stdout, stderr = process.communicate()
                failures.append(label + ": subprocess deadline exceeded")
            require(process.returncode == code, label + ": got " + str(process.returncode))
            # Only inspect captured streams. A pipe with no reader cannot prove silence.
            if stdout is not None:
                require(stdout == b"", label + ": captured stdout is empty")
            if stderr is not None:
                require(stderr == b"", label + ": captured stderr has no stray output or traceback")
            require(len(state["requests"]) == count + int(direct and status is not None), label + ": expected request count")
            require(not state["responses"], label + ": error response consumed")


def checkRegressions(testHome, questions, server):
    checkErrorStreams()
    with http.server.HTTPServer(("127.0.0.1", 0), http.server.BaseHTTPRequestHandler) as proxy:
        proxy.proxyRequests = []
        proxyThread = threading.Thread(target=proxy.serve_forever, daemon=True)
        proxyThread.start()
        proxyUrl = "http://127.0.0.1:" + str(proxy.server_port)
        proxyEnv = {name: proxyUrl for name in ("http_proxy", "HTTP_PROXY", "https_proxy", "HTTPS_PROXY", "all_proxy", "ALL_PROXY")}
        proxyEnv.update({"no_proxy": "", "NO_PROXY": ""})
        try:
            # A known request proves that the proxy capture can see headers.
            connection = http.client.HTTPConnection("127.0.0.1", proxy.server_port, timeout=5)
            connection.request("GET", "http://fixture.invalid/v1/models", headers={"Authorization": "Bearer " + fakeKey})
            connection.getresponse().read()
            connection.close()
            require(len(proxy.proxyRequests) == 1 and proxy.proxyRequests[0][2].get("Authorization") == "Bearer " + fakeKey, "A1 proxy capture positive control")

            for index, host in enumerate(("fixture.invalid", "192.0.2.1", "localhost.fixture.invalid", "[::ffff:127.0.0.1]",
                                          "localhost", "LOCALHOST", "localhost.", "LOCALHOST.",
                                          "localhost..", "0.0.0.0", "[::]", "[::1%25lo]", "127.0.0.1.", "127.000.0.1")):
                auditPath = testHome / ("network-" + str(index))
                run("A1 reject named or non-loopback HTTP: " + host, ["models"], 2, changes={**proxyEnv, "JEV_API_BASE": "http://" + host + ":" + str(server.server_port)}, networkLog=auditPath)
                require(not auditPath.exists(), "A1 rejected HTTP performs no DNS or connection attempt: " + host)

            for index, host in enumerate(("127.2.3.4", "[::1]", "[0:0:0:0:0:0:0:1]")):
                auditPath = testHome / ("allowed-loopback-" + str(index))
                run("A1 accept loopback address", ["models"], 4, changes={"JEV_API_BASE": "http://" + host}, networkLog=auditPath)
                require(auditPath.exists(), "A1 loopback address passes validation and reaches the network guard: " + host)

            directCount, proxyCount = len(state["requests"]), len(proxy.proxyRequests)
            run("A1 literal loopback bypasses proxies", ["models"], changes=proxyEnv)
            require(len(proxy.proxyRequests) == proxyCount, "A1 literal loopback never sends Authorization to a proxy")
            require(len(state["requests"]) == directCount + 1, "A1 literal loopback reaches the origin directly")

            proxyCount = len(proxy.proxyRequests)
            run("A1 HTTPS retains proxy support", ["models"], 4, changes={**proxyEnv, "JEV_API_BASE": "https://fixture.invalid"})
            tunnels = proxy.proxyRequests[proxyCount:]
            require(len(tunnels) == 3 and all(method == "CONNECT" and "Authorization" not in headers for method, _, headers in tunnels),
                    "A1 HTTPS makes three CONNECT attempts without API credentials")
        finally:
            proxy.shutdown()
            proxyThread.join(timeout=5)
            require(not proxyThread.is_alive(), "proxy fixture stopped")

    message = "Ayúdame, por favor."
    run("A2 UTF-8 stdin under Latin-1 locale", ["noul", "Help requested?"], inputText=message.encode("utf-8"), changes={"PYTHONIOENCODING": "latin-1"})
    require(state["requests"][-1][1]["state"] == message, "A2 stdin preserves UTF-8 independently of locale")
    accentedQuestions = {"present": {"type": "noul", "instructions": "¿El mensaje pide ayuda?"}}
    run("A2 UTF-8 questions under Latin-1 locale", ["ask", "--questions", "-", "--state", "x"], inputText=json.dumps(accentedQuestions, ensure_ascii=False).encode("utf-8"), changes={"PYTHONIOENCODING": "latin-1"})
    require(state["requests"][-1][1]["questions"] == accentedQuestions, "A2 questions preserve UTF-8 independently of locale")
    badFile = testHome / "invalid-utf8"
    badFile.write_bytes(b"bad:\xff")
    for args, inputBytes in (
        (["noul", "Question?"], b"bad:\xff"),
        (["noul", "Question?", "--state-file", str(badFile)], None),
        (["ask", "--questions", "-", "--state", "x"], b'{"q":"\xff"}'),
        (["ask", "--questions", str(badFile), "--state", "x"], None),
    ):
        count = len(state["requests"])
        run("A2 reject invalid UTF-8", args, 2, inputText=inputBytes, changes={"PYTHONIOENCODING": "latin-1"})
        require(len(state["requests"]) == count, "A2 invalid UTF-8 never reaches API")

    bom = b"\xef\xbb\xbf"
    stateBytes = json.dumps({"message": message}, ensure_ascii=False).encode("utf-8")
    bomState = testHome / "bom-state.json"
    bomState.write_bytes(bom + stateBytes)
    for args, inputBytes in ((["noul", "Question?", "--state-file", str(bomState)], None), (["noul", "Question?"], bom + stateBytes)):
        run("A3 BOM state", args, inputText=inputBytes)
        require(state["requests"][-1][1]["state"] == {"message": message}, "A3 BOM state stays a JSON object")
    bomQuestions = testHome / "bom-questions.json"
    bomQuestions.write_bytes(bom + json.dumps(questions).encode("utf-8"))
    for source, inputBytes in ((str(bomQuestions), None), ("-", bomQuestions.read_bytes())):
        count = len(state["requests"])
        run("A3 BOM questions", ["ask", "--questions", source, "--state", "x"], inputText=inputBytes)
        require(len(state["requests"]) == count + 1 and state["requests"][-1][1]["questions"] == questions, "A3 BOM questions reach API as a question map")

    for size in (1, 128 * 1024):
        state["responses"] = [{"status": 200, "json": {"models": [{"name": "x" * size}]}}]
        count = len(state["requests"])
        readFd, writeFd = os.pipe()
        os.close(readFd)
        try:
            process = subprocess.Popen([cli, "models"], stdin=subprocess.DEVNULL, stdout=writeFd, stderr=subprocess.PIPE, env=env)
        finally:
            os.close(writeFd)
        try:
            _, stderr = process.communicate(timeout=10)
        except subprocess.TimeoutExpired:
            process.kill()
            _, stderr = process.communicate()
            failures.append("A4 closed pipe subprocess deadline exceeded")
        require(process.returncode == 0, "A4 closed pipe after success expected exit 0, got " + str(process.returncode) + " (bytes=" + str(size) + ")")
        require(stderr == b"", "A4 closed pipe is silent, including interpreter shutdown")
        require(len(state["requests"]) == count + 1, "A4 closed pipe does not repeat successful API call")

    for malformed in ('{"user":"a","user":"b"}', '[{"x":1,"x":2}]', '{"x":NaN}', '[Infinity]', '{"x":-Infinity}', '{"x":1e400}'):
        count = len(state["requests"])
        stderr = run("A5 defective structured state", ["noul", "Question?", "--state", malformed], 2, returnError=True)
        require(len(state["requests"]) == count, "A5 defective structured state never reaches API")
        require("--state-text" in stderr, "A5 defective state explains the explicit text override")
        run("A5 explicit state text", ["noul", "Question?", "--state", malformed, "--state-text"])
        require(state["requests"][-1][1]["state"] == malformed, "A5 explicit override preserves the original text")
    run("A5 non-JSON stays text", ["noul", "Question?", "--state", '{"unfinished":'])
    require(state["requests"][-1][1]["state"] == '{"unfinished":', "A5 non-JSON still falls back to text")


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

            expectedVersion = json.loads((repo / ".claude-plugin/plugin.json").read_text())["version"]
            require(run("version", ["--version"]).strip() == "jev " + expectedVersion, "CLI version")
            checkRegressions(testHome, questions, server)
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
            checkKeySources(testHome)

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
