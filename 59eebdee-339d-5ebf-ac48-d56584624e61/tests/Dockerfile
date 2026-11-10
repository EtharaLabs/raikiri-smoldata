# syntax=docker/dockerfile:1@sha256:4edf897a3ffa55b89f906fc8cc78afdb3f1834cc9c7083565e611a8a7d5fe99e

FROM --platform=$BUILDPLATFORM docker.io/library/python:3.12-slim@sha256:05cda9777409a9c3ffddd94a4c476b79f0769a0b4857f0c7ed9226b6800b0d6f AS tree
ARG TARGETOS
ARG TARGETARCH
SHELL ["/bin/bash", "-o", "pipefail", "-c"]
WORKDIR /fetch
RUN . /etc/os-release \
 && rm -f /etc/apt/sources.list.d/debian.sources \
 && printf "deb [check-valid-until=no] https://snapshot.debian.org/archive/debian/20261001T000000Z $VERSION_CODENAME main\n" > /etc/apt/sources.list \
 && apt-get update \
 && apt-get install -y --no-install-recommends git=1:2.47.3-0+deb13u1 \
 && rm -rf /var/lib/apt/lists/*
COPY validate.py ./
RUN python3 validate.py --materialize-build-assets .
RUN base64 -d src.tgz.b64 > src.tgz \
 && mkdir -p /grade && tar -xzf src.tgz -C /grade \
 && cd /grade/mailpit && git init -q . && git add -A \
 && git -c user.email=grader@localhost -c user.name=grader commit -q -m pristine

FROM --platform=$BUILDPLATFORM docker.io/library/golang:1.25.0@sha256:5502b0e56fca23feba76dbc5387ba59c593c02ccc2f0f7355871ea9a0852cebe AS gomod
ARG TARGETOS
ARG TARGETARCH
SHELL ["/bin/bash", "-o", "pipefail", "-c"]
WORKDIR /fetch
COPY --from=tree /grade/mailpit /fetch/tree
RUN mkdir -p /gomod && cd /fetch/tree/. && GOMODCACHE=/gomod GOFLAGS=-mod=mod go mod download

FROM docker.io/library/golang:1.25.0@sha256:5502b0e56fca23feba76dbc5387ba59c593c02ccc2f0f7355871ea9a0852cebe AS go

FROM docker.io/library/python:3.12-slim@sha256:05cda9777409a9c3ffddd94a4c476b79f0769a0b4857f0c7ed9226b6800b0d6f AS runtime
SHELL ["/bin/bash", "-o", "pipefail", "-c"]
RUN . /etc/os-release \
 && rm -f /etc/apt/sources.list.d/debian.sources \
 && printf "deb [check-valid-until=no] https://snapshot.debian.org/archive/debian/20261001T000000Z $VERSION_CODENAME main\n" > /etc/apt/sources.list \
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
RUN pip install --no-cache-dir "pytest==8.3.5"

# Verifier reward toolchain (ported to the reference contract).
# RewardKit grades the ported tests/reward/ channels; the claude CLI hosts the Sonnet judge.
# --------------------------------------------------------------------------- #
RUN apt-get update && apt-get install -y --no-install-recommends curl ca-certificates \
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

ARG NODE_VERSION=20.20.2
RUN set -eux; \
    dpkg_arch="$(dpkg --print-architecture)"; \
    case "$dpkg_arch" in \
      arm64) node_arch="arm64"; node_sha="47ef73d543ecf6eb19435f6c03a0ac4809b3bf0dd6b26c7c571efc2a6572a74d" ;; \
      amd64) node_arch="x64"; node_sha="19e56f0825510207dd904f087fe52faa0a4eb6b2aab5f0ea7a33830d04888b8b" ;; \
      *) echo "unsupported architecture: $dpkg_arch" >&2; exit 1 ;; \
    esac; \
    archive="node-v${NODE_VERSION}-linux-${node_arch}.tar.gz"; \
    curl -fsSLO "https://nodejs.org/dist/v${NODE_VERSION}/${archive}"; \
    echo "${node_sha}  ${archive}" | sha256sum -c -; \
    tar -xzf "$archive" -C /usr/local --strip-components=1; \
    rm -f "$archive"; \
    node --version; \
    npm --version; \
    npm install -g "@anthropic-ai/claude-code@2.1.287"; \
    npm cache clean --force; \
    claude --version

COPY . /tests
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
USER root
CMD ["/bin/bash"]
