# Canonical quick review: items and controls

Use this example for a new bounded text-judgment template. Apply the control gates
and source-reading rules in [SKILL.md](../SKILL.md#when-the-operator-asks-for-something-quick).
The controls are a smoke test, not calibration for a domain or language.

Example `review-state.json`: two items and two agent-written controls. Keep the
expected labels outside both JSON files: `c1` is positive; `c2` is negative.

```json
{
  "items": {"a": "The service failed again and I am unhappy.", "b": "Everything works. Thanks."},
  "controls": {"c1": "I am dissatisfied with the service.", "c2": "I am happy with the service."}
}
```

`review-questions.json` repeats one template with exact field references:

```json
{
  "a": {"type": "noul", "instructions": "Does items.a explicitly express dissatisfaction with the service?"},
  "b": {"type": "noul", "instructions": "Does items.b explicitly express dissatisfaction with the service?"},
  "c1": {"type": "noul", "instructions": "Does controls.c1 explicitly express dissatisfaction with the service?"},
  "c2": {"type": "noul", "instructions": "Does controls.c2 explicitly express dissatisfaction with the service?"}
}
```

```bash
jev ask --questions review-questions.json --state-file review-state.json
```

The output is an answers map. First require `c1.noul > 0.8` and `c2.noul < 0.2`;
otherwise read directly and report failed controls. Then apply the bands and source
reading rule to `a` and `b`; report their IDs/values, excluding the control IDs.

For fifteen items and one criterion, instantiate fifteen item questions plus the
two controls. A question asking whether *any* item qualifies does not identify
which ones do. Read every flagged and uncertain original; unflagged does not mean
verified clean. If the batch exceeds the request limits, split it into bounded
batches with the necessary controls and preserve coverage of every item.

For generation, exact lookup, arithmetic or ordinary debugging, do that work
directly. Quick wording alone does not justify inventing a semantic judgment.
