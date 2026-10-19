#!/usr/bin/env bash
# Regression tests for the repository hooks: ./.agents/hooks/test-hooks.sh
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

failed=0
expect() {
  local want="$1" payload="$2" label="$3" got=0
  printf '%s' "$payload" | bash pre-tool.sh >/dev/null 2>&1 || got=$?
  if [ "$got" != "$want" ]; then
    echo "FAIL ($got, want $want): $label"
    failed=1
  fi
}

expect 2 '{"tool_name":"Read","tool_input":{"file_path":"/x/.env"}}' 'read .env'
expect 2 '{"tool_name":"Read","tool_input":{"file_path":"/x/apps/server/.env.local"}}' 'read .env.local'
expect 0 '{"tool_name":"Read","tool_input":{"file_path":"/x/.env.example"}}' 'read .env.example'
expect 0 '{"tool_name":"Read","tool_input":{"file_path":"/x/infra/secrets/dobby.env.enc"}}' 'read SOPS file'
expect 2 '{"tool_name":"Bash","tool_input":{"command":"cat apps/server/.env.local"}}' 'cat an env file'
expect 2 '{"tool_name":"Bash","tool_input":{"command":"grep TOKEN \".env\""}}' 'quoted env file'
expect 0 '{"tool_name":"Bash","tool_input":{"command":"ls * && echo ok"}}' 'a glob is not expanded'
expect 2 '{"tool_name":"Bash","tool_input":{"command":"npx vitest"}}' 'npx'
expect 2 '{"tool_name":"Read","tool_input":{"file_path":"/Users/x/.ssh/id_ed25519"}}' 'ssh private key'
expect 0 '{"tool_name":"Read","tool_input":{"file_path":"/Users/x/.ssh/known_hosts"}}' 'known_hosts'
expect 0 '{"tool_name":"Read","tool_input":{"file_path":"/Users/x/.ssh/id_ed25519.pub"}}' 'ssh public key'
expect 2 '{"tool_name":"Write","tool_input":{"file_path":"/x/data/burrow.sqlite"}}' 'mail database'
expect 0 '{"tool_name":"Read","tool_input":{"file_path":"/x/AGENTS.md"}}' 'ordinary file'
expect 2 '{"tool_name":"Read"}' 'malformed payload'
expect 2 '{"tool_name":"Bash","tool_input":{"command":"sops -d infra/secrets/tools.env.enc"}}' 'agent decrypts with sops'
expect 2 '{"tool_name":"Bash","tool_input":{"command":"cd infra && sops decrypt secrets/tools.env.enc"}}' 'sops after another command'
expect 2 '{"tool_name":"Bash","tool_input":{"command":"pnpm sops:edit infra/secrets/tools.env.enc"}}' 'agent edits with sops'
expect 0 '{"tool_name":"Bash","tool_input":{"command":"pnpm with-secrets tools ./script.sh"}}' 'the with-secrets wrapper'
expect 0 '{"tool_name":"Bash","tool_input":{"command":"pnpm sops:verify infra/secrets/tools.env.enc"}}' 'verify shows no values'
expect 0 '{"tool_name":"Bash","tool_input":{"command":"git commit -m \"docs: explain sops\""}}' 'sops in a commit message'

[ "$failed" = 0 ] && echo "hooks: all checks passed"
exit "$failed"
