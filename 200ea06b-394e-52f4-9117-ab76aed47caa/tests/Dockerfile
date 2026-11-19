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
 && cp /fetch/overlay/0 /grade/fastify/package-lock.json \
 && git -C /grade/fastify init -q . && git -C /grade/fastify add -A \
 && git -C /grade/fastify -c user.email=grader@localhost -c user.name=grader commit -q -m pristine

FROM --platform=$BUILDPLATFORM docker.io/library/node:22-slim@sha256:c3de60bf2f9dd0ac6370e6117950ff62d6e339527e7472301c9c78a017978392 AS nodedeps
ARG TARGETOS
ARG TARGETARCH
SHELL ["/bin/bash", "-o", "pipefail", "-c"]
WORKDIR /fetch
COPY --from=tree /grade/fastify/./package.json /grade/fastify/./package-lock.json ./
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
COPY --from=tree --chown=1001:1001 /grade/fastify /grade/fastify
COPY --from=node /usr/local/bin/node /usr/local/bin/node
COPY --from=node /usr/local/lib/node_modules /usr/local/lib/node_modules
RUN ln -s ../lib/node_modules/npm/bin/npm-cli.js /usr/local/bin/npm \
 && ln -s ../lib/node_modules/npm/bin/npx-cli.js /usr/local/bin/npx
COPY --from=nodedeps --chown=root:root /fetch/node_modules /opt/deps/node_modules
# system-pytest-for-grader: the sandboxed grader runs the pytest oracle with the image
# python, so pytest must be importable there (the reference installs it the same way).
COPY locks/pytest.txt /tmp/locks/pytest.txt
RUN ln -s /opt/deps/node_modules /grade/fastify/node_modules \
 && pip install --no-cache-dir --require-hashes --no-deps -r /tmp/locks/pytest.txt

# --------------------------------------------------------------------------- #

# Verifier reward toolchain (ported to the reference contract).
# RewardKit grades the ported tests/reward/ channels; the codex CLI hosts the GPT 6.1 Sol judge.
# --------------------------------------------------------------------------- #
RUN apt-get update && apt-get install -y --no-install-recommends curl=8.14.1-2+deb13u5 ca-certificates=20250419 \
    && rm -rf /var/lib/apt/lists/*
# uv comes from its digest-pinned image; locks/rewardkit.txt pins every package by sha256.
COPY --from=ghcr.io/astral-sh/uv:0.13.5@sha256:32a7bb39b496babbd997b0a39a4d66c126bdaf5661b302bf6f06abda8deca6ff /uv /uvx /usr/local/bin/
COPY locks/rewardkit.txt /tmp/locks/rewardkit.txt
RUN export UV_PYTHON_INSTALL_DIR=/opt/rewardkit/python UV_NO_PROGRESS=1 \
    && uv python install "3.13.17" \
    && uv venv --python "3.13.17" /opt/rewardkit/.venv \
    && uv pip install --require-hashes --python /opt/rewardkit/.venv/bin/python -r /tmp/locks/rewardkit.txt \
    && rm -rf /tmp/locks \
    && /opt/rewardkit/.venv/bin/python -c "import rewardkit, pytest; import importlib.metadata as md; assert md.version('harbor-rewardkit') == '0.2.3'" \
    && /opt/rewardkit/.venv/bin/rewardkit --help >/dev/null

# Rubric judge: the codex CLI tarballs come from the npm registry, each checked against its
# published sha512. Node is the digest-pinned node:22-slim copied above. At run time the
# verifier reaches only the host codex bridge.
RUN set -eux; \
    dpkg_arch="$(dpkg --print-architecture)"; \
    case "$dpkg_arch" in \
      arm64) codex_arch="linux-arm64"; codex_arch_sha512="359fc36905297109b19aa79eed9f6e0b5af3c371a149ba286b071a4ded4b379624f969629d42867535c98029514fff6881010433d4d6c58cefc4f7e3e46ff116" ;; \
      amd64) codex_arch="linux-x64"; codex_arch_sha512="a34e4dc803820f28123d1a35ca29f3c6f91149d9ac672043f44ee66e99a345a9d27ccf25ca9a96b50804a385df364c21b82476685bbc9a518eb101855d56d5c3" ;; \
      *) echo "unsupported architecture: $dpkg_arch" >&2; exit 1 ;; \
    esac; \
    codex_main_sha512="2a1cd896428fc6836cb11f02126e39223aa71569fb52d945e02883ded3893de6b9d7106cecc687cb45101bd1926c2aa4e8bae39f941d243574403d7f1605a51b"; \
    curl -fsSLo /tmp/codex.tgz "https://registry.npmjs.org/@openai/codex/-/codex-0.169.0.tgz"; \
    curl -fsSLo /tmp/codex-arch.tgz "https://registry.npmjs.org/@openai/codex/-/codex-0.169.0-${codex_arch}.tgz"; \
    echo "${codex_main_sha512}  /tmp/codex.tgz" | sha512sum -c -; \
    echo "${codex_arch_sha512}  /tmp/codex-arch.tgz" | sha512sum -c -; \
    npm install -g --omit=optional --no-audit --no-fund /tmp/codex.tgz; \
    codex_root="$(npm root -g)/@openai/codex"; \
    tar -xzf /tmp/codex-arch.tgz -C "$codex_root" --strip-components=1 package/vendor; \
    rm -f /tmp/codex.tgz /tmp/codex-arch.tgz; \
    npm cache clean --force; \
    codex --version

COPY validate.py test.sh test_output.py test_weights.json judge.toml /tests/
COPY data/ /tests/data/
COPY reward/ /tests/reward/
RUN chmod +x /tests/test.sh
WORKDIR /
ENV HOME=/home/verifier \
    PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
    PYTHONDONTWRITEBYTECODE=1
WORKDIR /tests
LABEL org.opencontainers.image.source="https://github.com/fastify/fastify" \
      org.opencontainers.image.revision="93c239a380f3f2778bb7565fcdf777e91cfe1fbc" \
      org.opencontainers.image.licenses="MIT" \
      org.opencontainers.image.base.name="docker.io/library/python:3.12-slim" \
      org.opencontainers.image.base.digest="sha256:05cda9777409a9c3ffddd94a4c476b79f0769a0b4857f0c7ed9226b6800b0d6f"
USER 0
CMD ["/bin/bash"]
