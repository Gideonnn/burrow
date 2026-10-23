# Diary index

Newest first.

- [2026-10-23 Hedwig's typography measured against Apple Mail](2026-10-23-hedwig-typography-measured-against-mail.md): sizes from pixel measurements, Mail's fonts read through AppleScript, semibold counts instead of `.badge`, Helvetica 12 for unstyled mail.
- [2026-10-23 Mail's list filter in Hedwig, filtered on the server](2026-10-23-hedwig-list-filter-on-the-server.md): criteria as query params so the whole folder counts, today as `since`, read mail stays until you move on.
- [2026-10-23 Hedwig's toolbar native, like Apple Mail](2026-10-23-hedwig-toolbar-native-like-mail.md): ControlGroups instead of hand-made glass, and the list column needs a toolbar item before compose can sit at the reading column's edge.
- [2026-10-23 Hedwig's reader header scrolls with the mail](2026-10-23-reader-header-scrolls-with-the-mail.md): Mail's header order, one ScrollView with a web view as tall as its mail, quirks mode locked the height, Reply-To kept by the server.
- [2026-10-23 Pensieve v6: iCloud is the source, Dobby keeps every file, links replace sharing](2026-10-23-pensieve-files-live-on-dobby.md): video goes to Dobby too, the app follows the iCloud folder with grey restorable deletions, and Stuur makes one-download 24-hour links instead of sharing between people.
- [2026-10-23 CI's Xcode differed from the local one](2026-10-23-ci-xcode-differs-from-local.md): a newer Swift on the runner rejected a send of non-Sendable drop providers; the loader runs on the caller's actor and CI pins the local Xcode.
- [2026-10-23 Keeping a window on screen hid it between Spaces](2026-10-23-window-keeper-hid-windows-between-spaces.md): no screen-change observer, no animation, fit only a settled window on the active Space.
- [2026-10-22 Pensieve v2: four kinds, video on the Mac, labels per person](2026-10-22-pensieve-v2-engine.md): only the diarizing model gives timestamps, measured part offsets, labels private per person, the shelf that deletes originals only after iCloud has the MP4.
- [2026-10-22 Every deploy restarted the tunnel: 30 seconds of 530](2026-10-22-deploys-restarted-the-tunnel.md): the install now leaves an unchanged tunnel alone; the apps retry gateway errors quietly and never show HTML.
- [2026-10-22 Folders per mailbox, the filter review in Spam, spam stays unread](2026-10-22-spam-review-per-mailbox.md): no merged inbox, no Meer, no Gefilterd page; spam is read only after "Geen spam".
- [2026-10-22 Sidebar rows with a badge need a tag](2026-10-22-sidebar-rows-with-a-badge.md): Gefilterd, Evenementen, Taken and Concepten ignored clicks; a badged `NavigationLink(value:)` needs `.tag`.
- [2026-10-22 Outing pictures on the Mac, pasted anywhere on the page](2026-10-22-outing-pictures-paste-anywhere.md): thumbnail, hero and title colours; ⌘V caught by a key monitor, bytes over links, files over their icon.
- [2026-10-22 The Evenementen page on the Mac, simple first](2026-10-22-evenementen-page-on-the-mac.md): one sentence per outing, details folded away, Mac notifications until Patronus, and a DatePicker that saved on appear.
- [2026-10-22 Outings live in Hedwig](2026-10-22-outings-in-hedwig.md): household-wide outings with tickets and a checklist, detected without a model, inside Hedwig because modules never import each other.
- [2026-10-22 Attachments on demand, keyed by part](2026-10-22-attachments-keyed-by-part.md): never stored, fetched per request; Gmail's attachmentId changes on every read, so ids are part ids.
- [2026-10-22 Runners, two queues and mail facts in one night](2026-10-22-runners-and-mail-facts.md): the claim is the registration, standing work as short-lived rows, and a keychain prompt that blocks a headless runner.
- [2026-10-20 A model per skill, Winky only local, and two Ollama traps](2026-10-20-models-per-skill-and-local-winky.md): Haiku by default, Opus for writing at effort high, Sol 6.1 for Codex; local bots never fall back to the cloud.
- [2026-10-21 Search in Hedwig](2026-10-21-hedwig-search.md): words as you type, meaning on Enter; the bot plans the search and never reads mail.
- [2026-10-20 The whole archive on Dobby, and search in the open place](2026-10-20-hedwig-archive-and-search-scope.md): backfill per mailbox instead of provider search; search follows the sidebar.
- [2026-10-20 A platform with modules, Pensieve, device login and burrowctl](2026-10-20-platform-pensieve-and-device-login.md): the refactor into platform and modules, RecHoarder adopted, login through the browser, agents operating every app.
- [2026-10-19 Keychain prompts after every build, and a search list that broke](2026-10-19-keychain-prompts-and-search-list.md): a fixed signing identity, and how not to touch the keychain search list.
- [2026-10-19 Signed Hedwig releases through the server](2026-10-19-signed-hedwig-releases-through-the-server.md): local install to iterate, signed release over SSH to Dobby, Sparkle rejected.
- [2026-10-19 Hedwig control through its own accessibility tree](2026-10-19-hedwig-control-through-accessibility.md): `hedwigctl`, approval for send and delete, and the rejected routes.
- [2026-10-19 Operator tokens in SOPS](2026-10-19-operator-tokens-in-sops.md): the Cloudflare API token in `tools.env.enc`, used through `pnpm with-secrets`.
- [2026-10-19 Tailscale dropped for Cloudflare](2026-10-19-tailscale-dropped-for-cloudflare.md): one route through the tunnel, `/api` guarded by keys and a rate limit.
- [2026-10-19 Public access through Cloudflare Access](2026-10-19-public-access-through-cloudflare-access.md): tunnel on its own port, Access token checked by the server, Funnel rejected.
- [2026-10-19 Burrow founded](2026-10-19-burrow-founded.md): design decisions for Hedwig and the server, and the alternatives rejected.
