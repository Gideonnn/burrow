---
id: 2026-10-19-signed-hedwig-releases-through-the-server
date: 2026-10-19
kind: decision
area: [hedwig, server]
topics: [hedwig-updates]
---

# Signed Hedwig releases through the server

Gideon wanted Hedwig to update itself on every Mac, with a "restart to update" prompt,
and an agent able to restart it; and to iterate on his own Mac without Angela noticing.
Decided: `pnpm hedwig:install` stays the local loop; `pnpm hedwig:release` signs a build
with an Ed25519 key from SOPS and copies it to Dobby, whose server offers it to every
Hedwig. Hedwig checks the signature against a public key compiled in.

Rejected:

- **Sparkle.** Proven, but an appcast host, a framework in a package without an Xcode
  project, and its own key handling, for two or three Macs.
- **Unsigned builds behind an admin upload route.** Anyone with an admin key or the
  server would be able to push code to every Mac. Copying over SSH also means no upload
  route exists at all.
- **Release channels.** Local install versus explicit release already keeps experiments
  off Angela's Mac; a channel would only add state.

Build numbers are the commit count on `main`, so they only grow and a local build never
gets replaced by an older release.
