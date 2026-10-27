# Mail providers

How each provider is connected, and the one-time setup the operator does at the provider.
The code lives in `modules/hedwig` (clients) and `modules/hedwig/src/server/accounts.ts`
(credentials, connecting). Credentials are sealed with `BURROW_SECRET_KEY`; losing that
key means reconnecting every mailbox.

## Sync and the archive

Sync keeps the recent inbox current (per provider below). Next to it a backfill loop
(`startBackfillLoop`) brings in every older message, newest first, one page every two
seconds per mailbox, until `mailboxes.backfilled_at` is set; `backfill_cursor` holds where
it continues. Backfilled mail skips spam, trash and drafts, is marked triaged so the bot
never sorts it, sends no events, and never overwrites what sync stored. Sync and backfill
take turns per mailbox (`MailService.busy`), so two clients never refresh one OAuth token
at once. Search covers whatever is on the server, so the archive is searchable as soon as
its pages are in.

## Attachments

Hedwig never stores attachments. `GET /api/messages/:id/attachments` asks the provider for
the list each time and `GET /api/messages/:id/attachments/:attachmentId` passes one file
through, as a download (`content-disposition: attachment`, `nosniff`, a sandbox CSP),
capped at 25 MB (413 above). Both need `read`, follow the message's visibility (404) and
refuse facts-only keys (403). An attachment id is stable for the same message, so it can
go in a URL; inline images (a Content-ID, not marked as attachment) come with
`inline: true`. Per provider below.

## Connecting an account

OAuth providers (Gmail, Microsoft) connect in three steps, so neither the password nor
an API key ever passes through the browser:

1. An admin client calls `POST /api/admin/accounts/connect` with the person and
   provider, and gets a one-time link valid for ten minutes.
2. The browser opens the link; the server redirects to the provider's own login page
   with PKCE.
3. The provider redirects to `<BURROW_PUBLIC_URL>/oauth/callback`; the server exchanges
   the code, asks the provider for the address and stores the mailbox. Connecting the
   same address again for the same person replaces the credentials.

When a provider refuses the stored refresh token (`invalid_grant`: revoked, a changed
password, or Google's seven days while the app is in *Testing*), the session raises
`GrantRevokedError`, `mailboxes.reconnect_needed_at` is set and a `mailbox.changed` event
goes out. Sync and backfill skip the mailbox, provider calls answer 409, and `/me` shows
`needsReconnect`, so Hedwig puts a notice with **Opnieuw inloggen** above the list. That
button asks `POST /api/mailboxes/:id/reconnect` (the owner with `organize`, no admin) for
the same kind of one-time link; the callback refuses a login as another address, and
storing the new tokens clears the mark. Fastmail tokens are not covered: a revoked one
still shows up only as failing syncs in the log.

The browser must reach `BURROW_PUBLIC_URL`. On Dobby that is the public hostname of the
Cloudflare Tunnel, behind an Access login, so a person logs in at Cloudflare first.

## Gmail (Google Cloud)

1. In the Google Cloud console, create a project (or reuse the one from `mail-mcp`) and
   enable the **Gmail API**.
2. OAuth consent screen: type **External**, add the scope
   `https://www.googleapis.com/auth/gmail.modify`, add each Google address as a test user.
3. **Publish the app.** While it is in *Testing*, Google expires refresh tokens after
   7 days. Unverified but published is fine for a household: each person clicks through
   one warning.
4. Create an OAuth client of type **Web application** with the redirect URIs
   `http://127.0.0.1:4717/oauth/callback` (local) and
   `https://<public hostname>/oauth/callback`.
5. Download the client as JSON and run `./infra/dobby/oauth-client.sh google <file>`:
   it sets `GOOGLE_CLIENT_ID` and `GOOGLE_CLIENT_SECRET` on Dobby without printing the
   secret, deletes the file on both sides and restarts the server.

Sync uses `users.history.list` from a history id; an expired id (older than about a week)
triggers a full resync of the last 100 inbox messages. Drafts are skipped. Backfill pages
through `messages.list` without a label, which leaves out spam and trash. Server
operations become one `messages.modify` call per message; missing user labels are
created on first use.

Attachments are the parts with a filename in `messages.get?format=full`. Gmail hands out
a new `body.attachmentId` with every `messages.get`, so the listed id is the part's
`partId`; a download fetches the message again for the current attachmentId, then
`messages.attachments.get`. A forwarded message is one attachment, not its parts.

## Microsoft (Outlook.com and Microsoft 365)

1. In the Microsoft Entra admin center, register an application with supported account
   types **personal Microsoft accounts and accounts in any organizational directory**.
2. Add a **Web** platform with the same two redirect URIs as Google.
3. Add delegated Graph permissions `offline_access`, `User.Read`, `Mail.ReadWrite`,
   `Mail.Send`, and create a client secret.
4. Put the application (client) id and secret in `MICROSOFT_CLIENT_ID` and
   `MICROSOFT_CLIENT_SECRET`.

A work tenant may block user consent for outside apps; then its IT admin has to approve
the app before the login succeeds. Ask before connecting a work account: its mail goes
through the household's agent.

Sync tracks the Inbox and Junk Email folders with delta queries, starting with the last
30 days. All calls ask for immutable ids, so a message keeps its id when it moves; a
message that leaves a tracked folder is fetched to see whether it moved (archive, trash)
or was deleted. Replies go through the `reply` endpoint to keep the conversation.
Backfill lists `/me/messages` across all folders by date and drops junk and deleted items
itself (the list cannot filter on folder next to that ordering); old mail has no headers,
which only come per message. Mail in other folders than Inbox and Junk is not tracked
after it is in, so a later change there does not reach Hedwig.

Attachments come from `/me/messages/{id}/attachments` (selected without `contentBytes`);
only `fileAttachment`s are listed, since an attached Outlook item or a OneDrive link has
no bytes of its own. A download reads the attachment's `contentBytes`. Graph's `size`
includes metadata, so the downloaded byte count is the real size.

## Fastmail (JMAP)

Fastmail only offers OAuth to registered partner apps, so a person creates an API token:
Settings › Privacy & Security › Integrations › API tokens, with access to **Email** and
**Email submission** and without "read-only". An admin client sends it to
`POST /api/admin/accounts/fastmail`; the server checks it against the JMAP session before
storing it sealed.

Fastmail is strict about header properties: `header:List-Unsubscribe:asText` is refused
with `invalidArguments` (List-* headers are URL headers to it), so the client asks
`asRaw`, which every server allows. Its errors name the offending arguments in
`arguments`, which the client prints; `description` is usually empty.

Sync queries the inbox once (last 100 messages), then follows `Email/changes` from the
state, starting over when the server answers `cannotCalculateChanges`. Backfill pages by
position through every mailbox but junk, trash and drafts (`inMailboxOtherThan`). Labels are JMAP
keywords (non-`$`); moves replace `mailboxIds` with the target role's mailbox. Sending
creates a draft and an `EmailSubmission` that files it under Sent on success.

Attachments are the email's `attachments` property from `Email/get`; the id is the
`partId` (two identical files share a blobId). A download looks up the part's blobId and
fetches it through the session's `downloadUrl` template with the API token.
