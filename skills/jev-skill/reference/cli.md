# CLI contract

Requires Python 3 with its standard library on a POSIX system. The attempt deadline
uses POSIX signals. The executable has no child processes and requires no pip
packages, jq, or curl.

## Commands

```text
jev ask --questions FILE|- [--state TEXT | --state-file FILE]
        [--state-text] [--model M] [--full]
jev noul INSTRUCTIONS [--true TEXT] [--false TEXT]
         [--state TEXT | --state-file FILE] [--state-text]
         [--model M] [--full | -p | --plain]
jev choice INSTRUCTIONS -o KEY=DESCRIPTION [-o KEY=DESCRIPTION ...]
           [--state TEXT | --state-file FILE] [--state-text]
           [--model M] [--full | -p | --plain]
jev score INSTRUCTIONS -l LEVEL [-l LEVEL ...]
          [--state TEXT | --state-file FILE] [--state-text]
          [--model M] [--full | -p | --plain]
jev models
jev --version
```

Without an explicit state option, read UTF-8 state from stdin. `--state-file -`
also means stdin. Files and stdin are read as bytes and decoded with `utf-8-sig`:
an initial UTF-8 BOM is removed, and invalid UTF-8 exits with 2. This applies to
both state and questions, regardless of locale or `PYTHONIOENCODING`. Other text,
including line endings, is preserved. A terminal without piped input requires
an explicit source.
For third-party content, use `jev ... < message.txt` or `--state-file message.txt`.
The text stays out of process arguments and shell interpolation. Inline `--state`
is only for short text the agent wrote itself, never for third-party content.
`--questions -` consumes stdin, so it requires `--state` or a named state file;
two inputs cannot share an undelimited stream. `--state-text` forces the original
text through unchanged. State source options are mutually exclusive.

Valid JSON objects and arrays become structured state. All other input remains
the original string, including numbers, booleans, `null`, quoted JSON strings,
and malformed JSON. For example, `--state '42'` sends the string `42`, and
`--state '"hello"'` preserves the quote characters. Use `--state 'hello'` to send
unquoted text. This follows the API's string/object/array state contract.

An object/array with duplicate keys or non-finite numbers (`NaN`, `Infinity`,
or a number overflowing the decoder) exits with 2 instead of silently becoming
text. The diagnostic names `--state-text` as the explicit override. Input that
cannot be parsed as an object/array even by the permissive JSON decoder still
falls back to text. `--state-text` skips JSON decoding, but not UTF-8 validation.

Questions are a nonempty JSON **map**, not a list and not an envelope containing
`state`, `model`, and `questions`. Preserve the IDs you need in the answer map.
Duplicate JSON keys are rejected to avoid silently dropping a question.
The simple commands use the internal ID `answer`, visible only with `--full`.
Choice keys must be nonempty and unique; split options at the first `=`.
Score takes 2–10 ordered levels. For structured instructions/criteria, use `ask`
and the shapes documented in the live advanced-structure reference.

### Single-question examples for already tested templates

Use these shortcuts only after the template has passed positive/negative controls.
For a new template, use the [canonical quick-review example](../SKILL.md#canonical-quick-review-items-and-controls-in-one-call)
to send item questions and agent-written controls in one `jev ask` call.

```bash
jev choice 'Which team handles the primary request?' \
  -o 'support=Help with an existing service' \
  -o 'sales=Information before purchasing' \
  -o 'none=None of these applies' --state-file message.txt

jev score 'How much does the reported issue block use?' \
  -l 'Cosmetic issue; all functions work' \
  -l 'A function fails; a workaround is stated' \
  -l 'The service is unusable; no workaround is stated' --state-file message.txt
```

## Output

- `ask`: compact `answers` JSON map.
- `noul`, `choice`, `score`: compact JSON of that one answer, including its type
  and all returned answer fields.
- `--full`: complete response, including resolved `model` and `usage`.
- `-p/--plain`: noul probability, unquoted choice key, or fractional score plus
  one newline. Available on single-question commands; incompatible with `--full`.
- `models`: compact JSON model listing (`{"models":[...]}`) from `GET /v1/models`.

The default requested model is `jev-latest`. Model listing may contain aliases
without every accepted version ID; consult the model docs when pinning a version.
The CLI validates response types before returning success. An invalid answer
diagnostic identifies the caller's question ID and failed field, without echoing
the remote field value. Caller IDs are sanitized and credential-redacted too.
Successful responses redact the loaded credential if it is echoed.
If a stdout consumer closes the pipe after a successful evaluation, the CLI
discards remaining output and exits with 0 without stderr, including during
interpreter shutdown. A closed reader does not turn success into an API failure.

## Credentials and transport

Credential lookup uses the first nonempty `TYPESAFE_API_KEY`, in this order:
environment, `~/.secrets/environment.d/11-secrets.conf`, then
`~/.config/typesafe/keyring.env`. Absent or unreadable files, files without the
variable, and files whose final assignment is empty are skipped.
Both files use the same parser: `TYPESAFE_API_KEY=` assignments may have an
`export ` prefix and surrounding single/double quotes; the last assignment wins
within each file. Full-line comments beginning with `#` are ignored. Files are
read as data: no shell evaluation, interpolation, or sourcing.
A nonempty value must contain only printable ASCII characters without spaces.
An invalid nonempty value or an API authentication rejection does not cause a
retry with a lower-priority credential. Missing credentials exit with 3 and name
the variable and both fallback paths, never credential values.

Never place a real credential in command arguments or in a generated file.
Inherit it from the existing environment or let the CLI read its existing location.

`JEV_API_BASE` defaults to `https://api.typesafe.ai`. The CLI appends `/v1/models`
or `/v1/systemone`; do not include those paths in the base. An override selects
where the authenticated request goes, so use a dummy key for local fake servers.
For HTTP, only literal loopback IP addresses are accepted:

- IPv4 literals in `127.0.0.0/8`, in four-part decimal notation without leading
  zeros or a trailing dot (for example, `127.0.0.1` or `127.2.3.4`).
- Bracketed IPv6 literals equal to `::1`, in any valid representation, without a
  zone identifier (for example, `[::1]` or `[0:0:0:0:0:0:0:1]`).

Every hostname requires HTTPS, including `localhost`, `localhost.`, and their
case variants; their eventual DNS/NSS resolution does not grant an HTTP exception.
Other rejected HTTP forms include scoped IPv6 such as `[::1%25lo]`, unspecified
addresses `0.0.0.0` and `[::]`, and IPv4-mapped IPv6 such as `[::ffff:127.0.0.1]`.
They exit with 2 before any DNS lookup or connection attempt. Literal loopback IPs
bypass all environment proxies, for both HTTP and HTTPS. Other HTTPS destinations
can use environment proxies; the API authorization header remains inside TLS.
HTTP redirects are rejected.

Each attempt has a 30-second deadline, including connecting and reading the body.
HTTP 429, all 5xx (including 529), and network failures retry up to **three total
attempts**. Backoff waits 1 second, then 2; a valid `Retry-After` number or HTTP
date can extend either wait. Invalid/past headers do not remove the backoff.
Each wait is limited to 30 seconds. If a retryable response requests a longer
wait, the CLI immediately exits with 4 and reports the requested seconds and
the limit; it does not sleep or silently retry earlier than requested.

A POST that times out while reading may already have been evaluated and billed.
Retrying a network failure can therefore cause up to three evaluations and
charges for one CLI invocation. The evaluation has no application-side effects,
but these retries do not provide exactly-once billing. The returned response is
from the attempt that completed successfully; earlier attempts may have completed
at the service even though their responses did not reach the CLI.

## Latency and persistent clients

Reuse **one persistent HTTP client** (keep-alive, with HTTP/2 when supported) for
software that makes repeated decisions. Send the operation and all speculative
target heads in one request per cycle, keep only visible/relevant state, and cap
recent history. See the [indexed action-loop pattern](use-cases.md#run-an-agent-loop-over-indexed-actions).

Measurements supplied by the director on 2026-09-19 used the same machine and
question against the real API:

| HTTPS connection | Median | Range | Sample |
| --- | --- | --- | --- |
| New connection per call | 484 ms | 414–780 ms | n=5 |
| Reused connection | 209 ms | 174–232 ms | n=8 |

The gap points to connection establishment as the dominant avoidable cost in
these measurements, rather than model work. These are client-observed timings,
not isolated inference measurements or a latency guarantee; measure your workload.

The public [performance report](https://github.com/browser-use/jev-ultrafast/blob/1231850a0b/docs/performance.md)
records a 178 ms median per Jev request and 17 requests in a 7.073 s task (about
7.1 s). Its [model client](https://github.com/browser-use/jev-ultrafast/blob/1231850a0b/jev_ultrafast/model.py)
reuses an HTTP/2-enabled client. The task timing includes text generation, browser
work, stale decisions, and loading waits; it excludes browser setup, initial
navigation/observation, and fresh independent post-run verification. This is
project-reported evidence on a narrow task, not a benchmark rerun for this skill.

For this low-latency software policy, retry decision requests briefly and with
bounded backoff **only on 429/529/503**. Honor `Retry-After`; if it exceeds the loop's
remaining wait budget, stop/escalate rather than retry early. Count attempts and
text-helper calls in the request budget. Transport failure or an uncertain mutation
must not replay a browser, CLI, or workflow action. The example uses fixed 0.5/1 s
backoff and omits `Retry-After`; follow [TypeSafe's documented guidance](https://docs.typesafe.ai/models.md)
for that header instead of copying the omission.

The bundled `jev` CLI is single-shot: separate invocations create fresh connections
and each pays connection setup. Combine an agent's shell judgments into **one
`jev ask`**, and use a persistent client in application code for a low-latency loop.
The loop policy above does not change the CLI's existing three-attempt retry policy
for 429/all 5xx/network errors, documented under Credentials and transport.

## Exit codes

| Exit | Meaning | Next step |
| --- | --- | --- |
| 0 | Successful output | Interpret values and confidence under tested rules. |
| 2 | Invalid command or input | Correct the source, JSON map, criteria, or flags. |
| 3 | Missing credential or HTTP 401/403 | Check that `TYPESAFE_API_KEY` is present; never display it. |
| 4 | API/network/limit failure, invalid response, or interrupted operation | Inspect service availability and retry policy; retain work for retry/review. |
| 5 | API validation error, HTTP 422 | Check the current API schema against the supplied state/questions. |

Errors occupy one stderr line when the stream is writable. A closed pipe reader,
invalid stderr descriptor, or closed stderr stream suppresses the diagnostic but
preserves the selected error exit code, without a traceback or shutdown error.
HTTP 422 includes the API's validation detail
(JSON `detail`/`message`, or text), with the credential redacted, nonprintable
characters removed or replaced, and whitespace normalized. The entire stderr
line is capped at 500 characters before its terminating newline. Redaction
precedes truncation. Reading the detail is bounded to 64 KiB and the attempt's
deadline; an unreadable body still exits with 5 and identifies HTTP 422.
Other HTTP errors suppress remote bodies. No diagnostic includes an authorization
header or exception traceback. Do not reinterpret an error as a negative answer,
an empty batch, or authorization to skip review.
