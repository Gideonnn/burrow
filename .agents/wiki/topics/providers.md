# Mail providers

How each provider is connected, and the one-time setup the operator does at the provider.
The code lives in `modules/hedwig` (clients) and `apps/server/src/mail/accounts.ts`
(credentials, connecting). Credentials are sealed with `BURROW_SECRET_KEY`; losing that
key means reconnecting every mailbox.

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
triggers a full resync of the last 100 inbox messages. Drafts are skipped. Server
operations become one `messages.modify` call per message; missing user labels are
created on first use.

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

## Fastmail (JMAP)

Fastmail only offers OAuth to registered partner apps, so a person creates an API token:
Settings › Privacy & Security › Integrations › API tokens, with access to **Email** and
**Email submission** and without "read-only". An admin client sends it to
`POST /api/admin/accounts/fastmail`; the server checks it against the JMAP session before
storing it sealed.

Sync queries the inbox once (last 100 messages), then follows `Email/changes` from the
state, starting over when the server answers `cannotCalculateChanges`. Labels are JMAP
keywords (non-`$`); moves replace `mailboxIds` with the target role's mailbox. Sending
creates a draft and an `EmailSubmission` that files it under Sent on success.
