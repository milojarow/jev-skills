# Find the source that matches the decision

Use the relevant official page and section, not the whole manual. This skill was
updated against the 2026-11-17 Markdown snapshot. Resolve a local corpus or RAG
through the environment's binding when available; otherwise use the official
source within the task's browsing constraints. State the snapshot and leave
unverified version-sensitive behavior explicit. A new librarian is not required
to use these references, and this skill does not provision a RAG.

| Need | Official pages |
| --- | --- |
| State, atomic questions and structured criteria | [State](https://docs.typesafe.ai/concepts/state.md), [Primitives](https://docs.typesafe.ai/primitives.md), [Advanced structure](https://docs.typesafe.ai/primitives/advanced.md) |
| Image inputs and localization | [Images](https://docs.typesafe.ai/images.md), [Box](https://docs.typesafe.ai/primitives/box.md) |
| Models, limits, opt-in headers and failures | [Models](https://docs.typesafe.ai/models.md), [Request rules and errors](https://docs.typesafe.ai/api/errors.md), [System One API](https://docs.typesafe.ai/api/system-one.md) |
| Uncertainty and applicability | [Confidence](https://docs.typesafe.ai/confidence.md), [Companion Noul](https://docs.typesafe.ai/patterns/companion-noul.md), [Probability routing](https://docs.typesafe.ai/patterns/probability-routing.md) |
| One batch versus a preliminary screen | [Speculative fan-out](https://docs.typesafe.ai/patterns/fan-out.md), [Noul screen](https://docs.typesafe.ai/patterns/noul-screen.md) |
| Candidate passages, citations and extraction | [RAG passages](https://docs.typesafe.ai/cookbooks/classifying_rag_passages.md), [Citation checking](https://docs.typesafe.ai/cookbooks/citation_check.md), [Value selection](https://docs.typesafe.ai/cookbooks/pre_parsed_value_extraction_cookbook.md) |
| Categories or skills from a large catalog | [Hierarchical classification](https://docs.typesafe.ai/cookbooks/hierarchical_classification.md), [Skill suggestion](https://docs.typesafe.ai/cookbooks/skill_suggestion.md) |
| Integration in the application's chosen stack | [Python SDK](https://docs.typesafe.ai/sdk/python.md), [JavaScript SDK](https://docs.typesafe.ai/sdk/javascript.md) |
| Literal reading, numeric precision and other known limitations | [Model jaggedness](https://docs.typesafe.ai/model-jaggedness.md) |

In a page-organized local copy, find a URL's path under `pages/` with a `.md`
suffix, for example `pages/primitives/box.md`. Retrieve by page title and relevant
section when using a RAG, retain the source, and inspect originals for material
decisions. Do not transfer corpus content or private records to a service merely
because that service is installed.
