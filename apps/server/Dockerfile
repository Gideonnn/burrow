# The Burrow server. Build from the repository root:
#   docker build -f apps/server/Dockerfile -t burrow-server .

FROM node:22-bookworm-slim AS build
# better-sqlite3 compiles a native module.
RUN apt-get update && apt-get install -y --no-install-recommends python3 make g++ \
  && rm -rf /var/lib/apt/lists/*
RUN corepack enable
WORKDIR /repo
COPY pnpm-lock.yaml pnpm-workspace.yaml package.json ./
COPY apps/server/package.json apps/server/
COPY modules/hedwig/package.json modules/hedwig/
COPY modules/pensieve/package.json modules/pensieve/
COPY packages/contracts/package.json packages/contracts/
COPY packages/platform/package.json packages/platform/
RUN pnpm install --frozen-lockfile --filter @burrow/server...
COPY tsconfig.base.json ./
COPY apps/server apps/server
COPY modules modules
COPY packages packages
RUN pnpm --filter @burrow/server build \
  && pnpm --filter @burrow/server deploy --prod /out \
  && cp -R apps/server/dist /out/dist

FROM node:22-bookworm-slim
# The agent CLIs the triage runs through. They log in once, interactively,
# into the volumes below (see the deploy topic).
RUN npm install -g @anthropic-ai/claude-code @openai/codex && npm cache clean --force
WORKDIR /app
COPY --from=build /out/node_modules node_modules
COPY --from=build /out/dist dist
COPY --from=build /out/package.json package.json
COPY bots bots
COPY skills skills
RUN mkdir -p /data /home/node/.claude /home/node/.codex && chown -R node:node /data /home/node
USER node
ENV NODE_ENV=production \
    BURROW_HOST=0.0.0.0 \
    BURROW_PORT=4717 \
    BURROW_DATA_DIR=/data \
    BURROW_BOTS_DIRS=/app/bots:/data/bots \
    BURROW_SKILLS_DIRS=/app/skills:/data/skills
VOLUME ["/data", "/home/node/.claude", "/home/node/.codex"]
EXPOSE 4717
HEALTHCHECK --interval=30s --timeout=5s --start-period=20s \
  CMD node -e "fetch('http://127.0.0.1:4717/health').then(r=>process.exit(r.ok?0:1)).catch(()=>process.exit(1))"
CMD ["node", "dist/main.js"]
