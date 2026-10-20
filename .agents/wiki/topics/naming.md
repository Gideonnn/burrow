# Naming

Every application in Burrow has a Harry Potter name; the repository is the Burrow, the
Weasleys' home, run by magical helpers. Use the name in code, packages and docs
(`@burrow/hedwig`). A user-facing alias may be plain (Raycast opens Hedwig as `email`).
The repository must not use Harry Potter logos, artwork, fonts or quotes, and the README
states that Burrow is not affiliated with the rights holders.

| Name | Role | Status |
|---|---|---|
| Burrow | The monorepo and platform | Active |
| Dobby | The home machine that runs the Burrow server (`apps/server`) | Active |
| Kreacher | Bot persona: the house-elf for everyday chores on a cloud AI: sorting mail, suggestions, search plans, meeting notes (`bots/kreacher.md`) | Active |
| Winky | Bot persona: the discreet house-elf for sensitive chores, only on a local model on the owner's Mac (`bots/winky.md`) | Active |
| Hedwig | Mail | Active |
| Pensieve | Recorded conversations: transcripts and notes (was RecHoarder); later also the searchable archive of documents and notes | Active |
| Sorting Hat | Decisions between fixed options (category, priority, sensitive, triage action): the triage skill today, later a small local decision model in the style of Jev | Draft |
| Portkey | Routines: triggers that start tasks | Planned |
| Remembrall | Tasks and reminders (Todoist replacement) | Idea |
| Weasley Clock | Where everyone is, family calendar | Idea |
| Gringotts | Money: invoices, subscriptions, budget | Idea |
| Daily Prophet | Morning briefing | Idea |
| Potions Book | Recipes, meal plan, shopping list | Idea |
| Howler | Urgent notifications | Idea |
| Accio | One search over everything, as a Raycast extension | Idea |
| Patronus | The Telegram bot: private chats and a household group with the bots | Planned |
| Unbreakable Vow | Contracts, warranties, insurance, notice periods | Idea |
| Errol | Parcels from shipping mail | Idea |
| Knight Bus | Trips: bookings from mail into one itinerary | Idea |
| Marauder's Map | House and server status | Idea |

Plain names, because they are mechanisms rather than applications: the platform
(`packages/platform`), BurrowKit and BurrowUI (the shared Swift package), `burrowctl`,
workers, tasks and routines.
