# App updates

Try changes on the operator's Mac with `pnpm hedwig:install` or `pnpm pensieve:install`;
nobody else notices. When the operator says a version may go out, `pnpm hedwig:release`
or `pnpm pensieve:release` publishes the current commit to every Mac: each copy fetches
it within the hour, checks its signature and shows "Update klaar · Herstart" at the
bottom of the sidebar. Releasing is the operator's call; never release on your own
initiative. Every app uses the same release key, script and updater
(`packages/burrow-kit/scripts/release.sh`, `BurrowKit/Update`).

## How a release travels

1. `packages/burrow-kit/scripts/release.sh <app folder> <AppName> <client>` refuses uncommitted or unpushed work, builds with the commit
   count on `main` as build number (`CFBundleVersion`), zips the app and signs the zip
   with `HEDWIG_RELEASE_KEY` from `infra/secrets/tools.env.enc` (Ed25519).
2. It copies the zip and `latest.json` over SSH to `~/.local/share/burrow/clients/<client>/`
   on Dobby, `latest.json` last, and keeps the three newest builds.
3. The server offers them at `/api/clients/<client>/latest` and `/<build>.zip` to any key.
4. The app downloads a build only when its number is higher than its own, checks size,
   SHA-256 and the signature against `ReleaseKey.publicKey`, and unpacks it under
   `~/Library/Application Support/<App>/Updates`.
5. Herstart (or `burrowctl <app> restart`) runs a small script that waits for the app to quit,
   swaps the app in place (restoring the old one if the copy fails) and opens it.

The signature means that whoever takes over the server or an admin key still cannot
push code to the household's Macs; only the holder of the release key can.

## Agents

`burrowctl <app> update` looks for a build now; `burrowctl <app> restart` restarts and
installs a ready build. Restart refuses while Hedwig has a compose window open or
Pensieve is recording: ask the person, then pass `--force` only with their consent.

## Setup and limits

- The release key is made once with `packages/burrow-kit/scripts/release-key.sh` by the
  operator, who then commits `ReleaseKey.swift`. Without a public key, and in
  development runs outside an `.app`, updates are off.
- The first version with the updater has to be installed by hand on each Mac.
- The apps keep their API key in the keychain. Besides its access rule, a keychain item
  has a *partition list*: for an app with an Apple team ID that is `teamid:<id>`, for
  any other signature (ad hoc or self-signed) it is `cdhash:<hash>` of that one build.
  "Sta altijd toe" only adds the current build, so without a team ID every update asks
  for the login password again, and the app hangs at launch until someone answers.
  `packages/burrow-kit/scripts/sign-app.sh` (used by both `bundle.sh` scripts) therefore
  signs with a Developer ID or Apple Development certificate when the Mac has one (a free
  Apple ID in Xcode gives the latter), else the self-signed "Burrow Hedwig"
  (`signing-identity.sh`), else ad hoc. A steady signature also keeps Pensieve's
  microphone and system audio grants. Releases must be built on the Mac that holds the
  identity. The first build with a team ID asks once more; check the item's partition
  list with `security dump-keychain -a` (attributes only) for `teamid:`.
