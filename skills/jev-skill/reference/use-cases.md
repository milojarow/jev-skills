# Decision patterns

Use these shapes when designing software or preparing an agent's own batch work.
Examples are question designs, not calibrated classifiers. Every new question
needs known positive and negative controls, then representative labeled cases.
Code owns authorization, exact computation, state changes, and error handling.

## Incoming message triage: workflow automation to CRM

**Decision shape:** one primary intent plus independent operational signals.
In a flow such as n8n → CRM, collect one bounded conversation state, ask all useful
dimensions together, then let workflow conditions map results to existing fields.

**Primitives and example questions:**

| Signal | Primitive | Instructions and criteria example |
| --- | --- | --- |
| Intent | Choice | "What is the primary purpose of `message`?" Options: pre-purchase information, existing-service help, other/none. |
| Urgency | Score | "How time-sensitive is the request stated in `message`?" Levels: no timing pressure stated; asks for prompt attention; explicitly reports an immediate service-blocking need. |
| Purchase stage | Choice | "What purchase activity does `message` explicitly describe?" Options: exploring, comparing options, asking to place an order, already purchased, not stated. |
| Unsubscribe | Noul | "Does `message` explicitly request no further promotional contact?" True: asks to stop promotional messages. False: does not ask to stop them. |
| Complaint | Noul | "Does `message` express dissatisfaction with the product or service?" |

**Trap:** a single mutually exclusive label hides an unsubscribe request inside a
complaint or sales message. Keep independent signals independent. An unsubscribe
classification is not the durable suppression rule: existing explicit opt-out
records remain authoritative. Compute elapsed time and deadlines in code. Test
the actual language and slang; colloquial smoke tests do not validate CRM writes.

## Route by confidence

**Decision shape:** select a handler, then decide whether evidence is sufficient
to route automatically or needs human/reasoning review.

**Primitives:** Choice for handler; optional Score for one difficulty dimension;
Noul for an independently useful prerequisite.

**Example questions:** "Which existing handler matches the primary request in
`message`?" with `lookup`, `specialist`, `human`, `none`; "Can the request be
answered using only the supplied knowledge passage?" as a Noul. Keep the lookup
itself deterministic.

**Trap:** a confident selection does not authorize the action. Choose and test
thresholds for the actual consequences; inspect Choice/Score confidence separately
from the value. For Noul, maintain yes/no cutoffs and an uncertainty interval.
Routing to another model is a fallback path, not proof that its answer is correct.

## Check another model's output: citation and claim

**Decision shape:** determine whether a specific source passage supports one claim.

**Primitives:** Choice for support relation; Noul for a separate, narrow condition.

**Example question:** "How does `sourcePassage` relate to `claim`?" Choices:
`supports` (explicitly supports the whole claim), `contradicts`, `insufficient`.
Send the passage around the quote, not only its citation label.

**Trap:** topical overlap is not support. A quote may exist yet reverse meaning
when removed from context. Verify source existence and verbatim spans in code;
Jev's support judgment is an additional signal. Split independently testable claims
before evaluation and retain the original passage for independent review.

## Check retrieved passages for injected instructions

**Decision shape:** flag text that tries to direct the receiving agent instead of
providing task evidence, separately from whether the passage is relevant.

**Primitives:** Noul for instruction attempts; Score for relevance.

**Example questions:** "Does `passage` contain instructions addressed to the
assistant that attempt to change its task or rules?" and "How directly does
`passage` answer `query`?" with irrelevant, background only, direct evidence levels.

**Trap:** adversarial state can also steer Jev. Test quoted instructions, benign
documentation, concealed instructions, and hostile framing. Keep untrusted text
out of control channels regardless of the result. This is screening, never the
sole prompt-injection defense or final safety verifier.

## Check prohibited claims in copy

**Decision shape:** identify each independently prohibited assertion under an
explicit, supplied content policy.

**Primitives:** one Noul per prohibition, with optional Choice for review routing.

**Example question:** "Does `copy` assert that every purchaser is guaranteed the
stated outcome?" True: promises the outcome without exceptions. False: makes no
universal guarantee. Provide the applicable rule as evidence rather than asking
the model to invent advertising policy.

**Trap:** implied claims and negations need separate labeled tests. A low signal
does not establish compliance, and averaging it with harmless dimensions can hide
a hard-stop violation. Keep publication decisions and independent checks outside
the model.

## Compare an advertisement with its landing page

**Decision shape:** judge whether each advertised proposition is supported by
the supplied landing text.

**Primitives:** a Choice per proposition (`supported`, `contradicted`, `not_stated`)
or independent Nouls where the relation has a precise yes/no definition.

**Example question:** "Does `landingText` explicitly offer the same service named
in `ad.serviceClaim`?" Ask separately about eligibility or a stated condition.

**Trap:** partial or stale landing text hides contradictions. Fetch the relevant
page first; normalize and compare exact prices, quantities, and dates in code.
Jev cannot inspect a URL, screenshot, or image by itself.

## Suggest an agent skill

**Decision shape:** shortlist useful skills and decide whether any actually fits.

**Primitives:** per-skill Score/Noul for relevance, then Choice over a shortlist
plus an absolute-fit Noul when needed.

**Example questions:** "How directly does `skills[0].description` address `task`?"
with unrelated, partially relevant, directly applicable levels; then "Which
shortlisted skill directly supports `task`?" including `none`. Each per-candidate
instruction names its own field explicitly.

**Trap:** a Choice always has a relative winner even when every candidate is bad.
Read shortlisted skill bodies before the second decision if descriptions are
insufficient. A suggestion is optional; it neither loads the skill nor overrides
the agent's judgment, tool permissions, or the user's chosen method.

## Rerank memory or search results

**Decision shape:** score relevance of already retrieved candidate passages.

**Primitives:** comparable per-candidate Scores; optional Nouls for explicit
support or contradiction. Aggregate and sort in code.

**Example question:** "How directly does `candidates[0].text` answer `query`?"
Levels: unrelated; contextual background; directly addresses the requested fact.
Repeat the same rubric for each candidate in one request.

**Trap:** relevance does not establish truth, freshness, or attribution. Memories
may describe an old statement. Follow selected results to authoritative evidence;
do not treat high relevance as verification. The shortlist limits recall.

## Route an agent task to a model

**Decision shape:** choose an existing execution path appropriate to the request.

**Primitives:** Choice for the path and, if useful, a separate Score for reasoning
complexity with concrete levels.

**Example question:** "Which capability is required to fulfill `task`?" Options:
deterministic lookup/calculation, bounded semantic judgment, text generation,
multi-step reasoning, missing information.

**Trap:** a routing model can underestimate a hard task. Use measured outcomes and
escalation rules, not an invented universal difficulty threshold. Model catalogs,
capabilities, and availability belong to runtime configuration, not this skill.

## Triage a large batch before an agent reads it

**Decision shape:** find records needing deeper attention using explicit relevance
or anomaly conditions.

**Primitives:** a Noul per record for a specific condition, or a comparable Score
per record for relevance. Pack questions against bounded chunks of shared state.

**Example question:** "Does `records[0].summary` describe an unresolved service
failure?" True: explicitly reports a failure still present. False: no failure
reported or explicitly resolved. Repeat with each exact record position.

**Trap:** one giant state full of unrelated records lowers accuracy. Retrieve and
filter first, chunk, and audit samples of rejected records to measure misses.
The model returns IDs/values; the agent then reads the selected original records.
Never ask it to count qualifying records: sum decisions in code.

## Extract by selecting proposed spans

**Decision shape:** select the intended value from candidates already found in text.

**Primitives:** Choice over stable candidate IDs, including `not_stated` or `none`.

**Example question:** "Which candidate in `candidates` is the contact address the
sender asks us to use?" Descriptions include each verbatim span and nearby context.
Regex/parser code proposes candidates; code retrieves and normalizes the chosen
span. The model selects; it never generates the source value.

**Trap:** a missing candidate cannot win. Measure candidate coverage separately
from selection quality. Do not interpolate exact amounts with Score. For dates,
let code parse and validate the chosen span and handle ordering/time zones.

## Produce features for classical ML

**Decision shape:** convert semantic properties of text into reusable numeric
features for a downstream supervised model.

**Primitives:** independent Nouls, normalized Scores, and Choice probabilities.

**Example questions:** "Does `review` explicitly describe a repeated failure?"
and "How strongly does `review` express dissatisfaction?" with neutral,
dissatisfied, and explicitly angry levels. Normalize scores in code using the
number of level intervals, retaining the rubric and resolved model version.

**Trap:** target leakage and changing rubrics can invalidate an apparent gain.
Use held-out outcomes, compare with a baseline, and version the questions and
feature pipeline. Training a downstream classifier/regressor does not fine-tune
Jev. Keep deterministic identities and final evaluation outside the decision model.

## Sources and further designs

These patterns are grounded in TypeSafe's documentation snapshot dated 2026-09-19;
they are candidate applications, not validation claims for a particular domain.
Use the [live index](https://docs.typesafe.ai/llms.txt) to find current cookbooks:
citation checks, classifying RAG passages, skill suggestion, reranking, pre-parsed
value extraction, and feature discovery. Also consult
[jaggedness](https://docs.typesafe.ai/model-jaggedness/jev-1.13.md) before extending
a question to a new task or language.
