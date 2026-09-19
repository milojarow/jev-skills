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

Credential lookup: nonempty `TYPESAFE_API_KEY` environment value, then an exact
`TYPESAFE_API_KEY=` assignment in `~/.secrets/environment.d/11-secrets.conf`.
Surrounding single/double quotes are supported. The file is read as data: no shell
evaluation, interpolation, or sourcing. A supplied invalid environment credential
does not trigger a second attempt with the file credential.

Never place a real credential in command arguments or in a generated file.
Inherit it from the existing environment or let the CLI read its existing location.

`JEV_API_BASE` defaults to `https://api.typesafe.ai`. The CLI appends `/v1/models`
or `/v1/systemone`; do not include those paths in the base. An override selects
where the authenticated request goes, so use a dummy key for local fake servers.
HTTPS is required except for literal IPv4 loopback addresses in `127.0.0.0/8`,
IPv6 `::1`, and `localhost`. Other HTTP hosts exit with 2 before any DNS lookup
or connection attempt. Loopback destinations bypass all environment proxies,
for both HTTP and HTTPS. Non-loopback HTTPS can use environment proxies; the
API authorization header remains inside TLS. HTTP redirects are rejected.

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

## Exit codes

| Exit | Meaning | Next step |
| --- | --- | --- |
| 0 | Successful output | Interpret values and confidence under tested rules. |
| 2 | Invalid command or input | Correct the source, JSON map, criteria, or flags. |
| 3 | Missing credential or HTTP 401/403 | Check that `TYPESAFE_API_KEY` is present; never display it. |
| 4 | API/network/limit failure, invalid response, or interrupted operation | Inspect service availability and retry policy; retain work for retry/review. |
| 5 | API validation error, HTTP 422 | Check the current API schema against the supplied state/questions. |

Errors occupy one stderr line. HTTP 422 includes the API's validation detail
(JSON `detail`/`message`, or text), with the credential redacted, nonprintable
characters removed or replaced, and whitespace normalized. The entire stderr
line is capped at 500 characters before its terminating newline. Redaction
precedes truncation. Reading the detail is bounded to 64 KiB and the attempt's
deadline; an unreadable body still exits with 5 and identifies HTTP 422.
Other HTTP errors suppress remote bodies. No diagnostic includes an authorization
header or exception traceback. Do not reinterpret an error as a negative answer,
an empty batch, or authorization to skip review.
