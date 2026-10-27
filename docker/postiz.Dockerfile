# syntax=docker/dockerfile:1.7
#
# Postiz for ECS: one image for backend, MCP, frontend and both workers; the
# task definition picks the process (pnpm run start:prod:backend | frontend |
# orchestrator), the same commands Railway runs.
#
# Build context: a checkout of gitroomhq/postiz-app (see .github/workflows/deploy.yml).
# Node and pnpm versions follow its package.json (engines, packageManager).

# --- build -------------------------------------------------------------------------
FROM node:22.23.4-bookworm-slim AS build

RUN apt-get update \
 && apt-get install -y --no-install-recommends g++ make python3 ca-certificates openssl libudev-dev \
 && rm -rf /var/lib/apt/lists/*

RUN npm --no-update-notifier --no-fund --global install pnpm@10.6.1

WORKDIR /app

# Plain install, as on Railway: the root postinstall runs `pnpm dlx prisma`,
# which needs the network, so the `pnpm fetch` + offline-install split does not work.
COPY . /app
RUN pnpm install --frozen-lockfile

# NEXT_PUBLIC_* values are compiled into the browser bundle, so they must exist
# at build time (Railway passed the Frontend service variables to its build).
# They arrive as a BuildKit secret file of KEY='value' lines and never land in
# an image layer. NEXT_PUBLIC_VERSION stays unset: it marks self-hosted builds.
RUN --mount=type=secret,id=frontend_env,required=false \
    set -a \
 && if [ -f /run/secrets/frontend_env ]; then . /run/secrets/frontend_env; fi \
 && set +a \
 && NODE_OPTIONS="--max-old-space-size=6144" pnpm run build

# --- runtime ------------------------------------------------------------------------
# Same base, without the compiler toolchain and the pnpm store.
FROM node:22.23.4-bookworm-slim

# openssl: Prisma's query engine; libudev1: native USB/HID modules compiled above
RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates openssl libudev1 \
 && rm -rf /var/lib/apt/lists/* \
 && npm --no-update-notifier --no-fund --global install pnpm@10.6.1

WORKDIR /app
COPY --from=build /app /app

ENV NODE_ENV=production
CMD ["pnpm", "run", "start:prod:backend"]
