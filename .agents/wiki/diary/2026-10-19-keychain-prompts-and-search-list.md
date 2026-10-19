---
id: 2026-10-19-keychain-prompts-and-search-list
date: 2026-10-19
kind: trap
area: [hedwig]
topics: [hedwig-updates]
---

# Keychain prompts after every build, and a search list that broke

Installing the new Hedwig on Gideon's Mac left it hanging at launch: macOS asked for
the login password before the new build could read its API key, because an ad hoc
signature changes with every build. An agent never types passwords, so it waited until
morning. Fix: a self-signed "Burrow Hedwig" code signing identity, made once by the
operator (`scripts/signing-identity.sh`), which `bundle.sh` uses when present. Tested
first in a throwaway keychain: `codesign` accepts the untrusted self-signed identity and
the designated requirement becomes `certificate leaf = H"…"`, stable across builds.

Trap while testing: `security create-keychain` adds the new keychain to the user's
search list, and restoring the list from the word-split output of
`security list-keychains` produced a malformed entry (`login.keychain-db -db`). Restored
with `security list-keychains -d user -s ~/Library/Keychains/login.keychain-db`.
Never rebuild the search list from parsed output; delete the test keychain with
`security delete-keychain` and check the list afterwards.
