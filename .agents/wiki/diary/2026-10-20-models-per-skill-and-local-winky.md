---
id: 2026-10-20-models-per-skill-and-local-winky
date: 2026-10-20
kind: decision
area: [platform, bots, skills]
topics: [architecture, naming]
---

# A model per skill, Winky only local, and two Ollama traps

## Decided

- **Haiku 5.5 for simple work, Opus 5.5 where it takes thought.** The bot's `model` is
  the default; a skill names `model: opus` when it needs more (reply suggestions, meeting
  notes). Sorting, search plans and key facts stay on Haiku. Sonnet is gone from the bot
  schema. Opus runs at effort high; Haiku gets no effort and chooses its own. Codex, the
  fallback, runs Sol 6.1 (`gpt-6.1-sol`).
- **Kreacher writes the meeting notes**, in the cloud, on Opus. Gideon did not want
  notes on a local model.
- **Winky is purely local**: `agent: local` with an `ollama:` model, refused by the
  server's fallback runner and by the Mac's Claude runner, so no fallback can ever send
  her work to a cloud model. The schema ties the two together: a local bot needs an
  `ollama:` model and only a local bot may name one.
- **Sorting Hat** names the decisions between fixed options; a Jev-style decision model
  may take it over. Jev itself is hosted by TypeSafe and was rejected for privacy.

## Traps (phase 0 of the mail facts plan)

- Homebrew's `ollama` formula ships without the xgrammar library of the MLX runner, so
  every request with `format` fails with "structured output is unavailable". The
  official app (`brew install --cask ollama-app`) has it.
- Ollama enforces a JSON schema while decoding but does not show it to the model. Without
  the options in the prompt, gemma4 picked enum values by their first letters (`account`
  and `code` for everything). List every enum option with a short meaning in the prompt.
