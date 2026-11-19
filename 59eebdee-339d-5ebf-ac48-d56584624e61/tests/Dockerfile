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
RUN python3 validate.py --materialize-build-assets .
RUN base64 -d src.tgz.b64 > src.tgz \
 && mkdir -p /grade && tar -xzf src.tgz -C /grade \
 && git -C /grade/mailpit init -q . && git -C /grade/mailpit add -A \
 && git -C /grade/mailpit -c user.email=grader@localhost -c user.name=grader commit -q -m pristine

FROM --platform=$BUILDPLATFORM docker.io/library/golang:1.25.0@sha256:5502b0e56fca23feba76dbc5387ba59c593c02ccc2f0f7355871ea9a0852cebe AS gomod
ARG TARGETOS
ARG TARGETARCH
SHELL ["/bin/bash", "-o", "pipefail", "-c"]
WORKDIR /fetch
COPY --from=tree /grade/mailpit /fetch/tree
COPY gomodproxy.tgz.part-00 gomodproxy.tgz.part-01 /fetch/
WORKDIR /fetch/tree
# Go modules come from the GOPROXY-format set shipped in this context (no network at build time).
RUN cat /fetch/gomodproxy.tgz.part-00 /fetch/gomodproxy.tgz.part-01 > /fetch/gomodproxy.tgz \
 && echo "c2badcb45dbdbe2c96a4fa741f8c407e547865c14a68365008fc0c8fd69190ee  /fetch/gomodproxy.tgz" | sha256sum -c --quiet - \
 && mkdir -p /gomodproxy /gomod && tar -xzf /fetch/gomodproxy.tgz -C /gomodproxy \
 && export GOMODCACHE=/gomod GOPROXY=file:///gomodproxy GOSUMDB=off GOFLAGS=-mod=mod GOTOOLCHAIN=local \
 && find /gomodproxy -name '*.zip' -printf '%P\n' | sed -E 's#/@v/#@#; s#\.zip$##; s#!([a-z])#\U\1#g' | sort | xargs -r go mod download \
 && go list -deps -test ./... > /dev/null

FROM docker.io/library/golang:1.25.0@sha256:5502b0e56fca23feba76dbc5387ba59c593c02ccc2f0f7355871ea9a0852cebe AS go

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
COPY --from=tree --chown=1001:1001 /grade/mailpit /grade/mailpit
COPY --from=go /usr/local/go /usr/local/go
COPY --from=gomod --chown=1001:1001 /gomod /home/verifier/go/pkg/mod

# --------------------------------------------------------------------------- #
# system-pytest-for-grader: the sandboxed grader runs the pytest oracle with the image
# python, so pytest must be importable there (the reference installs it the same way).
COPY locks/pytest.txt /tmp/locks/pytest.txt
RUN pip install --no-cache-dir --require-hashes --no-deps -r /tmp/locks/pytest.txt

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
ENV PATH="/opt/rewardkit/.venv/bin:${PATH}"

# Rubric judge: install an exact official Node release and the codex CLI tarballs from
# the npm registry, each checked against its published hash. At run time the verifier
# reaches only the host codex bridge.
ARG NODE_VERSION=20.20.2
RUN set -eux; \
    dpkg_arch="$(dpkg --print-architecture)"; \
    case "$dpkg_arch" in \
      arm64) node_arch="arm64"; node_sha="47ef73d543ecf6eb19435f6c03a0ac4809b3bf0dd6b26c7c571efc2a6572a74d"; \
             codex_arch="linux-arm64"; codex_arch_sha512="359fc36905297109b19aa79eed9f6e0b5af3c371a149ba286b071a4ded4b379624f969629d42867535c98029514fff6881010433d4d6c58cefc4f7e3e46ff116" ;; \
      amd64) node_arch="x64"; node_sha="19e56f0825510207dd904f087fe52faa0a4eb6b2aab5f0ea7a33830d04888b8b"; \
             codex_arch="linux-x64"; codex_arch_sha512="a34e4dc803820f28123d1a35ca29f3c6f91149d9ac672043f44ee66e99a345a9d27ccf25ca9a96b50804a385df364c21b82476685bbc9a518eb101855d56d5c3" ;; \
      *) echo "unsupported architecture: $dpkg_arch" >&2; exit 1 ;; \
    esac; \
    archive="node-v${NODE_VERSION}-linux-${node_arch}.tar.gz"; \
    curl -fsSLO "https://nodejs.org/dist/v${NODE_VERSION}/${archive}"; \
    echo "${node_sha}  ${archive}" | sha256sum -c -; \
    tar -xzf "$archive" -C /usr/local --strip-components=1; \
    rm -f "$archive"; \
    node --version; \
    npm --version; \
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
ENV CGO_ENABLED=0 \
    GOCACHE=/home/verifier/.cache/go-build \
    GOFLAGS=-mod=readonly \
    GOMODCACHE=/home/verifier/go/pkg/mod \
    GOPATH=/home/verifier/go \
    GOPROXY=off \
    GOTOOLCHAIN=local \
    HOME=/home/verifier \
    PATH=/usr/local/go/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
    PYTHONDONTWRITEBYTECODE=1
WORKDIR /tests
LABEL org.opencontainers.image.source="https://github.com/axllent/mailpit" \
      org.opencontainers.image.revision="2db18f671f729d6582e740cd6147eeef5d0df4d9" \
      org.opencontainers.image.licenses="MIT" \
      org.opencontainers.image.base.name="docker.io/library/python:3.12-slim" \
      org.opencontainers.image.base.digest="sha256:05cda9777409a9c3ffddd94a4c476b79f0769a0b4857f0c7ed9226b6800b0d6f"
USER 0
CMD ["/bin/bash"]
