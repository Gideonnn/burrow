#!/usr/bin/env bash
# Installs or updates the Burrow server on a Linux machine as a systemd user
# service, without Docker or sudo. Run it on the machine itself, from a
# checkout of the repository:
#
#   ~/burrow/infra/dobby/install.sh            install or update
#   ~/burrow/infra/dobby/install.sh --status   show service, health and next steps
#
# What it does, each step safe to repeat:
#   1. checks Node 22+ and installs pnpm into ~/.local/bin if needed;
#   2. installs dependencies and builds the server;
#   3. writes ~/.config/burrow/burrow.env once (mode 600) with a fresh
#      BURROW_SECRET_KEY and the Tailscale HTTPS name; later runs keep it;
#   4. installs and (re)starts the burrow.service and the nightly backup timer;
#   5. publishes the server on the tailnet with `tailscale serve` when allowed.
#
# Secrets stay on this machine: the env file is never printed or copied.
set -euo pipefail

REPO="$(cd "$(dirname "$0")/../.." && pwd)"
CONFIG_DIR="$HOME/.config/burrow"
ENV_FILE="$CONFIG_DIR/burrow.env"
DATA_DIR="$HOME/.local/share/burrow"
UNIT_DIR="$HOME/.config/systemd/user"
PORT=4717
export PATH="$HOME/.local/bin:$PATH"

say() { printf '\033[1m→ %s\033[0m\n' "$*"; }
fail() { printf '\033[31m✗ %s\033[0m\n' "$*" >&2; exit 1; }

health() { curl -fsS "http://127.0.0.1:$PORT/health" 2>/dev/null; }

status() {
  systemctl --user --no-pager status burrow.service 2>/dev/null | sed -n 1,5p || true
  if health >/dev/null; then echo "health: $(health)"; else echo "health: not answering"; fi
  echo
  echo "Next steps:"
  echo "  first person and admin key:  node $REPO/apps/server/dist/cli.js init <name>"
  echo "     (run with the env loaded: set -a; . $ENV_FILE; set +a)"
  echo "  logs:                         journalctl --user -u burrow -f"
  echo "  Google/Microsoft accounts:    add the client ids to $ENV_FILE, then rerun this script"
}

if [ "${1:-}" = "--status" ]; then status; exit 0; fi

say "checking Node"
command -v node >/dev/null || fail "Node 22 or newer is required"
major="$(node -p 'process.versions.node.split(".")[0]')"
[ "$major" -ge 22 ] || fail "Node 22 or newer is required (found $(node -v))"

if ! command -v pnpm >/dev/null; then
  say "installing pnpm into ~/.local/bin"
  mkdir -p "$HOME/.local/bin"
  corepack enable --install-directory "$HOME/.local/bin" pnpm
fi

say "installing dependencies and building"
cd "$REPO"
pnpm install --frozen-lockfile --filter @burrow/server... >/dev/null
pnpm --filter @burrow/server build >/dev/null

if [ ! -f "$ENV_FILE" ]; then
  say "writing $ENV_FILE (first install)"
  mkdir -p "$CONFIG_DIR" "$DATA_DIR"
  public_url="http://127.0.0.1:$PORT"
  if command -v tailscale >/dev/null; then
    name="$(tailscale status --self --json 2>/dev/null | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{try{process.stdout.write(JSON.parse(s).Self.DNSName.replace(/\.$/,""))}catch{}})')"
    [ -n "$name" ] && public_url="https://$name"
  fi
  umask 077
  cat > "$ENV_FILE" <<EOF
# Burrow server settings. Keep this file private; it is not in git.
BURROW_SECRET_KEY=$(node "$REPO/apps/server/dist/cli.js" generate-secret)
BURROW_DATA_DIR=$DATA_DIR
BURROW_PORT=$PORT
BURROW_PUBLIC_URL=$public_url
BURROW_LANGUAGE=Dutch
GOOGLE_CLIENT_ID=
GOOGLE_CLIENT_SECRET=
MICROSOFT_CLIENT_ID=
MICROSOFT_CLIENT_SECRET=
EOF
  umask 022
fi

say "installing the systemd user units"
mkdir -p "$UNIT_DIR"
cat > "$UNIT_DIR/burrow.service" <<EOF
[Unit]
Description=Burrow server
After=network-online.target

[Service]
WorkingDirectory=$REPO/apps/server
EnvironmentFile=$ENV_FILE
# The triage runs the agent CLIs installed for this user.
Environment=PATH=$HOME/.local/bin:/usr/local/bin:/usr/bin:/bin
ExecStart=$(command -v node) dist/main.js
Restart=always
RestartSec=5

[Install]
WantedBy=default.target
EOF
cat > "$UNIT_DIR/burrow-backup.service" <<EOF
[Unit]
Description=Burrow database backup

[Service]
Type=oneshot
EnvironmentFile=$ENV_FILE
ExecStart=$REPO/infra/dobby/backup.sh
EOF
/bin/cp -f "$REPO/infra/dobby/burrow-backup.timer" "$UNIT_DIR/burrow-backup.timer"
systemctl --user daemon-reload
systemctl --user enable burrow.service burrow-backup.timer >/dev/null 2>&1
systemctl --user restart burrow.service
systemctl --user start burrow-backup.timer

say "waiting for the server"
for _ in $(seq 1 30); do health >/dev/null && break; sleep 1; done
health >/dev/null || fail "the server did not start; see: journalctl --user -u burrow -n 50"

if command -v tailscale >/dev/null; then
  say "publishing on the tailnet with tailscale serve"
  if ! tailscale serve --bg --https=443 "http://127.0.0.1:$PORT" >/dev/null 2>&1; then
    echo "  not allowed for this user; run once:  sudo tailscale serve --bg --https=443 http://127.0.0.1:$PORT"
  fi
fi

echo
status
