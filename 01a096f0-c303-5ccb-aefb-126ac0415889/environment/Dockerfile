# syntax=docker/dockerfile:1.12.1@sha256:93bfd3b68c109427185cd78b4779fc82b484b0b7618e36d0f104d4d801e66d25
# hugo: pinned source snapshot and offline Go module cache for this task.
# Multi-architecture through one index digest: the golang base is pinned by its
# multi-arch index digest (linux/amd64 + linux/arm64 among others), so every
# builder (BuildKit or Kaniko) resolves the build platform's manifest of the same
# published release, with no TARGETARCH stage dispatch.
FROM golang@sha256:632dff7351799a5a9954a48dc06670ade72ee44e8c351cdc0e5a57af2fea21af
SHELL ["/bin/bash", "-o", "pipefail", "-c"]

ENV DEBIAN_FRONTEND=noninteractive
# Grading runs with no network, so the toolchain must never reach for one.
ENV GOFLAGS=-mod=mod GOTOOLCHAIN=local GOPROXY=off

# apt resolves against a fixed snapshot.debian.org date, with the three bookworm suites the
# base image itself uses (main, -updates, -security). The base was built 2026-10-21, so the
# snapshot must postdate it; these exact versions then stay installable.
RUN . /etc/os-release \
 && rm -f /etc/apt/sources.list.d/debian.sources \
 && printf 'deb [check-valid-until=no] https://snapshot.debian.org/archive/debian/20261101T000000Z %s main\ndeb [check-valid-until=no] https://snapshot.debian.org/archive/debian/20261101T000000Z %s-updates main\ndeb [check-valid-until=no] https://snapshot.debian.org/archive/debian-security/20261101T000000Z %s-security main\n' "$VERSION_CODENAME" "$VERSION_CODENAME" "$VERSION_CODENAME" > /etc/apt/sources.list \
 && apt-get update \
 && apt-get install -y --no-install-recommends \
        git=1:2.39.5-0+deb12u3 patch=2.7.6-7 diffutils=1:3.8-4 curl=7.88.1-10+deb12u15 \
        ca-certificates=20250419~deb12u2 python3=3.11.2-1+b1 python3-pip=23.0.1+dfsg-1 python3-venv=3.11.2-1+b1 \
 && rm -rf /var/lib/apt/lists/*
RUN pip install --no-cache-dir --break-system-packages "pytest==8.3.5"

# The agent runs as uid/gid 1000 ([agent].user = "1000") and owns exactly what it writes:
# the source tree, the submission directory, its workspace and its Go build cache.
RUN groupadd --gid 1000 agent \
 && useradd --uid 1000 --gid 1000 --create-home --shell /bin/bash agent \
 && install -d -o 1000 -g 1000 -m 0755 /output /src /home/agent/workspace
ENV GOCACHE=/home/agent/.cache/go-build

COPY src.tgz /opt/harness/src.tgz
RUN mkdir -p /src && tar xzf /opt/harness/src.tgz -C /src
WORKDIR /src

# Warm the module cache while the network is still available at build time, so
# the graded rebuild of the agent's patched tree resolves entirely from cache.
COPY gomodproxy.tgz.part-00 /tmp/gomodproxy.tgz.part-00
# Go modules come from the GOPROXY-format set shipped in this context (no network at build time).
RUN echo "3485e803fb11688c0e02fe2255a70bc0127c53ad8bba895fbbaab8d356e68f4e  /tmp/gomodproxy.tgz.part-00" | sha256sum -c --quiet - \
 && mkdir -p /tmp/gomodproxy && tar -xzf /tmp/gomodproxy.tgz.part-00 -C /tmp/gomodproxy \
 && find /tmp/gomodproxy -name '*.zip' -printf '%P\n' | sed -E 's#/@v/#@#; s#\.zip$##; s#!([a-z])#\U\1#g' | sort | GOPROXY=file:///tmp/gomodproxy GOSUMDB=off xargs -r go mod download \
 && GOPROXY=file:///tmp/gomodproxy GOSUMDB=off go list -deps -test ./... > /dev/null \
 && GOPROXY=off go build ./... \
 && rm -rf /tmp/gomodproxy /tmp/gomodproxy.tgz.part-00 \
 && chown -R 1000:1000 /src /home/agent/.cache

COPY scripts/ /opt/harness/scripts/
COPY config/config.toml /opt/harness/config.toml
RUN chmod +x /opt/harness/scripts/* \
 && mkdir -p /output /logs/verifier
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
# The venv is root-owned and world-readable, so the uid-1000 agent can import it.
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

WORKDIR /home/agent/workspace
USER 0
CMD ["/bin/bash"]
