# syntax=docker/dockerfile:1@sha256:4edf897a3ffa55b89f906fc8cc78afdb3f1834cc9c7083565e611a8a7d5fe99e

FROM --platform=$BUILDPLATFORM docker.io/library/python:3.12-slim@sha256:05cda9777409a9c3ffddd94a4c476b79f0769a0b4857f0c7ed9226b6800b0d6f AS tree
ARG TARGETOS
ARG TARGETARCH
SHELL ["/bin/bash", "-o", "pipefail", "-c"]
WORKDIR /fetch
COPY src.tgz ./
RUN mkdir -p /tree && tar -xzf src.tgz -C /tree
RUN --mount=type=bind,source=scripts/prepare.sh,target=/run/task-prepare.sh \
    echo "fe37afcd63c881938384c8bde64bf9e205a2564a4a0736d14e3c4b1c37ae5126  /run/task-prepare.sh" | sha256sum -c --quiet - \
 && bash /run/task-prepare.sh tree

FROM --platform=$BUILDPLATFORM docker.io/library/golang:1.25.7@sha256:5a79b94c34c299ac0361fbb7c7fca6dc552e166b42341050323fa3ab137d7be9 AS gomod
ARG TARGETOS
ARG TARGETARCH
SHELL ["/bin/bash", "-o", "pipefail", "-c"]
WORKDIR /fetch
COPY --from=tree /tree/v4 /fetch/tree
RUN mkdir -p /gomod && cd /fetch/tree/. && GOMODCACHE=/gomod GOFLAGS=-mod=mod go mod download

FROM docker.io/library/golang:1.25.7@sha256:5a79b94c34c299ac0361fbb7c7fca6dc552e166b42341050323fa3ab137d7be9 AS go

FROM docker.io/library/python:3.12-slim@sha256:05cda9777409a9c3ffddd94a4c476b79f0769a0b4857f0c7ed9226b6800b0d6f AS runtime
SHELL ["/bin/bash", "-o", "pipefail", "-c"]
RUN . /etc/os-release \
 && rm -f /etc/apt/sources.list.d/debian.sources \
 && printf "deb [check-valid-until=no] https://snapshot.debian.org/archive/debian/20261001T000000Z $VERSION_CODENAME main\n" > /etc/apt/sources.list \
 && apt-get update \
 && apt-get install -y --no-install-recommends git=1:2.47.3-0+deb13u1 patch=2.8-2 gcc=4:14.2.0-1 libc6-dev=2.41-12+deb13u4 \
 && rm -rf /var/lib/apt/lists/*
RUN groupadd --gid 1000 agent \
 && useradd --uid 1000 --gid 1000 --create-home --shell /bin/bash agent \
 && install -d -o 1000 -g 1000 -m 0755 /output /src
RUN install -d -o root -g root -m 0755 /opt/task
COPY --from=tree --chown=root:root /tree/v4 /opt/pristine/v4
COPY --from=tree --chown=1000:1000 /tree/v4 /src/v4
COPY --from=go /usr/local/go /usr/local/go
COPY --from=gomod --chown=1000:1000 /gomod /home/agent/go/pkg/mod
RUN --mount=type=bind,source=scripts/prepare.sh,target=/run/task-prepare.sh \
    echo "fe37afcd63c881938384c8bde64bf9e205a2564a4a0736d14e3c4b1c37ae5126  /run/task-prepare.sh" | sha256sum -c --quiet - \
 && bash /run/task-prepare.sh runtime
# Reproduction and regression harness (golden layout: config/, install_validate_deps.sh, scripts/),
# installed read-only under /opt/harness. Every file's sha256 is pinned here, so a build host can
# never install another bundle's copy; the bind mounts keep scripts/prepare.sh out of the image.
RUN --mount=type=bind,source=scripts,target=/run/task-scripts \
    --mount=type=bind,source=config,target=/run/task-config \
    --mount=type=bind,source=install_validate_deps.sh,target=/run/task-install_validate_deps.sh \
    printf '%s\n' "0a78957364ec8218bd43c17aeb9d238c50291e1a13d469a4a56ab2b2a72c9cd6  /run/task-scripts/compile.sh" \
        "39689c94f8799d0257e34d3cebdddf914bf7d6a602f80b0348530c3082c246d7  /run/task-scripts/run_poc.sh" \
        "ba5379aea89172017dbb4622d515b2c7068a76afc262870437d38eaa83d7b7df  /run/task-scripts/test.sh" \
        "b5a5623628aa03442253fcfacbc3169718f699ba5528f61b84fb1772fb1febec  /run/task-scripts/mkpatch.sh" \
        "43a2aed4d596b5afa8f6c5c93e5a0e22a426af0bfce7883878ba0e5f72b7664e  /run/task-config/config.toml" \
        "419a4e01d9d0ed4dae4c027eeba3b2bff0026780ac842e02b1cc4fdc7b90e5ca  /run/task-install_validate_deps.sh" | sha256sum -c --quiet - \
 && install -d -o root -g root -m 0755 /opt/harness /opt/harness/scripts \
 && install -o root -g root -m 0755 /run/task-scripts/compile.sh /run/task-scripts/run_poc.sh /run/task-scripts/test.sh /run/task-scripts/mkpatch.sh /opt/harness/scripts/ \
 && install -o root -g root -m 0644 /run/task-config/config.toml /opt/harness/config.toml \
 && install -o root -g root -m 0755 /run/task-install_validate_deps.sh /opt/harness/install_validate_deps.sh \
 && ln -sf /opt/harness/scripts/compile.sh /usr/local/bin/build.sh \
 && ln -sf /opt/harness/scripts/run_poc.sh /usr/local/bin/run_poc.sh \
 && ln -sf /opt/harness/scripts/test.sh /usr/local/bin/regression.sh \
 && ln -sf /opt/harness/scripts/mkpatch.sh /usr/local/bin/mkpatch.sh \
 && PATH=/usr/local/go/bin:$PATH /opt/harness/install_validate_deps.sh
ENV CGO_ENABLED=1 \
    GOCACHE=/home/agent/.cache/go-build \
    GOFLAGS=-mod=readonly \
    GOMODCACHE=/home/agent/go/pkg/mod \
    GOPATH=/home/agent/go \
    GOPROXY=off \
    GOTOOLCHAIN=local \
    HOME=/home/agent \
    PATH=/usr/local/go/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
    PYTHONDONTWRITEBYTECODE=1
WORKDIR /src/v4
LABEL org.opencontainers.image.source="https://github.com/argoproj/argo-workflows" \
      org.opencontainers.image.revision="5ac265d6aef7418e57c64d66168ea18b6dd8f609" \
      org.opencontainers.image.licenses="Apache-2.0" \
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
USER root
RUN apt-get update && apt-get install -y --no-install-recommends curl ca-certificates \
    && rm -rf /var/lib/apt/lists/*
ENV UV_PYTHON_INSTALL_DIR=/opt/uv/python
RUN set -eux; \
    curl -LsSf https://astral.sh/uv/0.13.5/install.sh | env UV_INSTALL_DIR=/usr/local/bin sh; \
    uv python install 3.12.15; \
    uv venv /opt/openhands-sdk-venv --python 3.12.15; \
    uv pip install --no-cache --python /opt/openhands-sdk-venv/bin/python \
        openhands-sdk==1.58.1 openhands-tools==1.58.1 fastapi==0.162.0; \
    chmod -R a+rX /opt/uv /opt/openhands-sdk-venv; \
    /opt/openhands-sdk-venv/bin/python -c "import openhands.sdk; assert openhands.sdk.__version__ == '1.58.1', openhands.sdk.__version__; print('openhands.sdk', openhands.sdk.__version__)"; \
    rm -rf /root/.cache/uv /home/agent/.cache/uv /tmp/uv-*.lock; \
    install -d -o 1000 -g 1000 -m 0755 /home/agent/.cache /home/agent/.config /home/agent/.local; \
    chown 1000:1000 /home/agent/.cache; chown -R 1000:1000 /home/agent/.config /home/agent/.local

USER root
CMD ["/bin/bash"]
