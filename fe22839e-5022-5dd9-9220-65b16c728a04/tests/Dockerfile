# syntax=docker/dockerfile:1@sha256:4edf897a3ffa55b89f906fc8cc78afdb3f1834cc9c7083565e611a8a7d5fe99e

FROM --platform=$BUILDPLATFORM docker.io/library/python:3.12-slim@sha256:05cda9777409a9c3ffddd94a4c476b79f0769a0b4857f0c7ed9226b6800b0d6f AS tree
ARG TARGETOS
ARG TARGETARCH
SHELL ["/bin/bash", "-o", "pipefail", "-c"]
WORKDIR /fetch
RUN . /etc/os-release \
 && rm -f /etc/apt/sources.list.d/debian.sources \
 && printf 'deb [check-valid-until=no] https://snapshot.debian.org/archive/debian/20261001T000000Z %s main\n' "$VERSION_CODENAME" > /etc/apt/sources.list \
 && apt-get update \
 && apt-get install -y --no-install-recommends git=1:2.47.3-0+deb13u1 \
 && rm -rf /var/lib/apt/lists/*
COPY validate.py ./
RUN python3 validate.py --materialize-build-assets . /fetch/overlay/0
RUN base64 -d src.tgz.b64 > src.tgz \
 && mkdir -p /grade && tar -xzf src.tgz -C /grade \
 && cp /fetch/overlay/0 /grade/fast-uri/package-lock.json \
 && git -C /grade/fast-uri init -q . && git -C /grade/fast-uri add -A \
 && git -C /grade/fast-uri -c user.email=grader@localhost -c user.name=grader commit -q -m pristine

FROM --platform=$BUILDPLATFORM docker.io/library/node:22-slim@sha256:c3de60bf2f9dd0ac6370e6117950ff62d6e339527e7472301c9c78a017978392 AS nodedeps
ARG TARGETOS
ARG TARGETARCH
SHELL ["/bin/bash", "-o", "pipefail", "-c"]
WORKDIR /fetch
COPY --from=tree /grade/fast-uri/./package.json /grade/fast-uri/./package-lock.json ./
RUN cpu="x64"; if [ "${TARGETARCH}" = "arm64" ]; then cpu="arm64"; fi \
 && npm ci --ignore-scripts --legacy-peer-deps --no-audit --no-fund --os=linux --cpu="${cpu}" \
 && node -e 'const fs = require("fs"); const cpu = process.argv[1]; const missing = Object.entries(require("./package-lock.json").packages || {}).filter(([k, v]) => k && v.optional && v.cpu && v.cpu.includes(cpu) && (!v.os || v.os.includes("linux")) && (!v.libc || v.libc.includes("glibc")) && !fs.existsSync(k)).map(([k]) => k); if (missing.length) { console.error("optional dependency not installed: " + missing.join(" ")); process.exit(1) }' "${cpu}"

FROM docker.io/library/node:22-slim@sha256:c3de60bf2f9dd0ac6370e6117950ff62d6e339527e7472301c9c78a017978392 AS node

FROM docker.io/library/python:3.12-slim@sha256:05cda9777409a9c3ffddd94a4c476b79f0769a0b4857f0c7ed9226b6800b0d6f AS runtime
SHELL ["/bin/bash", "-o", "pipefail", "-c"]
RUN . /etc/os-release \
 && rm -f /etc/apt/sources.list.d/debian.sources \
 && printf 'deb [check-valid-until=no] https://snapshot.debian.org/archive/debian/20261001T000000Z %s main\n' "$VERSION_CODENAME" > /etc/apt/sources.list \
 && apt-get update \
 && apt-get install -y --no-install-recommends git=1:2.47.3-0+deb13u1 patch=2.8-2 \
 && rm -rf /var/lib/apt/lists/*
RUN groupadd --gid 1001 verifier \
 && useradd --uid 1001 --gid 1001 --create-home --shell /bin/bash verifier \
 && install -d -o 1001 -g 1001 -m 0755 /output /grade
COPY --from=tree --chown=1001:1001 /grade/fast-uri /grade/fast-uri
COPY --from=node /usr/local/bin/node /usr/local/bin/node
COPY --from=node /usr/local/lib/node_modules /usr/local/lib/node_modules
RUN ln -s ../lib/node_modules/npm/bin/npm-cli.js /usr/local/bin/npm \
 && ln -s ../lib/node_modules/npm/bin/npx-cli.js /usr/local/bin/npx
COPY --from=nodedeps --chown=root:root /fetch/node_modules /opt/deps/node_modules
# system-pytest-for-grader: the sandboxed grader runs the pytest oracle with the image
# python, so pytest must be importable there (the reference installs it the same way).
RUN ln -s /opt/deps/node_modules /grade/fast-uri/node_modules \
 && pip install --no-cache-dir "pytest==8.3.5"

# --------------------------------------------------------------------------- #

# Verifier reward toolchain (ported to the reference contract).
# RewardKit grades the ported tests/reward/ channels; the codex CLI hosts the GPT 6.1 Sol judge.
# --------------------------------------------------------------------------- #
RUN apt-get update && apt-get install -y --no-install-recommends curl=8.14.1-2+deb13u5 ca-certificates=20250419 \
    && rm -rf /var/lib/apt/lists/*
RUN curl -fsSL https://astral.sh/uv/0.13.5/install.sh \
      | env UV_INSTALL_DIR=/usr/local/bin sh \
    && export UV_PYTHON_INSTALL_DIR=/opt/rewardkit/python UV_NO_PROGRESS=1 \
    && uv python install "3.13.17" \
    && uv venv --python "3.13.17" /opt/rewardkit/.venv \
    && uv pip install --python /opt/rewardkit/.venv/bin/python \
         "harbor-rewardkit==0.2.3" "pytest==8.3.5" \
    && /opt/rewardkit/.venv/bin/python -c "import rewardkit, pytest; import importlib.metadata as md; assert md.version('harbor-rewardkit') == '0.2.3'" \
    && /opt/rewardkit/.venv/bin/rewardkit --help >/dev/null
ENV PATH="/opt/rewardkit/.venv/bin:${PATH}"

RUN set -eux; \
    npm install -g "@openai/codex@0.169.0"; \
    npm cache clean --force; \
    codex --version

COPY . /tests
RUN chmod +x /tests/test.sh
WORKDIR /
ENV HOME=/home/verifier \
    PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
    PYTHONDONTWRITEBYTECODE=1
WORKDIR /tests
LABEL org.opencontainers.image.source="https://github.com/fastify/fast-uri" \
      org.opencontainers.image.revision="a34ced25d015d12dfc2b0cf85ce01a4a0d12ecf6" \
      org.opencontainers.image.licenses="BSD-3-Clause" \
      org.opencontainers.image.base.name="docker.io/library/python:3.12-slim" \
      org.opencontainers.image.base.digest="sha256:05cda9777409a9c3ffddd94a4c476b79f0769a0b4857f0c7ed9226b6800b0d6f"
USER 0
CMD ["/bin/bash"]
