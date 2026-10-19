# Login and the household

A new Mac app logs in through the browser and gets its own device key; nobody copies
keys. Both people of the household are admins: they manage each other's settings,
features and devices, but never read each other's mail or recordings.

## Device login (RFC 8252)

1. The app listens on `127.0.0.1:<random port>` and opens
   `<server>/login/device?app=…&device=…&challenge=…&state=…&redirect=http://127.0.0.1:…/callback`.
2. On the tunnel that page is behind Cloudflare Access; the server verifies the Access
   token itself and finds the person by `people.email`.
3. The page asks "<App> op <Mac> wil inloggen als <naam>" with Toestaan and Weigeren.
4. Toestaan redirects to the loopback address with a one-time code (2 minutes).
5. The app posts code and PKCE verifier to `POST /api/login/token` and gets a key with
   every right the person may hold (admin only for admins), named "<App> op <Mac>".

Why it is safe: only loopback redirects are accepted, so a link someone else crafted
delivers its code to the clicking person's own Mac; without the verifier the code is
worthless; approvals posted from another origin are refused. Code:
`apps/server/src/auth/deviceLogin.ts`, `packages/burrow-kit/Sources/BurrowKit/DeviceLogin.swift`.
Without Access (development) set `BURROW_DEV_LOGIN=<name>` for requests from the
machine itself, or create keys with the CLI.

## Admins

- Admins change anyone's settings (`PATCH /api/admin/people/:id/settings`) and bot
  instructions, list everyone's devices and revoke them, and connect mailboxes for the
  other person (who logs in at the provider, so the mailbox is theirs).
- An admin makes keys only for **themselves**: a key reads its person's mail. The other
  person logs in on their own Mac.
- Login addresses are set only by the operator (`cli.sh set-email`): whoever controls a
  person's address can log in as them.
- Known leak, accepted: learned triage rules contain sender addresses and are visible to
  admins as part of the settings.

## Settings

Modules declare settings; values are per person (`people.settings`), defaults apply
when unset, and `null` resets. Every app shows them under Settings › Huishouden.
