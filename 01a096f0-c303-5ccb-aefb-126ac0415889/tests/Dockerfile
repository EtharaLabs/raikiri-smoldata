# syntax=docker/dockerfile:1.12.1@sha256:93bfd3b68c109427185cd78b4779fc82b484b0b7618e36d0f104d4d801e66d25
#
# hugo -- verifier image.
#
# Harbor builds this image with the bundle's tests/ directory as the build
# context, so nothing here may COPY from environment/. The pristine snapshot
# and the environment scripts/config travel inside validate.py as base64 and
# are written back out by `validate.py --materialize` at build time, which is
# how the canonical bundles keep to the required tests/ file set.
#
# The golang base is pinned by its multi-arch index digest (linux/amd64 +
# linux/arm64 among others), so BuildKit and Kaniko both resolve the build
# platform's manifest of the same release, with no TARGETARCH stage dispatch.
FROM golang@sha256:632dff7351799a5a9954a48dc06670ade72ee44e8c351cdc0e5a57af2fea21af
SHELL ["/bin/bash", "-o", "pipefail", "-c"]

ENV DEBIAN_FRONTEND=noninteractive
ENV GOFLAGS=-mod=mod GOTOOLCHAIN=local GOPROXY=off
# apt resolves against a fixed snapshot.debian.org date, with the three bookworm suites the
# base image itself uses (main, -updates, -security). The base was built 2026-10-21, so the
# snapshot must postdate it; these exact versions then stay installable. curl also serves the
# uv/Node downloads below.
RUN . /etc/os-release \
 && rm -f /etc/apt/sources.list.d/debian.sources \
 && printf 'deb [check-valid-until=no] https://snapshot.debian.org/archive/debian/20261101T000000Z %s main\ndeb [check-valid-until=no] https://snapshot.debian.org/archive/debian/20261101T000000Z %s-updates main\ndeb [check-valid-until=no] https://snapshot.debian.org/archive/debian-security/20261101T000000Z %s-security main\n' "$VERSION_CODENAME" "$VERSION_CODENAME" "$VERSION_CODENAME" > /etc/apt/sources.list \
 && apt-get update \
 && apt-get install -y --no-install-recommends \
        git=1:2.39.5-0+deb12u3 patch=2.7.6-7 diffutils=1:3.8-4 python3=3.11.2-1+b1 python3-pip=23.0.1+dfsg-1 \
        python3-venv=3.11.2-1+b1 curl=7.88.1-10+deb12u15 ca-certificates=20250419~deb12u2 \
 && rm -rf /var/lib/apt/lists/*
RUN pip install --no-cache-dir --break-system-packages "pytest==8.3.5"
# Verifier user, as in the other raikiri tasks. test.sh itself runs as root (USER 0 below)
# and drops the grading steps to its own unprivileged uid.
RUN groupadd --gid 1001 verifier \
 && useradd --uid 1001 --gid 1001 --create-home --shell /bin/bash verifier \
 && install -d -o 1001 -g 1001 -m 0755 /output

COPY validate.py /tests/validate.py
RUN python3 /tests/validate.py --materialize \
        --src-tgz /opt/harness/src.tgz \
        --scripts-dir /opt/harness/scripts \
        --config-dir /opt/harness \
    && mv /opt/harness/scripts/install_validate_deps.sh \
          /opt/harness/install_validate_deps.sh \
    && chmod +x /opt/harness/scripts/* /opt/harness/install_validate_deps.sh

RUN mkdir -p /src && tar xzf /opt/harness/src.tgz -C /src
WORKDIR /src
COPY gomodproxy.tgz.part-00 /tmp/gomodproxy.tgz.part-00
# Go modules come from the GOPROXY-format set shipped in this context (no network at build time).
RUN echo "3485e803fb11688c0e02fe2255a70bc0127c53ad8bba895fbbaab8d356e68f4e  /tmp/gomodproxy.tgz.part-00" | sha256sum -c --quiet - \
 && mkdir -p /tmp/gomodproxy && tar -xzf /tmp/gomodproxy.tgz.part-00 -C /tmp/gomodproxy \
 && find /tmp/gomodproxy -name '*.zip' -printf '%P\n' | sed -E 's#/@v/#@#; s#\.zip$##; s#!([a-z])#\U\1#g' | sort | GOPROXY=file:///tmp/gomodproxy GOSUMDB=off xargs -r go mod download \
 && GOPROXY=file:///tmp/gomodproxy GOSUMDB=off go list -deps -test ./... > /dev/null \
 && GOPROXY=off go build ./... \
 && rm -rf /tmp/gomodproxy /tmp/gomodproxy.tgz.part-00 \
 && chmod -R a+rwX "$(go env GOMODCACHE)"

# --------------------------------------------------------------------------- #
# Verifier layer.  [verifier].environment_mode = "separate" grades in a
# dedicated container Harbor builds from this tests/ directory, so the image
# must own /tests.  Built on the SAME base + toolchain as environment/Dockerfile
# so a submission is graded under the toolchain it was produced against.
# --------------------------------------------------------------------------- #
RUN mkdir -p /output /logs/verifier /tests
# Rewardkit 0.2.3 requires Python >=3.12, while this pinned Debian bookworm base
# has Python 3.11. Install a pinned standalone Python and verifier environment.
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

# Rubric judge: the codex CLI hosts the GPT 6.1 Sol judge Rewardkit drives
# (JUDGE_TRANSPORT=codex). Installed at build time; at run time the verifier
# reaches only the host codex bridge.
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
    npm install -g "@openai/codex@0.169.0"; \
    npm cache clean --force; \
    codex --version

COPY . /tests
RUN chmod +x /tests/test.sh
WORKDIR /
USER 0
