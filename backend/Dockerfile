# Multi-stage build — the runtime image ships only compiled JS + prod
# dependencies, never the TypeScript source, dev tooling, or test files.
# Matches docs/AUDIT.md / the Hostinger deployment model: container
# listens on 0.0.0.0:3000 internally; the host maps a loopback-only port
# to it (nginx or, for VPS-IP testing, direct access via UFW) — this
# image never decides its own public exposure.
#
# node:22-alpine (Phase 18) — Node 20 reached end-of-life 2026-04-30
# (confirmed via current official Node.js release schedule, not assumed);
# 22 is the current Active LTS (EOL 2027-04-30). engines.node in
# package.json (">=18.18.0") is a floor, not a pin, so this doesn't need
# to change alongside it.

FROM node:22-alpine AS builder
WORKDIR /app
COPY package.json package-lock.json ./
RUN npm ci
COPY tsconfig.json ./
COPY src ./src
RUN npm run build

FROM node:22-alpine AS runtime
WORKDIR /app
ENV NODE_ENV=production
ENV PORT=3000
ENV HOST=0.0.0.0
COPY package.json package-lock.json ./
RUN npm ci --omit=dev && npm cache clean --force
COPY --from=builder /app/dist ./dist
# Run as a non-root user — the node:alpine image already ships one.
USER node
EXPOSE 3000
CMD ["node", "dist/src/server.js"]
