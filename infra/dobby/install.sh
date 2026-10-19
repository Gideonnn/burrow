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
#      BURROW_SECRET_KEY; later runs keep it;
#   4. installs and (re)starts the burrow.service and the nightly backup timer;
#   5. runs the Cloudflare Tunnel as burrow-tunnel.service once the tunnel
#      settings hold TUNNEL_TOKEN (installs cloudflared into ~/.local/bin
#      when missing);
#   6. installs ffmpeg and ffprobe into ~/.local/bin when missing, for
#      Pensieve (a static build, checked against its published SHA-256).
#
# Secrets stay on this machine: the env file is never printed or copied.
set -euo pipefail

REPO="$(cd "$(dirname "$0")/../.." && pwd)"
CONFIG_DIR="$HOME/.config/burrow"
ENV_FILE="$CONFIG_DIR/burrow.env"
# Apart from the server settings, so the server and its agents never see it.
TUNNEL_ENV="$CONFIG_DIR/tunnel.env"
DATA_DIR="$HOME/.local/share/burrow"
UNIT_DIR="$HOME/.config/systemd/user"
LOG_DIR="$HOME/.local/state/burrow"
PORT=4717
TUNNEL_PORT=4718
export PATH="$HOME/.local/bin:$PATH"

say() { printf '\033[1m→ %s\033[0m\n' "$*"; }
fail() { printf '\033[31m✗ %s\033[0m\n' "$*" >&2; exit 1; }

health() { curl -fsS "http://127.0.0.1:$PORT/health" 2>/dev/null; }

status() {
  systemctl --user --no-pager status burrow.service 2>/dev/null | sed -n 1,5p || true
  if health >/dev/null; then echo "health: $(health)"; else echo "health: not answering"; fi
  echo
  echo "Next steps:"
  echo "  first person and admin key:  $REPO/infra/dobby/cli.sh init <name>"
  echo "  logs:                         tail -f $LOG_DIR/server.log"
  echo "  Google/Microsoft accounts:    add the client ids to $ENV_FILE, then rerun this script"
  echo "  public access:                see the deploy topic (Cloudflare Tunnel and Access)"
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

if ! command -v ffmpeg >/dev/null || ! command -v ffprobe >/dev/null; then
  [ "$(uname -m)" = x86_64 ] || fail "install ffmpeg yourself on $(uname -m), then rerun"
  say "installing ffmpeg into ~/.local/bin (for Pensieve)"
  base="https://github.com/BtbN/FFmpeg-Builds/releases/download/latest"
  work="$(mktemp -d)"
  curl -fsSL -o "$work/checksums.sha256" "$base/checksums.sha256"
  # The newest release branch, not the daily master build.
  file="$(grep -oE 'ffmpeg-n[0-9.]+-latest-linux64-gpl-[0-9.]+\.tar\.xz$' "$work/checksums.sha256" | sort -V | tail -1)"
  [ -n "$file" ] || fail "no ffmpeg build found in the checksums"
  curl -fsSL -o "$work/$file" "$base/$file"
  (cd "$work" && grep " $file\$" checksums.sha256 | sha256sum -c --quiet -) || fail "the ffmpeg download does not match its checksum"
  tar -xJf "$work/$file" -C "$work"
  mkdir -p "$HOME/.local/bin"
  install -m 755 "$work"/ffmpeg-*/bin/ffmpeg "$work"/ffmpeg-*/bin/ffprobe "$HOME/.local/bin/"
  rm -rf "$work"
fi

say "installing dependencies and building"
cd "$REPO"
pnpm install --frozen-lockfile --filter @burrow/server... >/dev/null
pnpm --filter @burrow/server build >/dev/null

if [ ! -f "$ENV_FILE" ]; then
  say "writing $ENV_FILE (first install)"
  mkdir -p "$CONFIG_DIR" "$DATA_DIR"
  umask 077
  cat > "$ENV_FILE" <<EOF
# Burrow server settings. Keep this file private; it is not in git.
BURROW_SECRET_KEY=$(node "$REPO/apps/server/dist/cli.js" generate-secret)
BURROW_DATA_DIR=$DATA_DIR
BURROW_PORT=$PORT
# The public hostname of the Cloudflare Tunnel, e.g. https://burrow.example.com
BURROW_PUBLIC_URL=http://127.0.0.1:$PORT
BURROW_LANGUAGE=Dutch
GOOGLE_CLIENT_ID=
GOOGLE_CLIENT_SECRET=
MICROSOFT_CLIENT_ID=
MICROSOFT_CLIENT_SECRET=
CLOUDFLARE_ACCESS_TEAM=
CLOUDFLARE_ACCESS_AUD=
# Pensieve transcribes recordings through OpenAI.
OPENAI_API_KEY=
# Shown on the public /privacy and /terms pages.
BURROW_CONTACT_EMAIL=
EOF
  umask 022
fi

say "installing the systemd user units"
mkdir -p "$UNIT_DIR" "$LOG_DIR"
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
# The user journal is not readable on every machine, so the log is a file too.
StandardOutput=append:$LOG_DIR/server.log
StandardError=append:$LOG_DIR/server.log
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
health >/dev/null || fail "the server did not start; see: tail -n 50 $LOG_DIR/server.log"

if grep -q '^TUNNEL_TOKEN=..*' "$TUNNEL_ENV" 2>/dev/null; then
  say "running the Cloudflare Tunnel"
  if ! command -v cloudflared >/dev/null; then
    case "$(uname -m)" in
      x86_64) arch=amd64 ;;
      aarch64 | arm64) arch=arm64 ;;
      *) fail "no cloudflared build for $(uname -m)" ;;
    esac
    mkdir -p "$HOME/.local/bin"
    curl -fsSL -o "$HOME/.local/bin/cloudflared" \
      "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-$arch"
    chmod +x "$HOME/.local/bin/cloudflared"
  fi
  grep -q '^CLOUDFLARE_ACCESS_AUD=..*' "$ENV_FILE" ||
    echo "  CLOUDFLARE_ACCESS_TEAM and _AUD are empty in $ENV_FILE: nothing listens on $TUNNEL_PORT yet"
  cat > "$UNIT_DIR/burrow-tunnel.service" <<EOF
[Unit]
Description=Cloudflare Tunnel to the Burrow server
After=network-online.target burrow.service

[Service]
EnvironmentFile=$TUNNEL_ENV
ExecStart=$(command -v cloudflared) tunnel --no-autoupdate run
StandardOutput=append:$LOG_DIR/tunnel.log
StandardError=append:$LOG_DIR/tunnel.log
Restart=always
RestartSec=5

[Install]
WantedBy=default.target
EOF
  systemctl --user daemon-reload
  systemctl --user enable burrow-tunnel.service >/dev/null 2>&1
  systemctl --user restart burrow-tunnel.service
  echo "  started; log: $LOG_DIR/tunnel.log"
fi

echo
status
