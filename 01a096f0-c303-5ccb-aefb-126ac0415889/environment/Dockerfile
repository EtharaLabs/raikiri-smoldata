# syntax=docker/dockerfile:1.12.1@sha256:93bfd3b68c109427185cd78b4779fc82b484b0b7618e36d0f104d4d801e66d25
# hugo: pinned source snapshot and offline Go module cache for this task.
# Multi-architecture by explicit dispatch, matching the rest of the
# corpus: the base is pinned by its index digest so linux/amd64 and
# linux/arm64 resolve to the same published release rather than to
# whatever the tag happens to point at today.
ARG TARGETARCH

FROM --platform=linux/amd64 golang@sha256:632dff7351799a5a9954a48dc06670ade72ee44e8c351cdc0e5a57af2fea21af AS base-amd64
FROM --platform=linux/arm64 golang@sha256:632dff7351799a5a9954a48dc06670ade72ee44e8c351cdc0e5a57af2fea21af AS base-arm64
FROM base-${TARGETARCH}

ENV DEBIAN_FRONTEND=noninteractive
# Grading runs with no network, so the toolchain must never reach for one.
ENV GOFLAGS=-mod=mod GOTOOLCHAIN=local GOPROXY=off

RUN apt-get update && apt-get install -y --no-install-recommends \
        git patch diffutils curl ca-certificates python3 python3-pip python3-venv \
    && rm -rf /var/lib/apt/lists/*
RUN pip install --no-cache-dir --break-system-packages pytest

COPY src.tgz /opt/harness/src.tgz
RUN mkdir -p /src && tar xzf /opt/harness/src.tgz -C /src
WORKDIR /src

# Warm the module cache while the network is still available at build time, so
# the graded rebuild of the agent's patched tree resolves entirely from cache.
RUN GOPROXY=https://proxy.golang.org,direct go mod download all \
    && GOPROXY=off go build ./...

COPY scripts/ /opt/harness/scripts/
COPY config/config.toml /opt/harness/config.toml
RUN chmod +x /opt/harness/scripts/*

RUN mkdir -p /output /logs/verifier /root/workspace
# ---------------------------------------------------------------------------
# Prebaked OpenHands-SDK agent runtime.
#
# Harbor's openhands-sdk agent begins setup with:
#   [ -f /opt/openhands-sdk-venv/bin/python ] && \
#     /opt/openhands-sdk-venv/bin/python -c "import openhands.sdk"
# and skips its network install (uv python install + uv pip install
# openhands-sdk ...) when that succeeds. Baking the venv here means the agent
# phase performs no public-network package fetch: the only runtime egress left
# is the model endpoint itself (LLM_BASE_URL), admitted via --allow-agent-host.
# curl is already present (apt layer above) so the agent's system-dependency
# check (curl, coreutils) is an offline no-op; coreutils ships in the base.
# The venv is root-owned, matching the task's [agent].user = "0".
# Versions are pinned (openhands-sdk/tools 1.58.1, the version the KAKASHI
# trajectories ran on; Python 3.12.15) and the uv cache is removed in this layer.
# ---------------------------------------------------------------------------
ENV UV_PYTHON_INSTALL_DIR=/opt/uv/python
RUN set -eux; \
    curl -LsSf https://astral.sh/uv/0.13.5/install.sh | env UV_INSTALL_DIR=/usr/local/bin sh; \
    uv python install 3.12.15; \
    uv venv /opt/openhands-sdk-venv --python 3.12.15; \
    uv pip install --no-cache --python /opt/openhands-sdk-venv/bin/python \
        openhands-sdk==1.58.1 openhands-tools==1.58.1 fastapi==0.162.0; \
    chmod -R a+rX /opt/uv /opt/openhands-sdk-venv; \
    /opt/openhands-sdk-venv/bin/python -c "import openhands.sdk; assert openhands.sdk.__version__ == '1.58.1', openhands.sdk.__version__; print('openhands.sdk', openhands.sdk.__version__)"; \
    rm -rf /root/.cache/uv /tmp/uv-*.lock

WORKDIR /root/workspace
CMD ["/bin/bash"]
