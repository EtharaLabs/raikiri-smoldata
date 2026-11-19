# syntax=docker/dockerfile:1@sha256:4edf897a3ffa55b89f906fc8cc78afdb3f1834cc9c7083565e611a8a7d5fe99e

FROM --platform=$BUILDPLATFORM docker.io/library/python:3.12-slim@sha256:05cda9777409a9c3ffddd94a4c476b79f0769a0b4857f0c7ed9226b6800b0d6f AS tree
ARG TARGETOS
ARG TARGETARCH
SHELL ["/bin/bash", "-o", "pipefail", "-c"]
WORKDIR /fetch
COPY src.tgz ./
RUN mkdir -p /tree && tar -xzf src.tgz -C /tree
# The tree stage is throwaway (only /tree/<project> leaves it), so prepare.sh is copied in plainly.
COPY scripts/prepare.sh /run/task-prepare.sh
RUN echo "471d74af04be19efef006c66d8dff734e9830d823becd5fd65710e2edd3a80ac  /run/task-prepare.sh" | sha256sum -c --quiet - \
 && bash /run/task-prepare.sh tree

FROM --platform=$BUILDPLATFORM docker.io/library/node:22-slim@sha256:c3de60bf2f9dd0ac6370e6117950ff62d6e339527e7472301c9c78a017978392 AS nodedeps
ARG TARGETOS
ARG TARGETARCH
SHELL ["/bin/bash", "-o", "pipefail", "-c"]
WORKDIR /fetch
COPY --from=tree /tree/fastify/./package.json /tree/fastify/./package-lock.json ./
RUN cpu="x64"; if [ "${TARGETARCH}" = "arm64" ]; then cpu="arm64"; fi \
 && npm ci --ignore-scripts --legacy-peer-deps --no-audit --no-fund --os=linux --cpu="${cpu}" \
 && node -e 'const fs = require("fs"); const cpu = process.argv[1]; const missing = Object.entries(require("./package-lock.json").packages || {}).filter(([k, v]) => k && v.optional && v.cpu && v.cpu.includes(cpu) && (!v.os || v.os.includes("linux")) && (!v.libc || v.libc.includes("glibc")) && !fs.existsSync(k)).map(([k]) => k); if (missing.length) { console.error("optional dependency not installed: " + missing.join(" ")); process.exit(1) }' "${cpu}"

FROM docker.io/library/node:22-slim@sha256:c3de60bf2f9dd0ac6370e6117950ff62d6e339527e7472301c9c78a017978392 AS node

# Throwaway stage (Kaniko-safe, no bind mounts): prepare.sh and the harness sources exist only here.
# The runtime stage copies out just what they produce, so prepare.sh never reaches the task image.
FROM docker.io/library/python:3.12-slim@sha256:05cda9777409a9c3ffddd94a4c476b79f0769a0b4857f0c7ed9226b6800b0d6f AS taskfiles
SHELL ["/bin/bash", "-o", "pipefail", "-c"]
COPY scripts/prepare.sh /run/task-prepare.sh
COPY scripts/compile.sh scripts/run_poc.sh scripts/test.sh scripts/mkpatch.sh /run/task-scripts/
COPY config/config.toml /run/task-config/config.toml
COPY install_validate_deps.sh /run/task-install_validate_deps.sh
RUN echo "471d74af04be19efef006c66d8dff734e9830d823becd5fd65710e2edd3a80ac  /run/task-prepare.sh" | sha256sum -c --quiet - \
 && bash /run/task-prepare.sh runtime \
 && printf '%s\n' "0a78957364ec8218bd43c17aeb9d238c50291e1a13d469a4a56ab2b2a72c9cd6  /run/task-scripts/compile.sh" \
        "39689c94f8799d0257e34d3cebdddf914bf7d6a602f80b0348530c3082c246d7  /run/task-scripts/run_poc.sh" \
        "ba5379aea89172017dbb4622d515b2c7068a76afc262870437d38eaa83d7b7df  /run/task-scripts/test.sh" \
        "b197bda806b1502a9611f259eacfc4ddd36f6edd0521b2825a279d5764237a48  /run/task-scripts/mkpatch.sh" \
        "42ce260aaa41ac6ea7f9293fc684dd04e43b6cc2033327277771a046a02919e3  /run/task-config/config.toml" \
        "419a4e01d9d0ed4dae4c027eeba3b2bff0026780ac842e02b1cc4fdc7b90e5ca  /run/task-install_validate_deps.sh" | sha256sum -c --quiet - \
 && install -d -o root -g root -m 0755 /opt/harness /opt/harness/scripts \
 && install -o root -g root -m 0755 /run/task-scripts/compile.sh /run/task-scripts/run_poc.sh /run/task-scripts/test.sh /run/task-scripts/mkpatch.sh /opt/harness/scripts/ \
 && install -o root -g root -m 0644 /run/task-config/config.toml /opt/harness/config.toml \
 && install -o root -g root -m 0755 /run/task-install_validate_deps.sh /opt/harness/install_validate_deps.sh

FROM docker.io/library/python:3.12-slim@sha256:05cda9777409a9c3ffddd94a4c476b79f0769a0b4857f0c7ed9226b6800b0d6f AS runtime
SHELL ["/bin/bash", "-o", "pipefail", "-c"]
RUN . /etc/os-release \
 && rm -f /etc/apt/sources.list.d/debian.sources \
 && printf 'deb [check-valid-until=no] https://snapshot.debian.org/archive/debian/20261001T000000Z %s main\n' "$VERSION_CODENAME" > /etc/apt/sources.list \
 && apt-get update \
 && apt-get install -y --no-install-recommends git=1:2.47.3-0+deb13u1 patch=2.8-2 \
 && rm -rf /var/lib/apt/lists/*
RUN groupadd --gid 1000 agent \
 && useradd --uid 1000 --gid 1000 --create-home --shell /bin/bash agent \
 && install -d -o 1000 -g 1000 -m 0755 /output /src
RUN install -d -o root -g root -m 0755 /opt/task
COPY --from=tree --chown=root:root /tree/fastify /opt/pristine/fastify
COPY --from=tree --chown=1000:1000 /tree/fastify /src/fastify
COPY --from=node /usr/local/bin/node /usr/local/bin/node
COPY --from=node /usr/local/lib/node_modules /usr/local/lib/node_modules
RUN ln -s ../lib/node_modules/npm/bin/npm-cli.js /usr/local/bin/npm \
 && ln -s ../lib/node_modules/npm/bin/npx-cli.js /usr/local/bin/npx
COPY --from=nodedeps --chown=root:root /fetch/node_modules /opt/deps/node_modules
RUN ln -s /opt/deps/node_modules /src/fastify/node_modules \
 && ln -s /opt/deps/node_modules /opt/pristine/fastify/node_modules
# prepare.sh's runtime files and the reproduction/regression harness (golden layout: config/,
# install_validate_deps.sh, scripts/) come from the throwaway taskfiles stage, where every file's
# sha256 was verified; they are installed read-only and prepare.sh itself never enters this image.
COPY --from=taskfiles /opt/task/ /opt/task/
COPY --from=taskfiles /usr/local/bin/make-deliverables /usr/local/bin/check-reproducer /usr/local/bin/
COPY --from=taskfiles /opt/harness/ /opt/harness/
RUN ln -sf /opt/harness/scripts/compile.sh /usr/local/bin/build.sh \
 && ln -sf /opt/harness/scripts/run_poc.sh /usr/local/bin/run_poc.sh \
 && ln -sf /opt/harness/scripts/test.sh /usr/local/bin/regression.sh \
 && ln -sf /opt/harness/scripts/mkpatch.sh /usr/local/bin/mkpatch.sh \
 && /opt/harness/install_validate_deps.sh
ENV HOME=/home/agent \
    PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
    PYTHONDONTWRITEBYTECODE=1
WORKDIR /src/fastify
LABEL org.opencontainers.image.source="https://github.com/fastify/fastify" \
      org.opencontainers.image.revision="93c239a380f3f2778bb7565fcdf777e91cfe1fbc" \
      org.opencontainers.image.licenses="MIT" \
      org.opencontainers.image.base.name="docker.io/library/python:3.12-slim" \
      org.opencontainers.image.base.digest="sha256:05cda9777409a9c3ffddd94a4c476b79f0769a0b4857f0c7ed9226b6800b0d6f"

# --------------------------------------------------------------------------- #
# Prebaked OpenHands-SDK agent runtime (offline agent setup; TR-P1).
# Harbor's openhands-sdk agent begins setup with:
#   [ -f /opt/openhands-sdk-venv/bin/python ] && \
#     /opt/openhands-sdk-venv/bin/python -c "import openhands.sdk"
# and skips its network install when that succeeds. Baking the venv here means the
# agent phase performs no public-network package fetch; the only runtime egress left
# is the model endpoint (LLM_BASE_URL), admitted via --allow-agent-host. Versions are
# pinned (openhands-sdk/tools 1.58.1, Python 3.12.15); the uv cache is removed in-layer.
# The venv is world-readable so the uid-1000 agent can import it.
# --------------------------------------------------------------------------- #
USER 0
RUN apt-get update && apt-get install -y --no-install-recommends curl=8.14.1-2+deb13u5 ca-certificates=20250419 \
    && rm -rf /var/lib/apt/lists/*
ENV UV_PYTHON_INSTALL_DIR=/opt/uv/python
# uv comes from its digest-pinned image; locks/openhands-sdk.txt pins every package by sha256.
COPY --from=ghcr.io/astral-sh/uv:0.13.5@sha256:32a7bb39b496babbd997b0a39a4d66c126bdaf5661b302bf6f06abda8deca6ff /uv /uvx /usr/local/bin/
COPY locks/openhands-sdk.txt /tmp/openhands-sdk.txt
RUN set -eux; \
    uv python install 3.12.15; \
    uv venv /opt/openhands-sdk-venv --python 3.12.15; \
    uv pip install --no-cache --require-hashes --python /opt/openhands-sdk-venv/bin/python \
        -r /tmp/openhands-sdk.txt; \
    rm -f /tmp/openhands-sdk.txt; \
    chmod -R a+rX /opt/uv /opt/openhands-sdk-venv; \
    /opt/openhands-sdk-venv/bin/python -c "import openhands.sdk; assert openhands.sdk.__version__ == '1.58.1', openhands.sdk.__version__; print('openhands.sdk', openhands.sdk.__version__)"; \
    rm -rf /root/.cache/uv /home/agent/.cache/uv /tmp/uv-*.lock; \
    install -d -o 1000 -g 1000 -m 0755 /home/agent/.cache /home/agent/.config /home/agent/.local; \
    chown 1000:1000 /home/agent/.cache; chown -R 1000:1000 /home/agent/.config /home/agent/.local

USER 0
CMD ["/bin/bash"]
