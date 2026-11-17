# Models, request limits and client capabilities

Read this when selecting a model, sizing batches or using long context. The
following capabilities come from the official documentation snapshot dated
2026-11-17; confirm the target service and installed SDK before production use.

## Model and interface are separate

| Capability | Bundled `jev` CLI | Official SDK / HTTP API |
| --- | --- | --- |
| Text Choice, Noul, Score | Supported | Supported |
| Image assets | Not exposed | Experimental, images header required |
| Box questions | Not exposed | Experimental, Jev 1.14 and images header required |
| Long context opt-in | No header flag | Explicit per-request header |
| Persistent application connection | New connection per invocation | Reuse a client |

The snapshot lists `jev-1.14.0` and `jev-1.13.0`. Both accept text and gated image
inputs; Box needs 1.14. It reports improved multilingual support in 1.14, not a
validation of any particular Spanish dialect, domain or question template.

The CLI default stays `jev-latest`. The snapshot maps `jev-latest` and
`jev-preview` to 1.14.0, but aliases move. Pin the model ID used for calibration,
retain resolved `model` with results, and re-evaluate before adopting another
version. CLI/package version and model version identify different things.
`GET /v1/models` may list aliases without every accepted versioned model ID.

## Context and byte limits

Two token budgets apply to each request:

- **Per request:** state plus all questions combined; default 64k tokens.
- **Per question:** state plus any one question; default 32k tokens.

The documented long-context opt-in is
`TypeSafe-Danger-Zone-Long-Context: true`. It raises **both** budgets to 262k tokens
for that request on 1.13 or 1.14. Enable it deliberately when needed, after
considering retrieval, cost and accuracy. It does not remove the HTTP body limit
or prove that long, noisy state retains task accuracy. The CLI has no flag for
this header; configure it on the existing SDK/HTTP request instead.

The API has no separate question-count limit when both token budgets fit. Byte
length, character count and token count are different measures. For images, also
account for [asset expansion](images-and-box.md#prepare-assets-and-count-expansion).

HTTP requests have a 32 MiB body limit. JSON is UTF-8 without BOM, nesting is at
most 64 levels in state/instructions/criteria, and numbers must be finite. Use
strings for identifiers and exact large quantities. Compression does not raise
the body limit; the documented gzip/zstd rules apply to compressed and decompressed
size. The CLI's text input accepts a leading BOM by removing it locally; that
does not mean a raw API JSON body may contain one.

## Failure and retry decisions

Keep the existing client's behavior explicit. `400`/`413`/`415`/`422` identify
request or contract problems; correct the input rather than treating an error as
a negative judgment. `401`/`403` concern authentication/authorization and do not
justify changing to an unrelated credential. Never echo a credential to debug.

The service documents backoff for `429` and `529`, with SDK handling by default.
Honor retry headers and a bounded operation budget. The bundled CLI has its own
three-attempt policy for 429/all 5xx/network failures, preserved in the
[CLI contract](cli.md#credentials-and-transport). This is not an instruction to
replay an application effect when an evaluation request or its response is lost.

Sources: [Models](https://docs.typesafe.ai/models.md),
[Model changelog](https://docs.typesafe.ai/changelog.md),
[Request rules and errors](https://docs.typesafe.ai/api/errors.md),
[Images](https://docs.typesafe.ai/images.md) and
[Model jaggedness](https://docs.typesafe.ai/model-jaggedness.md).
