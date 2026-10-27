# Find files and passages by meaning

Read this reference when locating files, configurations, comments, or passages
whose relevance depends on meaning rather than a literal filename or keyword.
Jev can power semantic search: use it to classify, rank, or select supplied
candidates. Do not dismiss this workflow because the task is called a lookup.

## Collect, judge, verify

1. Use `rg --files`, `rg`, a directory listing, or an existing index to gather
   candidates within the requested scope. Give each a stable ID, path, and a
   small relevant excerpt or metadata summary. Jev evaluates supplied state;
   filesystem tools enumerate and read files.
2. Ask semantic questions in one bounded `jev ask` batch. `choice` selects one
   candidate (include `none`); per-candidate `noul` checks membership when several
   files may match; per-candidate `score` can rank relevance using one shared
   rubric. Inferring a sentence's intent or topic can be a Choice among supplied
   meanings, not a request for Jev to generate a free-form summary.
3. Apply the control gates and uncertainty rules in [SKILL.md](../SKILL.md).
   Read original evidence for selected and uncertain candidates, and verify
   paths and relevant facts locally. A selected ID or high confidence does not
   prove freshness, credential validity, or permission to use a file.
4. If evidence is missing or uncertain, expand the candidate set or inspect more
   context. A `none` result means no match in the supplied candidates, not that
   no matching file exists on disk. Do not hide retrieval gaps as certainty.

For an exact known filename or literal variable name, use deterministic search
directly. Use Jev when interpretation helps, or when explicitly requested for
semantic selection. For millions of comments or a large tree, retrieve and batch
first; do not send the whole corpus in one request. Keep Choice sets within the
live API limit and use per-item questions when all matches are requested.

## Example: general-use versus project credentials

Use variable names, paths, and nearby documentation to identify the intended
scope. Keep key values, tokens, passwords, and credential-file bodies out of
Jev's state. Path alone is not proof of scope; include `unknown` or abstain when
the evidence does not establish it. Verify locally before using a credential.
The following is synthetic metadata, not an account inventory.

`search-state.json`:

```json
{
  "candidates": {
    "a": {"path": "config/provider/keyring.env", "note": "Shared operator credential for tasks outside application projects; values omitted."},
    "b": {"path": "apps/demo/.env", "note": "Credential restricted to the demo application; values omitted."}
  },
  "controls": {
    "positive": "Shared operator credential explicitly for tasks outside projects.",
    "negative": "Credential explicitly restricted to one application project."
  }
}
```

`search-questions.json` uses the same Noul template for candidates and controls:

```json
{
  "a": {"type": "noul", "instructions": "Does candidates.a explicitly describe a credential intended for operator tasks outside application projects?"},
  "b": {"type": "noul", "instructions": "Does candidates.b explicitly describe a credential intended for operator tasks outside application projects?"},
  "positive": {"type": "noul", "instructions": "Does controls.positive explicitly describe a credential intended for operator tasks outside application projects?"},
  "negative": {"type": "noul", "instructions": "Does controls.negative explicitly describe a credential intended for operator tasks outside application projects?"}
}
```

```bash
jev ask --questions search-questions.json --state-file search-state.json
```

Require positive `> 0.8` and negative `< 0.2` before interpreting the candidates;
otherwise inspect the evidence directly. Apply the entrypoint's flag and
uncertainty bands, then inspect original metadata for both flagged and uncertain
items. These controls are a smoke test, not calibration or a credential policy.
Keep expected labels out of the request. General versus project use comes from
the operator's instructions and actual evidence, not a model's authorization.

## Official examples

- [Line-by-line semantic search](https://docs.typesafe.ai/cookbooks/semantic_find.md):
  Choice ranks supplied line IDs; Noul separately checks whether an answer exists.
- [Re-ranking](https://docs.typesafe.ai/cookbooks/rerank_typesafe.md):
  rank a retrieved shortlist against a query.
- [Hierarchical classification](https://docs.typesafe.ai/cookbooks/hierarchical_classification.md):
  navigate supplied categories in stages rather than generating category names.
