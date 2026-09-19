# CLAUDE.md

This repository packages `jev-skill` and its Python standard-library CLI as the
`jev-skills` Claude Code marketplace/plugin. The same skill directory is shared
with Codex and Grok through explicit local symlinks.

## Layout

- `.claude-plugin/`: marketplace and plugin manifests.
- `skills/jev-skill/SKILL.md`: activation and operational guidance, under 250 lines.
- `skills/jev-skill/reference/`: CLI contract and generic decision examples.
- `skills/jev-skill/bin/jev`: one executable, no package installation required.
- `evaluations/jev-skill/`: scenarios for independent skill evaluation.
- `tools/`: offline/live gates, version consistency, and local symlink installer.

## Maintenance

Keep examples generic. Never store credentials, account inventories, or operator
context. Keep question meaning, confidence, and authorization distinct.
The CLI version and both manifest versions must match. For a release, run
`tools/check-version-chain.sh`, `tools/check-cli.sh`, `tools/check-live.sh`, and
`claude plugin validate . --strict`; record actual exits. Live checks call the API.
Run a new verifier twice unchanged and exercise a known failing control before
trusting it. Independent adversarial review is required for newly written checks.

The implementer may run the offline CLI and version gates. The director runs live
acceptance, adversarial review, installation, commits, and publication. The
implementer's git metadata is read-only: do not attempt commits, add remotes,
install, or push. The shared source is the skill directory in Claude's managed
marketplace clone, resolved to its canonical path as described in the README.
Its `--check` mode must never write; conflicts must be found before any links change.

This generic repository guide belongs in the scaffold commit. Stage it explicitly
despite the local `CLAUDE.md` ignore convention. The git log records changes.
