# Haiku 5.5 thinks anyway

2 November 2026.

Claude Code on Dobby had `autoUpdates: false` and stayed at 2.1.288, where `--model haiku`
means Haiku 4.5. The full id `claude-haiku-5-5` ran on that version too, but with an
`unrecognized_model` warning and an unknown cost. `claude update` to 2.1.316 moved the
alias to Haiku 5.5, so the bots keep `model: haiku` instead of pinning an id.

Haiku 5.5 only accepts disabled thinking at effort high or below, and the CLI never sends
it: `MAX_THINKING_TOKENS=0`, `CLAUDE_CODE_DISABLE_THINKING=1`, `alwaysThinkingEnabled:
false` and `--effort low|medium|high` all still showed 180 to 640 thinking tokens on a
search plan. It does not matter much: a plan takes 3.5 to 5 s with thinking, against 6 s
for Haiku 4.5 without. `thinking: false` stays in the runner for models that honour it.
Per-kind effort was not worth measuring further; the noise between runs (a second either
way) was larger than the difference between efforts.
