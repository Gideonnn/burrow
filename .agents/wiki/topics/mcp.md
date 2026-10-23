# MCP

There are two MCP servers, for two jobs:

- **The server's endpoint** `/api/mcp` (streamable HTTP, stateless) for data: mail,
  recordings, settings, routines. Behind the API keys like everything else.
- **`burrowctl mcp`** (stdio, on the Mac) to operate the running apps: see
  [operating the apps](agent-control.md).

## The server's endpoint

Each request builds a server bound to the caller's key: tools only see what the key
sees, and a tool that needs a right the key lacks is not registered, so the agent never
sees it. The platform registers its tools (`packages/platform/src/mcp.ts`), then every
module its own (`modules/<name>/…/mcp-tools.ts`).

| Tool | Right | What it does |
|---|---|---|
| `get_settings` | read | The person's settings and features, with what each means |
| `update_settings` | organize | Change them (only what modules declare; never logins or keys) |
| `get_instructions`, `set_instructions` | read, organize | The person's standing instructions for their bots |
| `list_routines`, `save_routine`, `delete_routine` | read, organize | Routines |
| `list_tasks` | read | What the bots did, with results |
| `list_mailboxes`, `search_messages`, `get_message` | read | Hedwig: the key's mailboxes. Results carry the [mail facts](mail-facts.md); `get_message` also says whom Reply and Reply all address (`reply`, `replyAll`); low-priority mail only with `includeLow`; `get_message` returns secrets and personal numbers as placeholders, and a facts-only key does not get it at all |
| `organize_message` | organize | Archive, spam, inbox, read, flag, labels at the provider |
| `create_draft` | draft | A draft that appears in Hedwig for a person to send; a reply without `to` is addressed like Reply (Reply-To, else the sender) |
| `list_recordings`, `search_recordings`, `get_recording` | read | Pensieve: own and shared recordings of every kind, filtered by `kind` and `labels`; `get_recording` gives the transcript with `[mm:ss]` stamps and the marks |
| `list_recording_labels` | read | The person's own labels with counts |
| `rename_recording` | organize | A better title for an own recording |
| `label_recording` | organize | Set the person's labels on a recording they can see |

There is no tool that sends, deletes, shares, approves a task or moves money, whatever
the key's rights: an agent prepares, a person decides.

## Connecting an agent

Create a key for the agent with only the mailboxes and rights it needs, then:

```bash
claude mcp add --transport http burrow https://<server>/api/mcp \
  --header "Authorization: Bearer $BURROW_KEY"
codex mcp add burrow --url https://<server>/api/mcp --bearer-token-env-var BURROW_KEY
```
