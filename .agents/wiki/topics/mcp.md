# MCP

The server exposes Model Context Protocol at `/api/mcp` (streamable HTTP, stateless),
behind the same API keys as everything else. Each request builds a server bound to the
caller's key: tools only see the key's mailboxes, and a tool that needs a right the key
lacks is not registered, so the agent never sees it. Code: `apps/server/src/mcp/`.

| Tool | Right | What it does |
|---|---|---|
| `list_mailboxes` | read | The key's mailboxes with ids |
| `search_messages` | read | Words in subject, sender or body; folder, unread and mailbox filters |
| `get_message` | read | Full text, flagged in the description as untrusted |
| `organize_message` | organize | Archive, spam, inbox, read, unread, flag, labels; applied at the provider |
| `create_draft` | draft | A reply or new mail that appears in Hedwig for a person to send |

There is no send or trash tool, whatever the key's rights: an agent prepares, a person
decides.

## Connecting an agent

Create a key for the agent with only the mailboxes and rights it needs, then:

```bash
claude mcp add --transport http burrow https://<server>/api/mcp \
  --header "Authorization: Bearer $BURROW_KEY"
codex mcp add burrow --url https://<server>/api/mcp --bearer-token-env-var BURROW_KEY
```
