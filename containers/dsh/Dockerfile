# agentic-board dsh sandbox image (#773). dsh (DeepSeek Harness) runs ONLY in this image, never on
# the host. Build it from this folder:
#
#   docker build -t agentic-board/dsh:0.2.0-rc.2 containers/dsh
#
# Pinning: the base image by tag AND digest, dsh by exact version (package.json), and every
# transitive package by version + integrity (package-lock.json, installed with `npm ci`). Nothing
# here fetches an unpinned version: no @latest, no curl | sh, no apt-get.
# @deepseek-ai/dsh 0.2.0-rc.2 needs node >= 22.19.0 (a dependency's engines field).
FROM node:22.23.3-bookworm-slim@sha256:43ac6c60b8f89723f746e8a92ce91abd5017e627ce1ddfe4238355d3a30b772c AS build
WORKDIR /opt/abios-dsh
COPY package.json package-lock.json ./
RUN npm ci --omit=dev --no-audit --no-fund && npm cache clean --force

FROM node:22.23.3-bookworm-slim@sha256:43ac6c60b8f89723f746e8a92ce91abd5017e627ce1ddfe4238355d3a30b772c
COPY --from=build /opt/abios-dsh/node_modules /opt/abios-dsh/node_modules
COPY no-upload.patch.yml /opt/abios-dsh/no-upload.patch.yml
COPY --chmod=0755 entrypoint.sh /opt/abios-dsh/entrypoint.sh

# Image ENV is the "inherited process environment", the layer dsh trusts over any .env file.
#   DSH_HOME            on /tmp: the launch mounts /tmp as tmpfs, so dsh's session log, settings
#                       and anonymous id die with the container (no host home dir).
#   DSH_TELEMETRY_*     the documented opt-out (non-empty DISABLED), the mode, and an unreachable
#                       collector URL in case a future build ignores both.
#   DEEPSEEK_BASE_URL   pinned to the official endpoint, so nothing can redirect the API key.
#   DSH_PERMISSION_MODE dsh's own default, stated so it cannot come from anywhere else.
ENV PATH=/opt/abios-dsh/node_modules/.bin:$PATH \
    NODE_ENV=production \
    DSH_HOME=/tmp/dsh-home \
    DSH_TELEMETRY_DISABLED=1 \
    DSH_TELEMETRY_MODE=DISABLED \
    DSH_TELEMETRY_OTLP_URL=http://127.0.0.1:9/v1/logs \
    DEEPSEEK_BASE_URL=https://api.deepseek.com/anthropic \
    DSH_PERMISSION_MODE=workspace-write

# Fail the BUILD if the composed headless profile still mounts an uploader: the image never exists
# with the upload on (fail closed). --dump-config composes the layers without booting anything.
COPY check-upload-off.js /opt/abios-dsh/check-upload-off.js
RUN cd /tmp && DSH_HOME=/tmp/dsh-check dsh --patch /opt/abios-dsh/no-upload.patch.yml --profile headless --dump-config > /tmp/composed.yml \
 && node /opt/abios-dsh/check-upload-off.js < /tmp/composed.yml \
 && rm -rf /tmp/dsh-check /tmp/composed.yml

USER node
WORKDIR /work
ENTRYPOINT ["/opt/abios-dsh/entrypoint.sh"]
