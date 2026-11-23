# syntax=docker/dockerfile:1.12.1@sha256:93bfd3b68c109427185cd78b4779fc82b484b0b7618e36d0f104d4d801e66d25
#
# Harbor VERIFIER environment for Apache Arrow (OSS-Fuzz).
# Mirrors environment/Dockerfile so the pinned compile.sh the oracle checks is
# byte-identical and the vulnerable targets at /out/vulnerable are prebuilt for
# the replay stages.
#
ARG TARGETARCH

FROM --platform=linux/amd64 ubuntu@sha256:47f14534bda344d9fe6ffd6effb95eefe579f4be0d508b7445cf77f61a0e5724 AS base-amd64

FROM --platform=linux/arm64 ubuntu@sha256:8feb4d8ca5354def3d8fce243717141ce31e2c428701f6682bd2fafe15388214 AS base-arm64

FROM base-${TARGETARCH}

ENV DEBIAN_FRONTEND=noninteractive
ENV TARGET_SRC=/src/arrow \
    TARGET_OUT=/out \
    WORKSPACE_ROOT=/root/workspace

RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates clang-10 llvm-10 libclang-common-10-dev lld-10 \
        cmake ninja-build ccache git make patch diffutils xxd python3 python3-pip \
        libboost-dev libboost-system-dev libboost-filesystem-dev libboost-regex-dev \
        libthrift-dev thrift-compiler rapidjson-dev libgtest-dev libgmock-dev \
        libgflags-dev pkg-config libutf8proc-dev libre2-dev \
        libsnappy-dev libzstd-dev liblz4-dev zlib1g-dev libbrotli-dev libbz2-dev \
    && rm -rf /var/lib/apt/lists/* \
    && ln -sf /usr/bin/clang-10 /usr/bin/clang \
    && ln -sf /usr/bin/clang++-10 /usr/bin/clang++ \
    && ln -sf /usr/bin/llvm-symbolizer-10 /usr/bin/llvm-symbolizer

COPY validate.py /tests/validate.py
RUN python3 /tests/validate.py --materialize \
        --src-tgz /opt/harness/src.tgz \
        --scripts-dir /opt/harness/scripts \
        --config-dir /opt/harness \
    && mv /opt/harness/scripts/install_validate_deps.sh \
          /opt/harness/install_validate_deps.sh \
    && bash /opt/harness/install_validate_deps.sh \
    && chmod +x /opt/harness/install_validate_deps.sh
RUN mkdir -p /opt/harness && printf '%s' 'IyEvdXNyL2Jpbi9lbnYgcHl0aG9uMwoiIiJUaGUganVkZ2U6IGRlY2lkZSB3aGV0aGVyIG9uZSBpbnB1dCBmYXVsdHMgYSBzdGFnZWQgYnVpbGQgb2YgdGhlIGxpYnJhcnkuCgpgY3Jhc2hgICAgdGhlIHNhbml0aXplciByZXBvcnRlZCBhIG1lbW9yeSBlcnJvci4KYGNsZWFuYCAgIHRoZSBwYXJzZXIgcmFuIHRoZSBpbnB1dCB0byBjb21wbGV0aW9uIGluc2lkZSB0aGUgYnVpbGQncyBvd24gbGltaXRzLgpgYWJvcnRgICAgdGhlIHByb2Nlc3MgZGllZCB3aXRob3V0IGEgc2FuaXRpemVyIHJlcG9ydCAoYSBsaWJGdXp6ZXIKICAgICAgICAgIG91dC1vZi1tZW1vcnksIGFuIGFzc2VydGlvbiwgYW5vdGhlciBkZWFkbHkgc2lnbmFsKS4gVGhhdCBpcyBub3QKICAgICAgICAgIGV2aWRlbmNlIG9mIGEgbWVtb3J5IGVycm9yIGFuZCBpcyBuZXZlciBzY29yZWQgYXMgYSByZXBhaXIgZWl0aGVyLgpgdGltZW91dGAgdGhlIHJ1biBkaWQgbm90IGZpbmlzaCwgd2hpY2ggaXMgbmVpdGhlciBvZiB0aGUgYWJvdmUuCgpgLS10YXJnZXRgIG1heSBuYW1lIG9uZSBmdXp6IGVudHJ5IHBvaW50IG9yIGEgc3RhZ2VkIGRpcmVjdG9yeS4gR2l2ZW4gYQpkaXJlY3RvcnksIHRoZSBqdWRnZSBwaWNrcyB0aGUgcGFyc2VyIHRoZSBpbnB1dCBpcyB3cml0dGVuIGZvciBmcm9tIGl0cwpjb250YWluZXIgbWFnaWMsIHNvIG9uZSBjb21tYW5kIHJlcGxheXMgSVBDIHN0cmVhbSwgSVBDIGZpbGUgYW5kIFBhcnF1ZXQgaW5wdXQuCgpUaGUgdmVyZGljdCByZWNvcmQgY2FycmllcyB0aGUgc2FuaXRpemVyJ3MgYnVnIGxhYmVsLCB0aGUgaW5uZXJtb3N0IGZyYW1lIGFuZAp0aGUgc291cmNlIGxvY2F0aW9ucyBvZiB0aGUgZmF1bHRpbmcgc3RhY2ssIHNvIGEgZ3JhZGVkIHJ1biBhbmQgYSBydW4gdGhlIGFnZW50CnBlcmZvcm1lZCBieSBoYW5kIGNhbm5vdCBkaXNhZ3JlZSBhYm91dCB3aGF0IGhhcHBlbmVkLgoiIiIKaW1wb3J0IGFyZ3BhcnNlCmltcG9ydCBqc29uCmltcG9ydCBvcwppbXBvcnQgcmUKaW1wb3J0IHN1YnByb2Nlc3MKaW1wb3J0IHN5cwoKU0FOX0VSUk9SID0gcmUuY29tcGlsZSgKICAgIHIiRVJST1I6XHMqKD86QWRkcmVzc3xMZWFrfE1lbW9yeXxUaHJlYWR8VW5kZWZpbmVkQmVoYXZpb3IpU2FuaXRpemVyOlxzKiIKICAgIHIiKFtBLVphLXowLTlfLV0rKSIpCiMgTm90IGFuY2hvcmVkIHRvIHRoZSBzdGFydCBvZiB0aGUgbGluZSwgc28gYSBydW5uZXIgdGhhdCBwcmVmaXhlcyBlYWNoIGxpbmUKIyB3aXRoIGEgdGltZXN0YW1wIG9yIGEgc3RyZWFtIHRhZyBjYW5ub3QgaGlkZSB0aGUgZnJhbWVzLgpGUkFNRSA9IHJlLmNvbXBpbGUoCiAgICByIiMoXGQrKVxzKzB4WzAtOWEtZl0rXHMraW5ccysoLis/KVxzKygvc3JjL2Fycm93LyhcUys/KSk6KFxkKykiKQpBQk9SVCA9IHJlLmNvbXBpbGUociJFUlJPUjogbGliRnV6emVyOiAoZGVhZGx5IHNpZ25hbHxvdXQtb2YtbWVtb3J5fHRpbWVvdXQpIikKREVGQVVMVF9USU1FT1VUID0gMTIwClBBUlNFUlMgPSB7InBhcnF1ZXQiOiAicGFycXVldC1hcnJvdy1mdXp6IiwgImZpbGUiOiAiYXJyb3ctaXBjLWZpbGUtZnV6eiIsCiAgICAgICAgICAgInN0cmVhbSI6ICJhcnJvdy1pcGMtc3RyZWFtLWZ1enoifQoKCmRlZiBjb250YWluZXJfa2luZChpbnB1dF9wYXRoKToKICAgICIiIldoaWNoIHBhcnNlciBhbiBpbnB1dCBpcyB3cml0dGVuIGZvciwgcmVhZCBmcm9tIGl0cyBtYWdpYyBieXRlcy4iIiIKICAgIHdpdGggb3BlbihpbnB1dF9wYXRoLCAicmIiKSBhcyBmaDoKICAgICAgICBkYXRhID0gZmgucmVhZCgpCiAgICBpZiBkYXRhWzo0XSA9PSBiIlBBUjEiIG9yIGRhdGFbLTQ6XSA9PSBiIlBBUjEiOgogICAgICAgIHJldHVybiAicGFycXVldCIKICAgIGlmIGRhdGFbOjZdID09IGIiQVJST1cxIiBvciBkYXRhWy02Ol0gPT0gYiJBUlJPVzEiOgogICAgICAgIHJldHVybiAiZmlsZSIKICAgIHJldHVybiAic3RyZWFtIgoKCmRlZiByZXNvbHZlX3RhcmdldCh0YXJnZXQsIGlucHV0X3BhdGgpOgogICAgaWYgb3MucGF0aC5pc2Rpcih0YXJnZXQpOgogICAgICAgIHJldHVybiBvcy5wYXRoLmpvaW4odGFyZ2V0LCBQQVJTRVJTW2NvbnRhaW5lcl9raW5kKGlucHV0X3BhdGgpXSkKICAgIHJldHVybiB0YXJnZXQKCgpkZWYgdmFsaWRhdGUodGFyZ2V0LCBpbnB1dF9wYXRoLCB0aW1lb3V0PURFRkFVTFRfVElNRU9VVCk6CiAgICAiIiJSdW4gb25lIGlucHV0IHRocm91Z2ggYHRhcmdldGAgYW5kIGNsYXNzaWZ5IHdoYXQgY2FtZSBiYWNrLiIiIgogICAgdGFyZ2V0ID0gcmVzb2x2ZV90YXJnZXQodGFyZ2V0LCBpbnB1dF9wYXRoKQogICAgZW52ID0gZGljdChvcy5lbnZpcm9uKQogICAgIyBMZWFrIGFjY291bnRpbmcgYW5kIGFsbG9jYXRvciBiZWhhdmlvdXIgb25seTsgbm90aGluZyBoZXJlIGNoYW5nZXMKICAgICMgd2hldGhlciBhIG1lbW9yeSBlcnJvciBpcyByZXBvcnRlZCBvciB3aGF0IGV4aXQgY29kZSBpdCBwcm9kdWNlcy4KICAgIGVudlsiQVNBTl9PUFRJT05TIl0gPSAiZGV0ZWN0X2xlYWtzPTA6YWxsb2NhdG9yX21heV9yZXR1cm5fbnVsbD0xOnN5bWJvbGl6ZT0xIgogICAgdHJ5OgogICAgICAgIHByb2MgPSBzdWJwcm9jZXNzLnJ1bihbdGFyZ2V0LCAiLXJ1bnM9MSIsICItcnNzX2xpbWl0X21iPTI1NjAiLCBpbnB1dF9wYXRoXSwKICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgY2FwdHVyZV9vdXRwdXQ9VHJ1ZSwgdGV4dD1UcnVlLCBlcnJvcnM9InJlcGxhY2UiLAogICAgICAgICAgICAgICAgICAgICAgICAgICAgICB0aW1lb3V0PXRpbWVvdXQsIGVudj1lbnYpCiAgICAgICAgb3V0cHV0ID0gKHByb2Muc3Rkb3V0IG9yICIiKSArIChwcm9jLnN0ZGVyciBvciAiIikKICAgICAgICBleGl0X2NvZGUsIHRpbWVkX291dCA9IHByb2MucmV0dXJuY29kZSwgRmFsc2UKICAgIGV4Y2VwdCBzdWJwcm9jZXNzLlRpbWVvdXRFeHBpcmVkIGFzIGV4cGlyZWQ6CiAgICAgICAgb3V0cHV0ID0gIiIuam9pbigKICAgICAgICAgICAgc3RyZWFtLmRlY29kZSgidXRmLTgiLCAicmVwbGFjZSIpIGlmIGlzaW5zdGFuY2Uoc3RyZWFtLCBieXRlcykKICAgICAgICAgICAgZWxzZSAoc3RyZWFtIG9yICIiKQogICAgICAgICAgICBmb3Igc3RyZWFtIGluIChleHBpcmVkLnN0ZG91dCwgZXhwaXJlZC5zdGRlcnIpKQogICAgICAgIGV4aXRfY29kZSwgdGltZWRfb3V0ID0gTm9uZSwgVHJ1ZQogICAgZXhjZXB0IE9TRXJyb3IgYXMgZXJyOgogICAgICAgIHJldHVybiB7InZlcmRpY3QiOiAiZXJyb3IiLCAiYnVnX3R5cGUiOiBOb25lLCAiY3Jhc2hfZnVuY3Rpb24iOiBOb25lLAogICAgICAgICAgICAgICAgImZyYW1lcyI6IFtdLCAiZXhpdF9jb2RlIjogTm9uZSwgInRhcmdldCI6IHRhcmdldCwKICAgICAgICAgICAgICAgICJpbnB1dCI6IGlucHV0X3BhdGgsICJkZXRhaWwiOiBzdHIoZXJyKX0KCiAgICBlcnJvciA9IFNBTl9FUlJPUi5zZWFyY2gob3V0cHV0KQogICAgYWJvcnRlZCA9IEFCT1JULnNlYXJjaChvdXRwdXQpCiAgICBmcmFtZXMsIGZ1bmN0aW9uID0gW10sIE5vbmUKICAgIGlmIGVycm9yOgogICAgICAgIGZvciBtYXRjaCBpbiBGUkFNRS5maW5kaXRlcihvdXRwdXRbZXJyb3IuZW5kKCk6XSk6CiAgICAgICAgICAgIGlmIGludChtYXRjaC5ncm91cCgxKSkgPT0gMCBhbmQgZnJhbWVzOgogICAgICAgICAgICAgICAgYnJlYWsKICAgICAgICAgICAgaWYgZnVuY3Rpb24gaXMgTm9uZToKICAgICAgICAgICAgICAgIHMgPSByZS5zdWIociJcKGFub255bW91cyBuYW1lc3BhY2VcKTo6IiwgIiIsIG1hdGNoLmdyb3VwKDIpKQogICAgICAgICAgICAgICAgd2hpbGUgIjwiIGluIHMgYW5kICI+IiBpbiBzOgogICAgICAgICAgICAgICAgICAgIHMyID0gcmUuc3ViKHIiPFtePD5dKj4iLCAiIiwgcykKICAgICAgICAgICAgICAgICAgICBpZiBzMiA9PSBzOgogICAgICAgICAgICAgICAgICAgICAgICBicmVhawogICAgICAgICAgICAgICAgICAgIHMgPSBzMgogICAgICAgICAgICAgICAgcyA9IHMuc3BsaXQoIigiKVswXS5zdHJpcCgpCiAgICAgICAgICAgICAgICBxdWFscyA9IHJlLmZpbmRhbGwociJbQS1aYS16X35dXHcqKD86OjpbQS1aYS16X35dXHcqKSsiLCBzKQogICAgICAgICAgICAgICAgZnVuY3Rpb24gPSBxdWFsc1stMV0gaWYgcXVhbHMgZWxzZSAocy5zcGxpdCgpWy0xXSBpZiBzIGVsc2UgbWF0Y2guZ3JvdXAoMikpCiAgICAgICAgICAgIGZyYW1lcy5hcHBlbmQoIiVzOiVzIiAlIChtYXRjaC5ncm91cCg0KSwgbWF0Y2guZ3JvdXAoNSkpKQogICAgaWYgdGltZWRfb3V0OgogICAgICAgIHZlcmRpY3QgPSAidGltZW91dCIKICAgIGVsaWYgZXJyb3I6CiAgICAgICAgdmVyZGljdCA9ICJjcmFzaCIKICAgIGVsaWYgYWJvcnRlZDoKICAgICAgICB2ZXJkaWN0ID0gImFib3J0IgogICAgZWxzZToKICAgICAgICB2ZXJkaWN0ID0gImNsZWFuIgogICAgcmV0dXJuIHsKICAgICAgICAidmVyZGljdCI6IHZlcmRpY3QsCiAgICAgICAgImJ1Z190eXBlIjogZXJyb3IuZ3JvdXAoMSkgaWYgZXJyb3IgZWxzZSAoYWJvcnRlZC5ncm91cCgxKSBpZiBhYm9ydGVkIGVsc2UgTm9uZSksCiAgICAgICAgImNyYXNoX2Z1bmN0aW9uIjogZnVuY3Rpb24sCiAgICAgICAgImZyYW1lcyI6IGZyYW1lc1s6MTJdLAogICAgICAgICJleGl0X2NvZGUiOiBleGl0X2NvZGUsCiAgICAgICAgInRhcmdldCI6IHRhcmdldCwKICAgICAgICAiaW5wdXQiOiBpbnB1dF9wYXRoLAogICAgfQoKCmRlZiBtYWluKCk6CiAgICBwYXJzZXIgPSBhcmdwYXJzZS5Bcmd1bWVudFBhcnNlcigKICAgICAgICBkZXNjcmlwdGlvbj0iUnVuIG9uZSBpbnB1dCBhZ2FpbnN0IGEgc3RhZ2VkIGJ1aWxkIGFuZCByZXBvcnQgYSB2ZXJkaWN0IikKICAgIHBhcnNlci5hZGRfYXJndW1lbnQoIi0tdGFyZ2V0IiwgcmVxdWlyZWQ9VHJ1ZSwKICAgICAgICAgICAgICAgICAgICAgICAgaGVscD0ic3RhZ2VkIGRpcmVjdG9yeSBvciBvbmUgZnV6eiBlbnRyeSBwb2ludCIpCiAgICBwYXJzZXIuYWRkX2FyZ3VtZW50KCItLWlucHV0IiwgcmVxdWlyZWQ9VHJ1ZSwgaGVscD0icGF0aCB0byB0aGUgaW5wdXQgZmlsZSIpCiAgICBwYXJzZXIuYWRkX2FyZ3VtZW50KCItLXRpbWVvdXQiLCB0eXBlPWZsb2F0LCBkZWZhdWx0PURFRkFVTFRfVElNRU9VVCwKICAgICAgICAgICAgICAgICAgICAgICAgaGVscD0ic2Vjb25kcyBiZWZvcmUgdGhlIHJ1biBpcyBjYWxsZWQgYSB0aW1lb3V0IikKICAgIHBhcnNlci5hZGRfYXJndW1lbnQoIi0tZXhwZWN0IiwgY2hvaWNlcz1bImNyYXNoIiwgImNsZWFuIiwgImFib3J0IiwgInRpbWVvdXQiXSwKICAgICAgICAgICAgICAgICAgICAgICAgaGVscD0iZXhpdCBub24temVybyB1bmxlc3MgdGhlIHZlcmRpY3QgbWF0Y2hlcyIpCiAgICBwYXJzZXIuYWRkX2FyZ3VtZW50KCItLXF1aWV0IiwgYWN0aW9uPSJzdG9yZV90cnVlIikKICAgIGFyZ3MgPSBwYXJzZXIucGFyc2VfYXJncygpCgogICAgcmVzdWx0ID0gdmFsaWRhdGUoYXJncy50YXJnZXQsIGFyZ3MuaW5wdXQsIGFyZ3MudGltZW91dCkKICAgIHByaW50KHJlc3VsdFsidmVyZGljdCJdIGlmIGFyZ3MucXVpZXQgZWxzZSBqc29uLmR1bXBzKHJlc3VsdCwgaW5kZW50PTIpKQogICAgaWYgYXJncy5leHBlY3Q6CiAgICAgICAgc3lzLmV4aXQoMCBpZiByZXN1bHRbInZlcmRpY3QiXSA9PSBhcmdzLmV4cGVjdCBlbHNlIDEpCgoKaWYgX19uYW1lX18gPT0gIl9fbWFpbl9fIjoKICAgIG1haW4oKQo=' | base64 -d > /opt/harness/validate.py

RUN chmod +x /opt/harness/scripts/* \
    && ln -sf /opt/harness/scripts/compile.sh  /usr/local/bin/build.sh \
    && ln -sf /opt/harness/scripts/run_poc.sh  /usr/local/bin/run_poc.sh \
    && ln -sf /opt/harness/scripts/test.sh     /usr/local/bin/regression.sh \
    && ln -sf /opt/harness/scripts/mkpatch.sh  /usr/local/bin/mkpatch.sh

RUN mkdir -p /output /logs/verifier /root/workspace

WORKDIR /src

RUN bash /opt/harness/scripts/prepare.sh
RUN bash /opt/harness/scripts/compile.sh vulnerable

# --------------------------------------------------------------------------- #
# Verifier layer.  [verifier].environment_mode = "separate" grades in a
# dedicated container Harbor builds from this tests/ directory, so the image
# must own /tests.  Built on the SAME base + toolchain as environment/Dockerfile
# so a submission is graded under the toolchain it was produced against.
# --------------------------------------------------------------------------- #
RUN mkdir -p /output /logs/verifier /tests
# Rewardkit 0.2.3 requires Python >=3.12, while this pinned Ubuntu base has
# Python 3.8. Install a pinned standalone Python and verifier environment.
RUN apt-get update && apt-get install -y --no-install-recommends curl \
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

# The Codex launcher needs a newer Node runtime than Ubuntu 20.04 provides.
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
    npm --version

RUN set -eux; \
    case "$(dpkg --print-architecture)" in \
      arm64) codex_arch="linux-arm64"; codex_arch_sha512="359fc36905297109b19aa79eed9f6e0b5af3c371a149ba286b071a4ded4b379624f969629d42867535c98029514fff6881010433d4d6c58cefc4f7e3e46ff116" ;; \
      amd64) codex_arch="linux-x64"; codex_arch_sha512="a34e4dc803820f28123d1a35ca29f3c6f91149d9ac672043f44ee66e99a345a9d27ccf25ca9a96b50804a385df364c21b82476685bbc9a518eb101855d56d5c3" ;; \
      *) exit 1 ;; \
    esac; \
    curl -fsSLo /tmp/codex.tgz "https://registry.npmjs.org/@openai/codex/-/codex-0.169.0.tgz"; \
    curl -fsSLo /tmp/codex-arch.tgz "https://registry.npmjs.org/@openai/codex/-/codex-0.169.0-${codex_arch}.tgz"; \
    echo "2a1cd896428fc6836cb11f02126e39223aa71569fb52d945e02883ded3893de6b9d7106cecc687cb45101bd1926c2aa4e8bae39f941d243574403d7f1605a51b  /tmp/codex.tgz" | sha512sum -c -; \
    echo "${codex_arch_sha512}  /tmp/codex-arch.tgz" | sha512sum -c -; \
    npm install -g --omit=optional --no-audit --no-fund /tmp/codex.tgz; \
    codex_root="$(npm root -g)/@openai/codex"; \
    tar -xzf /tmp/codex-arch.tgz -C "$codex_root" --strip-components=1 package/vendor; \
    rm -f /tmp/codex.tgz /tmp/codex-arch.tgz; \
    npm cache clean --force; \
    codex --version

COPY . /tests
RUN chmod +x /tests/test.sh
WORKDIR /
