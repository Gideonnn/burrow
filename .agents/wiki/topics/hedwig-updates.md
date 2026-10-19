# Hedwig updates

Try changes on the operator's Mac with `pnpm hedwig:install`; nobody else notices. When
the operator says a version may go out, `pnpm hedwig:release` publishes the current
commit to every Mac: each Hedwig fetches it within the hour, checks its signature and
shows "Update klaar · Herstart" at the bottom of the sidebar. Releasing is the
operator's call; never release on your own initiative.

## How a release travels

1. `scripts/release.sh` refuses uncommitted or unpushed work, builds with the commit
   count on `main` as build number (`CFBundleVersion`), zips the app and signs the zip
   with `HEDWIG_RELEASE_KEY` from `infra/secrets/tools.env.enc` (Ed25519).
2. It copies the zip and `latest.json` over SSH to `~/.local/share/burrow/clients/hedwig/`
   on Dobby, `latest.json` last, and keeps the three newest builds.
3. The server offers them at `/api/clients/hedwig/latest` and `/<build>.zip` to any key.
4. Hedwig downloads a build only when its number is higher than its own, checks size,
   SHA-256 and the signature against `ReleaseKey.publicKey`, and unpacks it under
   `~/Library/Application Support/Hedwig/Updates`.
5. Herstart (or `hedwigctl restart`) runs a small script that waits for Hedwig to quit,
   swaps the app in place (restoring the old one if the copy fails) and opens it.

The signature means that whoever takes over the server or an admin key still cannot
push code to the household's Macs; only the holder of the release key can.

## Agents

`hedwigctl update` looks for a build now; `hedwigctl restart` restarts and installs a
ready build. Restart refuses while a compose window is open, because its text would be
lost: ask the person, then pass `--force` only with their consent.

## Setup and limits

- The release key is made once with `apps/hedwig-mac/scripts/release-key.sh` by the
  operator, who then commits `ReleaseKey.swift`. Without a public key, and in
  development runs outside an `.app`, updates are off.
- The first version with the updater has to be installed by hand on each Mac.
- Builds are signed ad hoc, so macOS may ask once after each update to allow Keychain
  access, where Hedwig keeps its API key. A stable signing certificate would end that.
