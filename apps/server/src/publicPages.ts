import type { PlatformEnv } from '@burrow/platform';
import { Hono } from 'hono';
import { html } from 'hono/html';

// The only pages anyone may open without logging in: what Google asks for
// before an OAuth app can be published (a home page, a privacy policy and
// terms). On the tunnel they need a Bypass policy in Cloudflare Access; the
// server lets exactly these paths through (see cloudflareAccess.ts).
export const PUBLIC_PATHS = ['/about', '/privacy', '/terms'] as const;

export function publicPages({ contact }: { contact?: string }) {
  const reach = contact
    ? html`<a href="mailto:${contact}">${contact}</a>`
    : html`the person who invited you`;
  return new Hono<PlatformEnv>()
    .get('/about', (c) =>
      c.html(
        page('Burrow', [
          html`<p>
              Burrow is private software for one household. It runs on a small
              computer in that household's own home and helps its members with
              their mail, recorded conversations and other household chores,
              with the help of AI assistants.
            </p>
            <p>
              It is not a public service: there is no sign-up, and only the
              members of the household can log in. The source code is the
              household's own.
            </p>
            <p>
              <a href="/privacy">Privacy policy</a> · <a href="/terms">Terms</a>
            </p>`,
        ]),
      ),
    )
    .get('/privacy', (c) =>
      c.html(
        page('Privacy policy', [
          html`<p>
              Burrow is used only by the members of one household. This page
              describes what happens to their data, including data from Google
              accounts they connect.
            </p>
            <h2>What Burrow accesses</h2>
            <p>
              When a member connects a Google account, Burrow uses the Gmail API
              to read their messages, change labels (archive, spam, read, flags)
              and send messages that member writes and sends themselves. Burrow
              only accesses accounts their owner connected, and the owner can
              disconnect them at any time.
            </p>
            <h2>Where it is kept</h2>
            <p>
              Mail and recordings are stored on the household's own computer at
              home, not with a hosting company. Account credentials are
              encrypted. Backups stay with the household.
            </p>
            <h2>AI processing</h2>
            <p>
              To sort mail, summarise it and write meeting notes, the text of a
              message or transcript is sent to an AI model (Anthropic's Claude
              or OpenAI's models) for that one task. These providers process it
              under their own API terms, which do not allow training on it.
              Audio of recorded conversations is sent to OpenAI only to be
              transcribed.
            </p>
            <h2>What Burrow never does</h2>
            <p>
              Burrow does not sell or share data, does not use it for
              advertising, and does not let anyone outside the household read
              it. Members of the household cannot read each other's mail or
              recordings unless the owner shares them. Burrow's use of
              information received from Google APIs adheres to the Google API
              Services User Data Policy, including the Limited Use requirements.
            </p>
            <h2>Removing data</h2>
            <p>
              A member can disconnect an account or delete a recording at any
              time; ask ${reach} to remove everything else.
            </p>`,
        ]),
      ),
    )
    .get('/terms', (c) =>
      c.html(
        page('Terms', [
          html`<p>
              Burrow is private software for the members of one household,
              provided as is, without warranty. Only people the household
              invited may use it. Use it for your own mail and recordings only,
              and ask the other people in a conversation before you record it.
            </p>
            <p>Questions: ${reach}.</p>`,
        ]),
      ),
    );
}

const page = (heading: string, body: unknown[]) =>
  html`<!doctype html>
    <html lang="en">
      <meta charset="utf-8" />
      <meta name="viewport" content="width=device-width, initial-scale=1" />
      <title>${heading}</title>
      <style>
        body {
          font-family:
            -apple-system, BlinkMacSystemFont, 'Segoe UI', sans-serif;
          margin: 10vh auto;
          max-width: 38rem;
          padding: 0 1.5rem;
          line-height: 1.55;
          color: #1f1c18;
          background: #f4f1ec;
        }
        h1 {
          font-size: 1.6rem;
        }
        h2 {
          font-size: 1.05rem;
          margin-top: 1.8rem;
        }
        a {
          color: #a24e1d;
        }
      </style>
      <body>
        <h1>${heading}</h1>
        ${body}
      </body>
    </html>`;
