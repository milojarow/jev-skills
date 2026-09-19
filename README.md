# jev-skills

A shared agent skill and a Python standard-library CLI for bounded semantic
decisions with TypeSafe's Jev model.

Repository: [jev-skills](https://github.com/milojarow/jev-skills).

## What is this?

`jev` sends state and typed questions to TypeSafe and prints compact JSON or one
scalar. The skill teaches agents when to use that decision step in software and
when to use it directly from the shell during their own work.

It covers the boundaries that matter: atomic questions, batching, none-applicable
outcomes, confidence versus value, calibration, adversarial input, and exact work
that belongs in code. The examples are generic and contain no account inventory.

| Skill | Purpose |
| --- | --- |
| [jev-skill](skills/jev-skill/SKILL.md) | Typed semantic decisions for application builders and shell users. |

See [decision use cases](skills/jev-skill/reference/use-cases.md) and the
[CLI contract](skills/jev-skill/reference/cli.md).

## Requirements

- Python 3 and its standard library on POSIX; the offline checker additionally
  requires Linux `/proc` to inspect process arguments.
- Each machine's own TypeSafe credential, already in `TYPESAFE_API_KEY` or its
  existing assignment in `~/.secrets/environment.d/11-secrets.conf`. Each user
  keeps that credential locally; installation does not copy credentials.
- Network access for live calls. The offline checker uses a local fake server and
  generated dummy credentials.

No pip packages, jq, or curl are needed. No credential belongs in an argv, a repo,
or a generated file. Neither the CLI nor the installer provisions a credential.

## Try the bundled executable

Use an existing UTF-8 `message.txt` for the last command; third-party text belongs
in a file or stdin, not inline shell arguments. That single-question shortcut
requires an already tested template. For a new template, follow the
[canonical quick review](skills/jev-skill/SKILL.md#canonical-quick-review-items-and-controls-in-one-call)
with agent-written controls in the same batch.

```bash
skills/jev-skill/bin/jev --version
skills/jev-skill/bin/jev models
skills/jev-skill/bin/jev noul 'Does this request no more promotional contact?' -p < message.txt
```

The model default is `jev-latest`; pin a tested model ID when using calibrated
thresholds. `--full` exposes the resolved model and usage. `jev --version` reports
the CLI's version, separately from the model.

## Install after review

Use the same steps on each Linux machine, under the account that runs the agents.
Install the GitHub marketplace and plugin for Claude Code:

```bash
claude plugin marketplace add milojarow/jev-skills
claude plugin install jev-skills@jev-skills
```

Claude manages the clone at `~/.claude/plugins/marketplaces/jev-skills`.
Use its `skills/jev-skill` directory as the shared canonical source for Codex,
Grok, and the CLI. Resolve it before passing it to `tools/install-local.sh`:

```bash
repoRoot="$HOME/.claude/plugins/marketplaces/jev-skills"
skillDir=$(CDPATH= cd -- "$repoRoot/skills/jev-skill" && pwd -P)
"$repoRoot/tools/install-local.sh" "$skillDir"
"$repoRoot/tools/install-local.sh" --check "$skillDir"
```

The installer creates these links:

| Destination | Target |
| --- | --- |
| `~/.codex/skills/jev-skill` | Selected skill directory |
| `~/.agents/skills/jev-skill` | Selected skill directory |
| `~/.local/bin/jev` | Selected skill directory's `bin/jev` |

It preflights all destinations. Existing correct symlinks are reused; any file,
directory, or different symlink stops the operation before creation. `--check`
only inspects and fails if any link is missing or wrong. Put `~/.local/bin` on
PATH through the normal shell setup if it is not already present.

Grok follows the skill symlink in `~/.agents/skills`; Codex uses
`~/.codex/skills`; Claude uses the installed plugin. Verify on each machine:

```bash
jev models
grok inspect --json
codex debug prompt-input "x"
```

`jev models` must succeed with that machine's credential. The Grok report and
Codex prompt input must list `jev-skill`; check the source path as well. Start a
new Claude Code session and confirm the skill is available there. In a new agent
session, phrases such as "pásaselo a jev" should select the skill. Listing a
description is discovery evidence; actual selection needs a behavioral check.
The installer alone proves neither discovery nor triggering.

## Acceptance and review

The implementer can run the offline and version gates. The director owns live
acceptance, installation, publication, and independent adversarial review.
No runtime pass is implied by the presence of these scripts.

```bash
tools/check-cli.sh
tools/check-live.sh
tools/check-version-chain.sh
claude plugin validate . --strict
wc -l skills/jev-skill/SKILL.md
```

- `check-cli.sh`: local HTTP server, all exit codes, request/output shapes,
  environment/file credential lookup, authenticated header, seconds/date retry
  waits and their upper bound, recovery/exhaustion, redirects, sanitized 422
  details, actionable response validation, and output/argv credential checks.
  Regression cases also cover HTTP rejection outside literal loopback IPs, proxy bypass,
  UTF-8 under a different locale, BOM, closed stdout pipes, and defective JSON
  state. To challenge a historical executable, use `tools/check-cli.sh /path/to/jev`;
  the checker keeps its current expectations and reports regressions with exit 1.
- `check-live.sh`: real endpoint authentication, positive noul > 0.9, negative
  noul < 0.1, and dummy credential rejection with exit 3. This is a smoke test,
  not domain calibration. A 180-second subprocess watchdog also bounds the gate.
- `check-version-chain.sh`: both manifests and actual `jev --version` agree.
- Skill length must be strictly below 250 lines. Apply the operator's privacy
  deny-list to the entire tree, including ignored files and excluding `.git`.
  Permit only the explicitly approved GitHub repository reference in manifests
  and installation instructions; keep all other private-name checks intact.
- Run each new checker twice unchanged. Independently challenge it with a known
  failure: for example, change only the executable's version in an isolated copy
  and require the version gate to fail. Restore that isolated fixture afterward.
- Independently review new checks adversarially. Use the scenarios in
  `evaluations/jev-skill/` for skill findability and decision behavior; provide
  queries without expected answers to the evaluator. Runtime tests, scenario
  fixtures, and actual agent discovery are separate evidence.
  `evaluations/jev-skill/trigger-evals.json` separates `should_trigger` (skill
  loading) from `expect_cli_call` (CLI execution, checked in the tool trace).
  Bounded judgments include concrete synthetic inputs. Mentions and quick phrases
  can load the skill for non-judgment tasks; those tasks run directly and briefly,
  without a Jev call, ⚖️ marker, skill mention, or tool-selection explanation.

Run longer checks in the background through the directing agent's normal task
runner. Record each command's exit and any failing condition. Do not reinterpret
a missing execution as a pass. The director creates the remote and publishes it.

## License

MIT. The CLI, skill guidance, and examples are maintained here; current TypeSafe
API contracts, models, and limits live in the [documentation](https://docs.typesafe.ai/llms.txt).
