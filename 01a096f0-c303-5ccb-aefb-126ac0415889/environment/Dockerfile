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
COPY locks/pytest.txt /tmp/locks/pytest.txt
RUN pip install --no-cache-dir --break-system-packages --require-hashes --no-deps -r /tmp/locks/pytest.txt \
 && rm -rf /tmp/locks

COPY src.tgz /opt/harness/src.tgz
RUN echo "820c099a812adcb9184c5fc1682801ee058b6d6976524a2aab06750d3c7ea614  /opt/harness/src.tgz" | sha256sum -c --quiet -
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
 && rm -rf /tmp/gomodproxy /tmp/gomodproxy.tgz.part-00

COPY scripts/ /opt/harness/scripts/
COPY config/config.toml /opt/harness/config.toml
RUN chmod +x /opt/harness/scripts/* \
 && mkdir -p /output /logs/verifier /root/workspace
# ---------------------------------------------------------------------------
# Prebaked Claude Code agent runtime.
#
# Harbor's claude-code agent runs `claude --version` first and skips its network
# install (bootstrap.sh from downloads.claude.ai) when the version matches the
# one requested with --ak version=2.1.326, so the agent phase fetches no package;
# its only egress is the model endpoint admitted by --allow-agent-host.
# The binary is the glibc build from the 2.1.326 release manifest, checked against
# that manifest's sha256 for the build platform. The arch is read at run time, not
# from TARGETARCH, so BuildKit and Kaniko build the same way.
# ---------------------------------------------------------------------------
ENV DISABLE_AUTOUPDATER=1
RUN set -eux; \
    case "$(dpkg --print-architecture)" in \
      amd64) cc_platform=linux-x64;   cc_sha=b6b3647d981130dc44fc670846ae97b6cde531ffb667cf9c4d17cfcafb38cb37 ;; \
      arm64) cc_platform=linux-arm64; cc_sha=98d56f6ffe53469767a74864a38eaf359d62ef557a8de1b1ad524d61a66ec119 ;; \
      *) echo "unsupported architecture" >&2; exit 1 ;; \
    esac; \
    curl -fsSL -o /usr/local/bin/claude "https://downloads.claude.ai/claude-code-releases/2.1.326/${cc_platform}/claude"; \
    echo "${cc_sha}  /usr/local/bin/claude" | sha256sum -c --quiet -; \
    chmod 0755 /usr/local/bin/claude; \
    claude --version | grep -q '^2\.1\.326 '

WORKDIR /root/workspace
USER 0
CMD ["/bin/bash"]
