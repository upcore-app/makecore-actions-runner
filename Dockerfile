# The one image a makecore machine runs.
#
# It is a whole operating system, not a container image. A job runs as a virtual
# machine of its own, so this carries an init, a kernel and a Docker daemon. The
# daemon on the node boots a copy-on-write clone of it.
#
# Built from ubuntu rather than from ghcr.io/actions/actions-runner. That image
# has no init and no kernel, and its entrypoint is the runner itself. That is
# what a container needs, and what a machine cannot use.
FROM ubuntu:26.04

ARG DEBIAN_FRONTEND=noninteractive
ARG RUNNER_VERSION=2.328.0
ARG GITLAB_RUNNER_VERSION=v17.11.0

# amd64 or arm64. The runner downloads and the tool cache spell the same
# architectures differently, so both spellings appear below.
ARG TARGETARCH

# -e as well as pipefail.
#
# Without it a command that fails inside a loop or a group does not stop the
# build. The loop over the Node versions is the case that matters: the first
# download could fail, the second succeed, and the image would ship with one of
# the two toolchains and no error anywhere.
SHELL ["/bin/bash", "-eo", "pipefail", "-c"]

# The init, the kernel, and the base tools.
#
# linux-image-virtual is what makes this bootable. The node copies the kernel
# and the initramfs out of here when it builds a root disk, and Cloud Hypervisor
# boots those. Without it this is a container image again.
#
# The initramfs is not optional. This kernel builds virtio_blk as a module, so a
# guest without it boots and then cannot find its own root disk.
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
        systemd \
        systemd-sysv \
        linux-image-virtual \
        initramfs-tools \
        udev \
        dbus \
        iproute2 \
        iputils-ping \
        ca-certificates \
        curl \
        wget \
        gnupg \
        git \
        git-lfs \
        jq \
        unzip \
        zip \
        xz-utils \
        zstd \
        build-essential \
        pkg-config \
        openssh-client \
        rsync \
        sudo \
        e2fsprogs \
 && rm -rf /var/lib/apt/lists/*

# The Docker daemon, not only the client.
#
# A machine has no sidecar. Its own dockerd serves a job's `container:` and
# `services:`, and on the GitLab path it runs every build container. The node
# mounts the cache disk over /var/lib/docker before this starts.
RUN install -m 0755 -d /etc/apt/keyrings \
 && curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc \
 && chmod a+r /etc/apt/keyrings/docker.asc \
 && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
        > /etc/apt/sources.list.d/docker.list \
 && apt-get update \
 && apt-get install -y --no-install-recommends \
        docker-ce \
        docker-ce-cli \
        containerd.io \
        docker-buildx-plugin \
        docker-compose-plugin \
 && rm -rf /var/lib/apt/lists/*

# What the Actions runner needs to run. It is a .NET program.
#
# Not `./bin/installdependencies.sh` from the tarball. That script holds a list
# of package names from older distributions and tries each one until it finds
# one that exists. This release ships none of them, so the script spends minutes
# failing and then installs nothing, and the runner does not start.
#
# The names are resolved from the archive of this release instead, so the next
# one needs no change here.
RUN apt-get update \
 && icu="$(apt-cache search --names-only '^libicu[0-9]+$' | sort -V | tail -n1 | cut -d' ' -f1)" \
 && ssl="$(apt-cache search --names-only '^libssl[0-9]+(t64)?$' | sort -V | tail -n1 | cut -d' ' -f1)" \
 && if [ -z "$icu" ] || [ -z "$ssl" ]; then \
        echo "this release ships no libicu or no libssl under a name we know: icu='$icu' ssl='$ssl'" >&2 ; \
        exit 1 ; \
    fi \
 && echo "runner dependencies: $icu $ssl" \
 && apt-get install -y --no-install-recommends \
        "$icu" \
        "$ssl" \
        libkrb5-3 \
        zlib1g \
 && rm -rf /var/lib/apt/lists/*

# The GitHub Actions runner, where the config disk of a machine expects it.
RUN useradd -m -s /bin/bash runner \
 && usermod -aG docker runner \
 && case "${TARGETARCH}" in \
        amd64) runner_arch=x64 ;; \
        arm64) runner_arch=arm64 ;; \
        *) echo "unsupported architecture ${TARGETARCH}" >&2; exit 1 ;; \
    esac \
 && cd /home/runner \
 && curl -fsSL -o runner.tar.gz \
        "https://github.com/actions/runner/releases/download/v${RUNNER_VERSION}/actions-runner-linux-${runner_arch}-${RUNNER_VERSION}.tar.gz" \
 && tar -xzf runner.tar.gz \
 && rm runner.tar.gz \
 && chown -R runner:runner /home/runner

# gitlab-runner, for a machine that serves a GitLab repository.
#
# One image serves both hosts. A machine runs whichever its config disk names,
# and a node then keeps one root disk rather than two.
RUN case "${TARGETARCH}" in \
        amd64) gl_arch=amd64 ;; \
        arm64) gl_arch=arm64 ;; \
        *) echo "unsupported architecture ${TARGETARCH}" >&2; exit 1 ;; \
    esac \
 && curl -fsSL -o /usr/local/bin/gitlab-runner \
        "https://gitlab-runner-downloads.s3.amazonaws.com/${GITLAB_RUNNER_VERSION}/binaries/gitlab-runner-linux-${gl_arch}" \
 && chmod 0755 /usr/local/bin/gitlab-runner \
 && mkdir -p /etc/gitlab-runner

# The toolchains a workflow expects to find already there.
#
# Node goes into GitHub's own tool cache directory, in the layout and with the
# `.complete` marker that `setup-node` looks for. A workflow asking for one of
# these versions then downloads nothing.
ARG NODE_LTS_A=22.20.0
ARG NODE_LTS_B=20.19.5

RUN case "${TARGETARCH}" in \
        amd64) node_arch=x64 ;; \
        arm64) node_arch=arm64 ;; \
        *) echo "unsupported architecture ${TARGETARCH}" >&2; exit 1 ;; \
    esac \
 && for version in "${NODE_LTS_A}" "${NODE_LTS_B}"; do \
        target="/opt/hostedtoolcache/node/${version}/${node_arch}" ; \
        mkdir -p "${target}" ; \
        curl -fsSL "https://nodejs.org/dist/v${version}/node-v${version}-linux-${node_arch}.tar.xz" \
            | tar -xJ --strip-components=1 -C "${target}" ; \
        touch "/opt/hostedtoolcache/node/${version}/${node_arch}.complete" ; \
    done \
 && ln -sf "/opt/hostedtoolcache/node/${NODE_LTS_A}/${node_arch}/bin/node" /usr/local/bin/node \
 && ln -sf "/opt/hostedtoolcache/node/${NODE_LTS_A}/${node_arch}/bin/npm" /usr/local/bin/npm \
 && ln -sf "/opt/hostedtoolcache/node/${NODE_LTS_A}/${node_arch}/bin/npx" /usr/local/bin/npx

ARG GO_VERSION=1.25.1

RUN curl -fsSL "https://go.dev/dl/go${GO_VERSION}.linux-${TARGETARCH}.tar.gz" \
        | tar -xz -C /usr/local \
 && ln -sf /usr/local/go/bin/go /usr/local/bin/go \
 && ln -sf /usr/local/go/bin/gofmt /usr/local/bin/gofmt

RUN apt-get update \
 && apt-get install -y --no-install-recommends \
        python3 \
        python3-pip \
        python3-venv \
        openjdk-21-jdk-headless \
        openjdk-17-jdk-headless \
 && rm -rf /var/lib/apt/lists/*

# What a machine must not start on its own.
#
# The node writes one unit into the root disk when it builds it, and that unit
# runs the job. Docker is started by that unit, after the cache disk is mounted
# over its image store — started here it would make a store on the root disk and
# the job would run cold.
# Docker is disabled, not masked. The init of the guest starts it by hand once
# the cache disk is mounted over its image store, and a masked unit cannot be
# started at all.
#
# The rest are masked, because nothing should ever start them.
RUN systemctl mask \
        getty@tty1.service \
        serial-getty@ttyS0.service \
        systemd-resolved.service \
        apt-daily.timer \
        apt-daily-upgrade.timer \
 && systemctl disable docker.service docker.socket || true \
 && rm -f /etc/machine-id \
 && rm -rf /var/cache/apt/archives/*.deb

# systemd, so the machine comes up as a machine.
ENTRYPOINT ["/lib/systemd/systemd"]
