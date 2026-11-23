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
RUN echo "185b55d07e5e07e1917a8e93a898ccf76e208ab741cff974aad76009406db380  /run/task-prepare.sh" | sha256sum -c --quiet - \
 && bash /run/task-prepare.sh tree

FROM --platform=$BUILDPLATFORM docker.io/library/golang:1.25.0@sha256:5502b0e56fca23feba76dbc5387ba59c593c02ccc2f0f7355871ea9a0852cebe AS gomod
ARG TARGETOS
ARG TARGETARCH
SHELL ["/bin/bash", "-o", "pipefail", "-c"]
WORKDIR /fetch
COPY --from=tree /tree/mailpit /fetch/tree
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

# Throwaway stage (Kaniko-safe, no bind mounts): prepare.sh and the harness sources exist only here.
# The runtime stage copies out just what they produce, so prepare.sh never reaches the task image.
FROM docker.io/library/python:3.12-slim@sha256:05cda9777409a9c3ffddd94a4c476b79f0769a0b4857f0c7ed9226b6800b0d6f AS taskfiles
SHELL ["/bin/bash", "-o", "pipefail", "-c"]
COPY scripts/prepare.sh /run/task-prepare.sh
COPY scripts/compile.sh scripts/run_poc.sh scripts/test.sh scripts/mkpatch.sh /run/task-scripts/
COPY config/config.toml /run/task-config/config.toml
COPY install_validate_deps.sh /run/task-install_validate_deps.sh
RUN echo "185b55d07e5e07e1917a8e93a898ccf76e208ab741cff974aad76009406db380  /run/task-prepare.sh" | sha256sum -c --quiet - \
 && bash /run/task-prepare.sh runtime \
 && printf '%s\n' "0a78957364ec8218bd43c17aeb9d238c50291e1a13d469a4a56ab2b2a72c9cd6  /run/task-scripts/compile.sh" \
        "39689c94f8799d0257e34d3cebdddf914bf7d6a602f80b0348530c3082c246d7  /run/task-scripts/run_poc.sh" \
        "ba5379aea89172017dbb4622d515b2c7068a76afc262870437d38eaa83d7b7df  /run/task-scripts/test.sh" \
        "b5a5623628aa03442253fcfacbc3169718f699ba5528f61b84fb1772fb1febec  /run/task-scripts/mkpatch.sh" \
        "35e28b8e030a08913c20dbb3ad35368f0d10991ab0d1de28015d3033057a018d  /run/task-config/config.toml" \
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
COPY --from=tree --chown=root:root /tree/mailpit /opt/pristine/mailpit
COPY --from=tree --chown=1000:1000 /tree/mailpit /src/mailpit
COPY --from=go /usr/local/go /usr/local/go
COPY --from=gomod --chown=1000:1000 /gomod /home/agent/go/pkg/mod
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
 && PATH=/usr/local/go/bin:$PATH /opt/harness/install_validate_deps.sh
ENV CGO_ENABLED=0 \
    GOCACHE=/home/agent/.cache/go-build \
    GOFLAGS=-mod=readonly \
    GOMODCACHE=/home/agent/go/pkg/mod \
    GOPATH=/home/agent/go \
    GOPROXY=off \
    GOTOOLCHAIN=local \
    HOME=/home/agent \
    PATH=/usr/local/go/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
    PYTHONDONTWRITEBYTECODE=1
WORKDIR /src/mailpit
LABEL org.opencontainers.image.source="https://github.com/axllent/mailpit" \
      org.opencontainers.image.revision="2db18f671f729d6582e740cd6147eeef5d0df4d9" \
      org.opencontainers.image.licenses="MIT" \
      org.opencontainers.image.base.name="docker.io/library/python:3.12-slim" \
      org.opencontainers.image.base.digest="sha256:05cda9777409a9c3ffddd94a4c476b79f0769a0b4857f0c7ed9226b6800b0d6f"

# --------------------------------------------------------------------------- #
# Prebaked Claude Code agent runtime.
# Harbor's claude-code agent runs `claude --version` first and skips its network
# install when the version matches the one requested with --ak version=2.1.326,
# so the agent phase fetches no package; its only egress is the model endpoint
# admitted by --allow-agent-host. The binary is the glibc build from the 2.1.326
# release manifest, checked against that manifest's sha256. The arch is read at
# run time, not from TARGETARCH, so BuildKit and Kaniko build the same way.
# The home dirs belong to the uid-1000 agent.
# --------------------------------------------------------------------------- #
USER 0
RUN apt-get update && apt-get install -y --no-install-recommends curl=8.14.1-2+deb13u5 ca-certificates=20250419 \
    && rm -rf /var/lib/apt/lists/*
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
    claude --version | grep -q '^2\.1\.326 '; \
    install -d -o 1000 -g 1000 -m 0755 /home/agent/.cache /home/agent/.config /home/agent/.local; \
    chown 1000:1000 /home/agent/.cache; chown -R 1000:1000 /home/agent/.config /home/agent/.local

USER 0
CMD ["/bin/bash"]
