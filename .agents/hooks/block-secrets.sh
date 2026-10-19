#!/usr/bin/env bash
# Stops agents from reading or writing plaintext secrets: env files, databases
# with mail and tokens, private keys. Example files and SOPS-encrypted files
# are allowed. Exit 2 blocks the tool call.
set -euo pipefail

payload=$(cat)
set -f  # the Bash branch splits a command into words; never glob them
tool=$(jq -r '.tool_name // empty' <<<"$payload")

secret_path() {
  local p="$1" base
  base=$(basename "$p")
  case "$base" in
    .env.example|*.env.example|*.enc|*.enc.*|*.pub) return 1 ;;
    .env|.env.*|*.env) return 0 ;;
    *.sqlite|*.sqlite-*|*.db) return 0 ;;
    *.pem|*.key|*.p12|id_rsa|id_ed25519|id_ecdsa|*_ed25519|*_rsa) return 0 ;;
    keys.txt) [[ "$p" == *sops/age* ]] && return 0 ;;
  esac
  case "$p" in
    */.ssh/*) [[ "$base" == known_hosts || "$base" == config || "$base" == authorized_keys ]] || return 0 ;;
  esac
  return 1
}

block() { echo "Blocked: $1 looks like a plaintext secret. Use the example file or a script that reads it for you." >&2; exit 2; }

case "$tool" in
  Read|Edit|Write|NotebookEdit)
    path=$(jq -r '.tool_input.file_path // .tool_input.notebook_path // empty' <<<"$payload")
    [ -n "$path" ] && secret_path "$path" && block "$path"
    ;;
  Grep|Glob)
    path=$(jq -r '.tool_input.path // empty' <<<"$payload")
    [ -n "$path" ] && secret_path "$path" && block "$path"
    ;;
  Bash)
    cmd=$(jq -r '.tool_input.command // empty' <<<"$payload")
    for word in $cmd; do
      word=${word//[\"\'\;\|\&\(\)\<\>]/}
      [ -n "$word" ] || continue
      [[ "$word" == -* ]] && continue
      secret_path "$word" && block "$word"
    done
    ;;
esac
exit 0
