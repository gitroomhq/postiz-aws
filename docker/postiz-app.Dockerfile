# syntax=docker/dockerfile:1.7
#
# Postiz on ECS, one slim image per app, built from a checkout of
# gitroomhq/postiz-app. postiz-app itself is not changed: its all-in-one image
# stays the easy path for self-hosters.
#
#   --target frontend      Next standalone server (enabled by a config wrapper below)
#   --target backend       backend build + only the files main.js loads; also runs mcp
#   --target orchestrator  orchestrator build + only the files main.js loads (workers)
#   --target migrate       Prisma CLI + schema.prisma, for the db push task
#
# The apps declare no dependencies of their own (postiz-app keeps all 270 in the
# root package.json), so pnpm cannot prune per app: the backend and orchestrator
# images keep what @vercel/nft traces from their entrypoint, plus the generated
# Prisma client, whose query engine is loaded by a computed path.
# Node and pnpm versions follow postiz-app's package.json (engines, packageManager).

ARG NODE_IMAGE=node:22.23.4-bookworm-slim

# --- dependencies, shared by the app builds -------------------------------------------
FROM ${NODE_IMAGE} AS deps
RUN apt-get update \
 && apt-get install -y --no-install-recommends g++ make python3 ca-certificates openssl libudev-dev \
 && rm -rf /var/lib/apt/lists/* \
 && npm --no-update-notifier --no-fund --global install pnpm@10.6.1
WORKDIR /app
# Plain install, as on Railway: the root postinstall runs `pnpm dlx prisma generate`,
# which needs the network.
COPY . /app
RUN pnpm install --frozen-lockfile

# --- frontend ---------------------------------------------------------------------------
FROM deps AS frontend-build
# Standalone output without touching postiz-app's next.config.js: wrap it. The
# tracing root is the monorepo, so libraries/* and the hoisted packages are included.
RUN mv apps/frontend/next.config.js apps/frontend/next.config.postiz.js
COPY <<'EOF' /app/apps/frontend/next.config.js
import { fileURLToPath } from 'node:url';
import postiz from './next.config.postiz.js';

const aws = {
  output: 'standalone',
  outputFileTracingRoot: fileURLToPath(new URL('../../', import.meta.url)),
};

export default typeof postiz === 'function'
  ? async (...args) => ({ ...(await postiz(...args)), ...aws })
  : { ...postiz, ...aws };
EOF
# NEXT_PUBLIC_* values are compiled into the browser bundle: they come in as a
# BuildKit secret file of KEY='value' lines and never land in an image layer.
RUN --mount=type=secret,id=frontend_env,required=false \
    set -a \
 && if [ -f /run/secrets/frontend_env ]; then . /run/secrets/frontend_env; fi \
 && set +a \
 && NODE_OPTIONS="--max-old-space-size=6144" pnpm --filter ./apps/frontend run build

FROM ${NODE_IMAGE} AS frontend
WORKDIR /app
COPY --from=frontend-build /app/apps/frontend/.next/standalone ./
COPY --from=frontend-build /app/apps/frontend/.next/static ./apps/frontend/.next/static
COPY --from=frontend-build /app/apps/frontend/public ./apps/frontend/public
ENV NODE_ENV=production PORT=4200 HOSTNAME=0.0.0.0
WORKDIR /app/apps/frontend
CMD ["node", "server.js"]

# --- tracing for the Nest apps -----------------------------------------------------------
FROM deps AS trace
RUN npm --no-update-notifier --no-fund install --prefix /trace @vercel/nft@1.11.0
# Copies what the entrypoints load (comma-separated), plus whole extra
# directories, into OUT with /app's layout and any symlinks intact. Prints the
# tracer's warnings (loads it could not resolve) so a build log shows them.
COPY <<'EOF' /trace/trace.mjs
import { nodeFileTrace } from '@vercel/nft';
import { copyFile, lstat, mkdir, readdir, readFile, readlink, symlink } from 'node:fs/promises';
import { dirname, join, relative } from 'node:path';

const [entries, out, cwd, ...extra] = process.argv.slice(2);
const entry = entries.split(',');
const base = '/app';
const { fileList, warnings } = await nodeFileTrace(entry, { base, processCwd: cwd, mixedModules: true });
const files = new Set(fileList);
for (const w of warnings) console.log(`trace warning: ${String(w.message || w).split('\n')[0]}`);

async function walk(dir) {
  for (const e of await readdir(dir, { withFileTypes: true })) {
    const p = join(dir, e.name);
    if (e.isDirectory()) await walk(p);
    else files.add(relative(base, p));
  }
}
// extra: directories to copy whole, or @file with one absolute path per line
// (only its files: webpack also lists directories it watched, like node_modules)
for (const x of extra) {
  if (x.startsWith('@')) {
    for (const p of (await readFile(x.slice(1), 'utf8')).split('\n')) {
      if (!p.startsWith(base + '/')) continue;
      const st = await lstat(p).catch(() => null);
      if (st && !st.isDirectory()) files.add(relative(base, p));
    }
  } else {
    await walk(join(base, x));
  }
}

let links = 0;
for (const f of files) {
  const src = join(base, f);
  const dst = join(out, f);
  await mkdir(dirname(dst), { recursive: true });
  const st = await lstat(src);
  if (st.isSymbolicLink()) {
    links++;
    await symlink(await readlink(src), dst).catch((e) => { if (e.code !== 'EEXIST') throw e; });
  } else if (st.isFile()) {
    await copyFile(src, dst);
  }
}
console.log(`traced ${entry}: ${files.size} files (${links} symlinks), ${warnings.size} warnings`);
EOF
# Bundles the workflows exactly as the workers' Temporal SDK does at startup and
# prints every file webpack read: the workflow bundle resolves packages through
# their ESM entries, which a require() trace does not follow.
COPY <<'EOF' /trace/workflow-files.mjs
import { createRequire } from 'node:module';
import { join, resolve } from 'node:path';

const require = createRequire(join(process.cwd(), 'package.json'));
const { bundleWorkflowCode } = require('@temporalio/worker');
const files = new Set();
await bundleWorkflowCode({
  workflowsPath: resolve(process.argv[2]),
  logger: { trace() {}, debug() {}, info() {}, warn() {}, error: (m) => console.error(m) },
  webpackConfigHook: (config) => {
    config.plugins = [...(config.plugins || []), {
      apply: (compiler) => compiler.hooks.done.tap('workflow-files', (stats) => {
        if (stats.hasErrors()) throw new Error(stats.toString({ errorDetails: false, all: false, errors: true }));
        for (const f of stats.compilation.fileDependencies) files.add(f);
      }),
    }];
    return config;
  },
});
console.log([...files].join('\n'));
EOF

# node_modules is hoisted (postiz-app's .npmrc: node-linker=hoisted), so the
# generated Prisma client and its query engine live in node_modules/.prisma.
FROM trace AS backend-build
RUN NODE_OPTIONS="--max-old-space-size=6144" pnpm --filter ./apps/backend run build \
 && node /trace/trace.mjs apps/backend/dist/apps/backend/src/main.js /out /app/apps/backend \
      node_modules/.prisma

# The workers' Temporal SDK bundles the workflow code with webpack when it starts,
# reading those files from disk rather than requiring them: add every file that
# bundling reads (workflow-files.mjs), or tslib, @temporalio/workflow, ... are missing.
FROM trace AS orchestrator-build
RUN NODE_OPTIONS="--max-old-space-size=6144" pnpm --filter ./apps/orchestrator run build \
 && (cd apps/orchestrator && node /trace/workflow-files.mjs ./dist/apps/orchestrator/src/workflows > /tmp/workflow-files.txt) \
 && echo "workflow bundle reads $(wc -l < /tmp/workflow-files.txt) files" \
 && node /trace/trace.mjs \
      apps/orchestrator/dist/apps/orchestrator/src/main.js,apps/orchestrator/dist/apps/orchestrator/src/workflows/index.js \
      /out /app/apps/orchestrator node_modules/.prisma @/tmp/workflow-files.txt

# --- runtime for the Nest apps (openssl: Prisma's engine; libudev1: native HID modules) --
FROM ${NODE_IMAGE} AS nest-runtime
RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates openssl libudev1 \
 && rm -rf /var/lib/apt/lists/*
ENV NODE_ENV=production

FROM nest-runtime AS backend
COPY --from=backend-build /out /app
WORKDIR /app/apps/backend
CMD ["node", "--experimental-require-module", "./dist/apps/backend/src/main.js"]

FROM nest-runtime AS orchestrator
COPY --from=orchestrator-build /out /app
WORKDIR /app/apps/orchestrator
CMD ["node", "--experimental-require-module", "./dist/apps/orchestrator/src/main.js"]

# --- prisma db push (the Railway pre-deploy command) --------------------------------------
FROM ${NODE_IMAGE} AS migrate
RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates openssl \
 && rm -rf /var/lib/apt/lists/* \
 && npm --no-update-notifier --no-fund --global install prisma@6.5.0
WORKDIR /app
COPY libraries/nestjs-libraries/src/database/prisma/schema.prisma ./schema.prisma
# --skip-generate: no client to generate here; the app images carry their own.
CMD ["prisma", "db", "push", "--schema", "./schema.prisma", "--skip-generate"]
