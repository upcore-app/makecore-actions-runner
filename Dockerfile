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
ARG RUNNER_VERSION=2.337.0
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
 && install -d -o runner -g runner /opt/hostedtoolcache \
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
ARG NODE_LTS_C=24.19.0

RUN case "${TARGETARCH}" in \
        amd64) node_arch=x64 ;; \
        arm64) node_arch=arm64 ;; \
        *) echo "unsupported architecture ${TARGETARCH}" >&2; exit 1 ;; \
    esac \
 && for version in "${NODE_LTS_A}" "${NODE_LTS_B}" "${NODE_LTS_C}"; do \
        target="/opt/hostedtoolcache/node/${version}/${node_arch}" ; \
        mkdir -p "${target}" ; \
        curl -fsSL "https://nodejs.org/dist/v${version}/node-v${version}-linux-${node_arch}.tar.xz" \
            | tar -xJ --strip-components=1 -C "${target}" ; \
        touch "/opt/hostedtoolcache/node/${version}/${node_arch}.complete" ; \
    done \
 && chown -R runner:runner /opt/hostedtoolcache/node \
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
 && rm -rf /var/lib/apt/lists/*

# ---------------------------------------------------------------------------
# Parity with GitHub's `ubuntu-24.04` runner image.
#
# Everything below exists because a workflow written against `ubuntu-latest`
# expects to find it already there. The source of truth is
# `images/ubuntu/toolsets/toolset-2404.json` in `actions/runner-images`; the
# lists here are that file, transcribed. When GitHub moves a version, this is
# the file that has to move with it.
#
# Two deliberate differences. This is Ubuntu 26.04 and GitHub's is 24.04, so a
# package name that changed between the two is resolved from the archive rather
# than pinned. And nothing here is Azure-specific: GitHub's image carries agents
# and telemetry for the fleet it runs on, which a machine of ours has no use for.
#
# Nothing is installed with `|| true`. A name that moved must fail the build and
# be fixed here, not disappear into an image that ships a hole where a toolchain
# was supposed to be.
#
# What is deliberately absent, and why. Each of these cost more build minutes
# than the workflows on this fleet get back, and each has a `setup-*` action
# that installs it on demand:
#
#   Swift, Haskell (GHC/cabal/stack), Julia, Kotlin, Miniconda, Homebrew,
#   the PowerShell Az and Microsoft.Graph modules, the CodeQL bundle,
#   Temurin 8/11/25, ant.
#
# The CodeQL bundle is the one to understand: `github/codeql-action` downloads
# its own when the tool cache has none, so a code-scanning job still works and
# only pays the download. The rest break a workflow that assumes them without
# asking a `setup-*` action first. PHP, .NET, Rust, PowerShell itself, the
# browsers, the cloud CLIs and the full gcc/clang matrix all stay.
# ---------------------------------------------------------------------------

# universe and multiverse, which most of the list below lives in.
#
# The base image enables main and restricted only. Nothing here is exotic —
# shellcheck, mediainfo, aria2 and haveged are universe, 7zip-rar is
# multiverse — but with the components off apt reports every one of them as an
# unlocatable package, which is one error for what is really one cause.
#
# 26.04 writes its sources in deb822 at /etc/apt/sources.list.d/ubuntu.sources.
# The one-line format is handled too, so this layer does not have to be revisited
# if a future base image goes back to it.
RUN if [ -f /etc/apt/sources.list.d/ubuntu.sources ]; then \
        sed -i -E 's/^Components:.*/Components: main restricted universe multiverse/' \
            /etc/apt/sources.list.d/ubuntu.sources ; \
    elif [ -f /etc/apt/sources.list ]; then \
        sed -i -E 's/^(deb(-src)? .*ubuntu[^ ]* [a-z-]+) main.*/\1 main restricted universe multiverse/' \
            /etc/apt/sources.list ; \
    else \
        echo "this base image writes its apt sources somewhere new" >&2 ; exit 1 ; \
    fi \
 && grep -qE 'universe' /etc/apt/sources.list.d/ubuntu.sources /etc/apt/sources.list 2>/dev/null \
    || { echo "universe is still not enabled after rewriting the sources" >&2; exit 1; }

# The apt packages, as three lists: `vital`, `common` and `cmd` in the toolset.
#
# --no-install-recommends throughout, which is what GitHub does. A recommends
# pulled in here is a package no workflow asked for on every root disk.
#
# `upx` rather than `upx-ucl` is what the toolset says, but on this release
# `upx` is a virtual package and only `upx-ucl` provides it. The real name is
# used here so the dependency resolver never has to make that choice.
#
# One `apt-get install` for the whole list, because seventy of them one at a
# time is minutes of nothing. When that fails, the packages are retried singly
# to find which name is the bad one — apt's own error names a file and an exit
# code, not the package, and a list this long is not something to bisect by hand.
ARG APT_TOOLSET_PACKAGES="\
        bzip2 curl g++ gcc make jq tar unzip wget \
        autoconf automake dbus bind9-dnsutils dpkg dpkg-dev fakeroot \
        fonts-noto-color-emoji gnupg2 iproute2 iputils-ping libyaml-dev \
        libtool libssl-dev libicu-dev libsqlite3-dev locales mercurial \
        openssh-client pkg-config python-is-python3 rpm texinfo \
        tk tree tzdata upx-ucl xvfb xz-utils zsync \
        acl aria2 binutils bison brotli libnss3-tools coreutils file \
        findutils flex ftp haveged lz4 m4 mediainfo netcat-openbsd net-tools \
        7zip 7zip-rar parallel patchelf pigz pollinate rsync shellcheck \
        sphinxsearch sqlite3 ssh sshpass sudo systemd-coredump swig \
        telnet time zip"

RUN apt-get update \
 && if ! apt-get install -y --no-install-recommends ${APT_TOOLSET_PACKAGES}; then \
        echo "=== the batch failed; finding which package ===" >&2 ; \
        failed="" ; \
        for pkg in ${APT_TOOLSET_PACKAGES}; do \
            apt-get install -y --no-install-recommends "${pkg}" > /dev/null 2>&1 \
                || failed="${failed} ${pkg}" ; \
        done ; \
        echo "packages this release will not install:${failed}" >&2 ; \
        exit 1 ; \
    fi \
 && locale-gen en_US.UTF-8 \
 && rm -rf /var/lib/apt/lists/*

# The compiler matrix. GitHub ships three of each, not one.
#
# `gcc`/`g++` from build-essential above is whatever this release defaults to;
# these are the versioned binaries a workflow names explicitly.
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
        gcc-12 g++-12 gfortran-12 \
        gcc-13 g++-13 gfortran-13 \
        gcc-14 g++-14 gfortran-14 \
        clang-17 clang-18 clang-19 \
        clang-format-17 clang-format-18 clang-format-19 \
        clang-tidy-17 clang-tidy-18 clang-tidy-19 \
        lld-18 llvm-18 \
 && update-alternatives --install /usr/bin/clang clang /usr/bin/clang-18 100 \
 && update-alternatives --install /usr/bin/clang++ clang++ /usr/bin/clang++-18 100 \
 && update-alternatives --install /usr/bin/clang-format clang-format /usr/bin/clang-format-18 100 \
 && update-alternatives --install /usr/bin/clang-tidy clang-tidy /usr/bin/clang-tidy-18 100 \
 && rm -rf /var/lib/apt/lists/*

# The global npm packages of the toolset's `node_modules`, plus node-gyp.
#
# node-gyp is the one addition to GitHub's list, and it is here because of how
# a native module resolves its compiler. npm puts its own bundled copy on PATH
# for the lifecycle scripts it runs, so `node-gyp` resolves under npm without
# ever being installed; bun runs those same scripts with no such PATH, so a
# package whose install script falls back from a prebuild to `node-gyp rebuild`
# dies with 127. Installing it globally makes the fallback path work under both.
#
# Into every cached Node, not only the default. `setup-node` puts the version a
# workflow pins at the front of PATH, so a global installed against 22 alone is
# not on PATH for a job that asked for 24.
RUN for prefix in /opt/hostedtoolcache/node/*/*/ ; do \
        [ -x "${prefix}bin/npm" ] || continue ; \
        echo "global modules into ${prefix}" ; \
        "${prefix}bin/npm" install -g --prefix "${prefix}" \
            node-gyp grunt gulp n parcel typescript newman \
            webpack webpack-cli lerna yarn ; \
        chown -R runner:runner "${prefix}lib/node_modules" "${prefix}bin" ; \
    done

# Python, in the tool cache layout `setup-python` reads.
#
# The versions come from `actions/python-versions`, which is where the action
# itself would download them from. Building them here rather than letting each
# job fetch one is the whole point of a cache.
#
# Each version is published for several Ubuntu releases, so the release has to
# be part of the selection -- without it jq returns every match and the URL is
# three URLs. This release's own build is preferred and 24.04 is the fallback.
#
# The tarball's setup.sh is shipped mode 0644 with no shebang and copies `./*`,
# so it has to be fed to bash from inside its own directory rather than run.
# It reads the tool cache path out of the environment, and the ENV that sets
# that for the image is further down, so it is passed here explicitly.
ARG PYTHON_VERSIONS="3.10 3.11 3.12 3.13 3.14"

RUN case "${TARGETARCH}" in \
        amd64) tc_arch=x64 ;; \
        arm64) tc_arch=arm64 ;; \
        *) echo "unsupported architecture ${TARGETARCH}" >&2; exit 1 ;; \
    esac \
 && . /etc/os-release \
 && manifest="$(curl -fsSL https://raw.githubusercontent.com/actions/python-versions/main/versions-manifest.json)" \
 && for series in ${PYTHON_VERSIONS}; do \
        url="" ; \
        for pv in "${VERSION_ID}" 24.04 22.04; do \
            url="$(echo "${manifest}" | jq -r --arg s "${series}." --arg a "${tc_arch}" --arg p "${pv}" '[.[] | select(.version | startswith($s)) | select(.stable)] | first | [.files[] | select(.platform == "linux" and .arch == $a and .platform_version == $p) | .download_url] | first // empty')" ; \
            if [ -n "${url}" ]; then echo "python ${series}: ubuntu ${pv}" ; break ; fi ; \
        done ; \
        if [ -z "${url}" ]; then \
            echo "no python ${series} for linux/${tc_arch} in the manifest" >&2 ; exit 1 ; \
        fi ; \
        tmp="$(mktemp -d)" ; \
        curl -fsSL "${url}" | tar -xz -C "${tmp}" ; \
        ( cd "${tmp}" && AGENT_TOOLSDIRECTORY=/opt/hostedtoolcache bash ./setup.sh ) ; \
        rm -rf "${tmp}" ; \
    done \
 && newest="$(ls /opt/hostedtoolcache/Python | sort -V | tail -n1)" \
 && if [ -z "${newest}" ]; then echo "the python setup script installed nothing" >&2; exit 1; fi \
 && chown -R runner:runner /opt/hostedtoolcache/Python \
 && ln -sf "/opt/hostedtoolcache/Python/${newest}/${tc_arch}/bin/python3" /usr/local/bin/python3 \
 && python3 --version

# pipx, and the two packages the toolset installs with it.
RUN apt-get update \
 && apt-get install -y --no-install-recommends python3-pip pipx \
 && rm -rf /var/lib/apt/lists/* \
 && PIPX_HOME=/opt/pipx PIPX_BIN_DIR=/usr/local/bin pipx install yamllint \
 && PIPX_HOME=/opt/pipx PIPX_BIN_DIR=/usr/local/bin pipx install ansible-core

# Go, in the tool cache as well as at /usr/local/go.
#
# The symlinks from the layer above stay: a job that runs `go` without asking
# `setup-go` for a version gets the default, as it does on GitHub.
ARG GO_VERSIONS="1.24 1.25 1.26"

RUN case "${TARGETARCH}" in \
        amd64) tc_arch=x64 ; dl_arch=amd64 ;; \
        arm64) tc_arch=arm64 ; dl_arch=arm64 ;; \
        *) echo "unsupported architecture ${TARGETARCH}" >&2; exit 1 ;; \
    esac \
 && manifest="$(curl -fsSL https://raw.githubusercontent.com/actions/go-versions/main/versions-manifest.json)" \
 && for series in ${GO_VERSIONS}; do \
        version="$(echo "${manifest}" | jq -r --arg s "${series}." \
            '[.[] | select(.version | startswith($s)) | select(.stable)] | first | .version')" ; \
        if [ -z "${version}" ] || [ "${version}" = "null" ]; then \
            echo "no stable go ${series} in the manifest" >&2 ; exit 1 ; \
        fi ; \
        target="/opt/hostedtoolcache/go/${version}/${tc_arch}" ; \
        mkdir -p "${target}" ; \
        curl -fsSL "https://go.dev/dl/go${version}.linux-${dl_arch}.tar.gz" \
            | tar -xz --strip-components=1 -C "${target}" ; \
        touch "/opt/hostedtoolcache/go/${version}/${tc_arch}.complete" ; \
    done \
 && chown -R runner:runner /opt/hostedtoolcache/go

# Ruby, in the tool cache, from the builds `setup-ruby` uses.
#
# These are built for a specific Ubuntu release and for a specific arch, and
# both belong in the asset name -- matching on the release alone also matches
# the -arm64 asset of the same release. They are dynamically linked against
# libssl and libyaml, both installed above.
ARG RUBY_VERSIONS="3.2 3.3 3.4"

RUN case "${TARGETARCH}" in \
        amd64) tc_arch=x64 ;; \
        arm64) tc_arch=arm64 ;; \
        *) echo "unsupported architecture ${TARGETARCH}" >&2; exit 1 ;; \
    esac \
 && . /etc/os-release \
 && case "${TARGETARCH}" in amd64) rb_suffix="-x64" ;; arm64) rb_suffix="-arm64" ;; esac \
 && releases="$(curl -fsSL https://api.github.com/repos/ruby/ruby-builder/releases?per_page=100)" \
 && for series in ${RUBY_VERSIONS}; do \
        url="" ; \
        for pv in "${VERSION_ID}" 24.04 22.04; do \
            url="$(echo "${releases}" | jq -r --arg s "ruby-${series}." --arg e "-ubuntu-${pv}${rb_suffix}.tar.gz" '[.[].assets[] | select(.name | startswith($s)) | select(.name | endswith($e))] | sort_by(.name | capture("^ruby-(?<v>[0-9]+(\\.[0-9]+)*)-").v | split(".") | map(tonumber)) | last | .browser_download_url // empty')" ; \
            if [ -n "${url}" ] && [ "${url}" != "null" ]; then echo "ruby ${series}: ubuntu ${pv}${rb_suffix}" ; break ; fi ; \
            url="" ; \
        done ; \
        if [ -z "${url}" ]; then \
            echo "no ruby ${series} build for this release or its fallbacks" >&2 ; exit 1 ; \
        fi ; \
        version="$(basename "${url}" | sed -E 's/^ruby-([0-9.]+)-.*/\1/')" ; \
        target="/opt/hostedtoolcache/Ruby/${version}/${tc_arch}" ; \
        mkdir -p "${target}" ; \
        curl -fsSL "${url}" | tar -xz --strip-components=1 -C "${target}" ; \
        touch "/opt/hostedtoolcache/Ruby/${version}/${tc_arch}.complete" ; \
    done \
 && default="/opt/hostedtoolcache/Ruby/$(ls /opt/hostedtoolcache/Ruby | sort -V | tail -n1)/${tc_arch}" \
 && ln -sf "${default}/bin/ruby" /usr/local/bin/ruby \
 && ln -sf "${default}/bin/gem" /usr/local/bin/gem \
 && "${default}/bin/gem" install --no-document multi_json fastlane \
 && chown -R runner:runner /opt/hostedtoolcache/Ruby

# Java, and the JAVA_HOME_<version>_<arch> variables that name each JDK.
#
# From Adoptium, not from apt: Temurin is where GitHub takes these from anyway,
# and one source does not thin out as the distribution drops old JDKs.
#
# Two, not GitHub's five. 8, 11 and 25 are 420 MB of JDK for versions nothing
# here builds against, and `setup-java` downloads any of them on demand. A
# workflow pinning one of those without `setup-java` is the case this breaks.
ARG JAVA_VERSIONS="17 21"
ARG JAVA_DEFAULT=17

RUN case "${TARGETARCH}" in \
        amd64) jdk_arch=x64 ;; \
        arm64) jdk_arch=aarch64 ;; \
        *) echo "unsupported architecture ${TARGETARCH}" >&2; exit 1 ;; \
    esac \
 && case "${TARGETARCH}" in amd64) home_arch=X64 ;; arm64) home_arch=ARM64 ;; esac \
 && mkdir -p /usr/lib/jvm \
 && for version in ${JAVA_VERSIONS}; do \
        target="/usr/lib/jvm/temurin-${version}" ; \
        mkdir -p "${target}" ; \
        curl -fsSL "https://api.adoptium.net/v3/binary/latest/${version}/ga/linux/${jdk_arch}/jdk/hotspot/normal/eclipse" \
            | tar -xz --strip-components=1 -C "${target}" ; \
        echo "JAVA_HOME_${version}_${home_arch}=${target}" >> /etc/environment ; \
    done \
 && echo "JAVA_HOME=/usr/lib/jvm/temurin-${JAVA_DEFAULT}" >> /etc/environment \
 && update-alternatives --install /usr/bin/java java "/usr/lib/jvm/temurin-${JAVA_DEFAULT}/bin/java" 100 \
 && update-alternatives --install /usr/bin/javac javac "/usr/lib/jvm/temurin-${JAVA_DEFAULT}/bin/javac" 100

ENV JAVA_HOME=/usr/lib/jvm/temurin-17

# Maven and Gradle, which the toolset carries beside the JDKs.
ARG MAVEN_VERSION=3.9.16
ARG GRADLE_VERSION=9.7.1

RUN curl -fsSL "https://archive.apache.org/dist/maven/maven-3/${MAVEN_VERSION}/binaries/apache-maven-${MAVEN_VERSION}-bin.tar.gz" \
        | tar -xz -C /opt \
 && ln -sf "/opt/apache-maven-${MAVEN_VERSION}/bin/mvn" /usr/local/bin/mvn \
 && curl -fsSL -o /tmp/gradle.zip "https://services.gradle.org/distributions/gradle-${GRADLE_VERSION}-bin.zip" \
 && unzip -q /tmp/gradle.zip -d /opt \
 && rm /tmp/gradle.zip \
 && ln -sf "/opt/gradle-${GRADLE_VERSION}/bin/gradle" /usr/local/bin/gradle

# .NET, from the install script rather than from apt.
#
# Microsoft's prod feed for 26.04 exists but carries no dotnet-sdk at all, and
# 26.04's own archive has only .NET 10 -- neither can produce the 8/9/10 set
# GitHub's image has. dotnet-install.sh is release-independent and installs the
# channels side by side under one root, which is what `dotnet --list-sdks`
# wants anyway.
ARG DOTNET_CHANNELS="8.0 9.0 10.0"

RUN curl -fsSL -o /tmp/dotnet-install.sh https://dot.net/v1/dotnet-install.sh \
 && chmod +x /tmp/dotnet-install.sh \
 && for channel in ${DOTNET_CHANNELS}; do \
        echo "dotnet sdk ${channel}" ; \
        /tmp/dotnet-install.sh --channel "${channel}" --install-dir /usr/share/dotnet --no-path ; \
    done \
 && rm /tmp/dotnet-install.sh \
 && ln -sf /usr/share/dotnet/dotnet /usr/local/bin/dotnet \
 && dotnet --list-sdks \
 && DOTNET_CLI_TELEMETRY_OPTOUT=1 dotnet tool install --tool-path /usr/local/bin nbgv

# PowerShell, from the release tarball.
#
# There is no `powershell` package for 26.04 in any Microsoft feed, so the
# distro-independent archive is the only way in. Same binary the deb ships.
RUN case "${TARGETARCH}" in \
        amd64) pwsh_arch=x64 ;; \
        arm64) pwsh_arch=arm64 ;; \
        *) echo "no powershell build for ${TARGETARCH}" >&2 ; exit 1 ;; \
    esac \
 && pwsh_version="$(curl -fsSL https://api.github.com/repos/PowerShell/PowerShell/releases/latest | jq -r '.tag_name | ltrimstr("v")')" \
 && echo "powershell ${pwsh_version} ${pwsh_arch}" \
 && mkdir -p /opt/microsoft/powershell/7 \
 && curl -fsSL "https://github.com/PowerShell/PowerShell/releases/download/v${pwsh_version}/powershell-${pwsh_version}-linux-${pwsh_arch}.tar.gz" \
        | tar -xz -C /opt/microsoft/powershell/7 \
 && chmod 0755 /opt/microsoft/powershell/7/pwsh \
 && ln -sf /opt/microsoft/powershell/7/pwsh /usr/bin/pwsh \
 && pwsh --version

ENV DOTNET_ROOT=/usr/share/dotnet \
    DOTNET_CLI_TELEMETRY_OPTOUT=1 \
    DOTNET_NOLOGO=1 \
    DOTNET_SKIP_FIRST_TIME_EXPERIENCE=1

# The PowerShell modules of the toolset, minus Az and Microsoft.Graph.
#
# Those two were the slowest step in this file by a wide margin, and a workflow
# that wants them can `Install-Module Az` itself. Pester and PSScriptAnalyzer
# are small, fast, and what a PowerShell job actually reaches for.
RUN pwsh -NoProfile -Command \
        "Set-PSRepository -Name PSGallery -InstallationPolicy Trusted; \
         Install-Module -Name Pester -RequiredVersion 5.9.0 -Scope AllUsers -Force -SkipPublisherCheck; \
         Install-Module -Name PSScriptAnalyzer -Scope AllUsers -Force"

# Rust, for the runner user as well as root: rustup installs per-user, and a
# job runs as `runner`.
ENV RUSTUP_HOME=/usr/share/rust/.rustup \
    CARGO_HOME=/usr/share/rust/.cargo \
    PATH=/usr/share/rust/.cargo/bin:$PATH

RUN curl -fsSL https://sh.rustup.rs \
        | sh -s -- -y --profile minimal --default-toolchain stable --no-modify-path \
 && /usr/share/rust/.cargo/bin/rustup component add rustfmt clippy \
 && chmod -R a+rwX /usr/share/rust

# PHP, from the archive.
#
# ondrej's PPA publishes nothing for 26.04, so pinning 8.3 the way GitHub's
# image does is not available here; this takes whatever the release ships
# (8.5 at time of writing). A workflow that needs a specific PHP uses
# shivammathur/setup-php, which downloads its own regardless.
#
# The version is resolved from the archive instead of pinned so this layer
# does not break the next time the default moves.
RUN apt-get update \
 && php_version="$(apt-cache depends php | awk '/Depends: php[0-9]/ {sub(/^php/,"",$2); print $2; exit}')" \
 && if [ -z "${php_version}" ]; then echo "cannot resolve a php version from the archive" >&2; exit 1; fi \
 && echo "php ${php_version}" \
 && apt-get install -y --no-install-recommends \
        "php${php_version}" "php${php_version}-cli" "php${php_version}-common" \
        "php${php_version}-curl" "php${php_version}-mbstring" "php${php_version}-xml" \
        "php${php_version}-zip" "php${php_version}-bcmath" "php${php_version}-intl" \
        "php${php_version}-sqlite3" "php${php_version}-mysql" "php${php_version}-pgsql" \
        "php${php_version}-xdebug" "php${php_version}-pcov" \
 && rm -rf /var/lib/apt/lists/* \
 && curl -fsSL https://getcomposer.org/installer -o /tmp/composer-setup.php \
 && php /tmp/composer-setup.php --install-dir=/usr/local/bin --filename=composer \
 && rm /tmp/composer-setup.php \
 && curl -fsSL -o /usr/local/bin/phpunit https://phar.phpunit.de/phpunit-8.phar \
 && chmod 0755 /usr/local/bin/phpunit

# The build tools: cmake, ninja, bazel and vcpkg.
#
# cmake is pinned where GitHub pins it. Their note says 4.0 breaks projects that
# still declare a 3.x minimum, and a runner is the wrong place to find that out.
ARG CMAKE_VERSION=3.31.6

RUN case "${TARGETARCH}" in amd64) cm_arch=x86_64 ;; arm64) cm_arch=aarch64 ;; esac \
 && curl -fsSL "https://github.com/Kitware/CMake/releases/download/v${CMAKE_VERSION}/cmake-${CMAKE_VERSION}-linux-${cm_arch}.tar.gz" \
        | tar -xz --strip-components=1 -C /usr/local \
 && apt-get update \
 && apt-get install -y --no-install-recommends ninja-build \
 && rm -rf /var/lib/apt/lists/* \
 && case "${TARGETARCH}" in amd64) bz_arch=amd64 ;; arm64) bz_arch=arm64 ;; esac \
 && curl -fsSL -o /usr/local/bin/bazelisk \
        "https://github.com/bazelbuild/bazelisk/releases/latest/download/bazelisk-linux-${bz_arch}" \
 && chmod 0755 /usr/local/bin/bazelisk \
 && ln -sf /usr/local/bin/bazelisk /usr/local/bin/bazel \
 && git clone --depth 1 https://github.com/microsoft/vcpkg /usr/local/share/vcpkg \
 && /usr/local/share/vcpkg/bootstrap-vcpkg.sh -disableMetrics \
 && ln -sf /usr/local/share/vcpkg/vcpkg /usr/local/bin/vcpkg \
 && chmod -R a+rwX /usr/local/share/vcpkg

ENV VCPKG_INSTALLATION_ROOT=/usr/local/share/vcpkg

# The cloud CLIs.
RUN case "${TARGETARCH}" in amd64) aws_arch=x86_64 ; gcp_arch=x86_64 ;; arm64) aws_arch=aarch64 ; gcp_arch=arm ;; esac \
 && curl -fsSL -o /tmp/awscli.zip "https://awscli.amazonaws.com/awscli-exe-linux-${aws_arch}.zip" \
 && unzip -q /tmp/awscli.zip -d /tmp \
 && /tmp/aws/install \
 && rm -rf /tmp/awscli.zip /tmp/aws \
 && curl -fsSL -o /tmp/sam.zip "https://github.com/aws/aws-sam-cli/releases/latest/download/aws-sam-cli-linux-${aws_arch}.zip" \
 && unzip -q /tmp/sam.zip -d /tmp/sam \
 && /tmp/sam/install \
 && rm -rf /tmp/sam.zip /tmp/sam \
 && case "${TARGETARCH}" in amd64) sm_arch=64bit ;; arm64) sm_arch=arm64 ;; esac \
 && curl -fsSL -o /tmp/session-manager.deb \
        "https://s3.amazonaws.com/session-manager-downloads/plugin/latest/ubuntu_${sm_arch}/session-manager-plugin.deb" \
 && dpkg -i /tmp/session-manager.deb \
 && rm /tmp/session-manager.deb \
 && curl -fsSL "https://dl.google.com/dl/cloudsdk/channels/rapid/downloads/google-cloud-cli-linux-${gcp_arch}.tar.gz" \
        | tar -xz -C /usr/local \
 && /usr/local/google-cloud-sdk/install.sh --quiet --path-update false --usage-reporting false \
 && for bin in gcloud gsutil bq; do ln -sf "/usr/local/google-cloud-sdk/bin/${bin}" "/usr/local/bin/${bin}"; done

RUN curl -fsSL https://aka.ms/InstallAzureCLIDeb | bash \
 && az extension add --name azure-devops --system \
 && case "${TARGETARCH}" in amd64) bicep_arch=x64 ;; arm64) bicep_arch=arm64 ;; esac \
 && curl -fsSL -o /usr/local/bin/bicep \
        "https://github.com/Azure/bicep/releases/latest/download/bicep-linux-${bicep_arch}" \
 && chmod 0755 /usr/local/bin/bicep \
 && case "${TARGETARCH}" in amd64) az_arch=amd64 ;; arm64) az_arch=arm64 ;; esac \
 && curl -fsSL "https://aka.ms/downloadazcopy-v10-linux" \
        | tar -xz --strip-components=1 -C /usr/local/bin --wildcards '*/azcopy' \
 && chmod 0755 /usr/local/bin/azcopy \
 && ln -sf /usr/local/bin/azcopy /usr/local/bin/azcopy10

# GitHub's own CLI, and the tools that talk to registries and clusters.
RUN mkdir -p /etc/apt/keyrings \
 && curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
        -o /etc/apt/keyrings/githubcli.gpg \
 && chmod a+r /etc/apt/keyrings/githubcli.gpg \
 && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli.gpg] https://cli.github.com/packages stable main" \
        > /etc/apt/sources.list.d/github-cli.list \
 && apt-get update \
 && apt-get install -y --no-install-recommends gh podman buildah skopeo \
 && rm -rf /var/lib/apt/lists/*

RUN arch="$(dpkg --print-architecture)" \
 && curl -fsSL -o /usr/local/bin/kubectl \
        "https://dl.k8s.io/release/$(curl -fsSL https://dl.k8s.io/release/stable.txt)/bin/linux/${arch}/kubectl" \
 && curl -fsSL -o /usr/local/bin/kind \
        "https://kind.sigs.k8s.io/dl/latest/kind-linux-${arch}" \
 && curl -fsSL -o /usr/local/bin/minikube \
        "https://storage.googleapis.com/minikube/releases/latest/minikube-linux-${arch}" \
 && chmod 0755 /usr/local/bin/kubectl /usr/local/bin/kind /usr/local/bin/minikube \
 && curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash \
 && kustomize_tag="$(curl -fsSL https://api.github.com/repos/kubernetes-sigs/kustomize/releases | jq -r '[.[].tag_name | select(startswith("kustomize/"))] | first')" \
 && kustomize_version="${kustomize_tag#kustomize/v}" \
 && curl -fsSL "https://github.com/kubernetes-sigs/kustomize/releases/download/${kustomize_tag}/kustomize_v${kustomize_version}_linux_${arch}.tar.gz" \
        | tar -xz -C /usr/local/bin kustomize \
 && chmod 0755 /usr/local/bin/kustomize

# Terraform, Packer, Pulumi, and the smaller CLIs of the toolset.
RUN arch="$(dpkg --print-architecture)" \
 && curl -fsSL https://apt.releases.hashicorp.com/gpg -o /etc/apt/keyrings/hashicorp.asc \
 && chmod a+r /etc/apt/keyrings/hashicorp.asc \
 && echo "deb [arch=${arch} signed-by=/etc/apt/keyrings/hashicorp.asc] https://apt.releases.hashicorp.com $(. /etc/os-release && echo "${UBUNTU_CODENAME}") main" \
        > /etc/apt/sources.list.d/hashicorp.list \
 && apt-get update \
 && apt-get install -y --no-install-recommends terraform packer \
 && rm -rf /var/lib/apt/lists/* \
 && curl -fsSL https://get.pulumi.com | HOME=/usr/local sh -s -- --install-root /usr/local \
 && curl -fsSL -o /usr/local/bin/yq \
        "https://github.com/mikefarah/yq/releases/latest/download/yq_linux_${arch}" \
 && chmod 0755 /usr/local/bin/yq \
 && curl -fsSL "https://github.com/oras-project/oras/releases/latest/download/oras_$(curl -fsSL https://api.github.com/repos/oras-project/oras/releases/latest | jq -r .tag_name | tr -d v)_linux_${arch}.tar.gz" \
        | tar -xz -C /usr/local/bin oras \
 && chmod 0755 /usr/local/bin/oras

# The browsers and their drivers, with the paths GitHub exports for them.
#
# amd64 only. Google publishes no arm64 Chrome for Linux and Microsoft no arm64
# Edge, so an arm64 machine gets Firefox and no more. A workflow that drives
# Chrome is an amd64 workflow, on GitHub as well as here.
ENV CHROMEWEBDRIVER=/usr/local/share/chromedriver-linux64 \
    EDGEWEBDRIVER=/usr/local/share/edge_driver \
    GECKOWEBDRIVER=/usr/local/share/gecko_driver \
    SELENIUM_JAR_PATH=/usr/share/java/selenium-server.jar

RUN install -m 0755 -d /etc/apt/keyrings \
 && curl -fsSL https://packages.mozilla.org/apt/repo-signing-key.gpg \
        -o /etc/apt/keyrings/packages.mozilla.org.asc \
 && chmod a+r /etc/apt/keyrings/packages.mozilla.org.asc \
 && echo "deb [signed-by=/etc/apt/keyrings/packages.mozilla.org.asc] https://packages.mozilla.org/apt mozilla main" \
        > /etc/apt/sources.list.d/mozilla.list \
 && printf '%s\n' \
        'Package: *' \
        'Pin: origin packages.mozilla.org' \
        'Pin-Priority: 1000' \
        > /etc/apt/preferences.d/mozilla \
 && apt-get update \
 && apt-get install -y --no-install-recommends firefox \
 && rm -rf /var/lib/apt/lists/* \
 && mkdir -p "${GECKOWEBDRIVER}" \
 && gecko="$(curl -fsSL https://api.github.com/repos/mozilla/geckodriver/releases/latest | jq -r .tag_name)" \
 && case "${TARGETARCH}" in amd64) gk_arch=linux64 ;; arm64) gk_arch=linux-aarch64 ;; esac \
 && curl -fsSL "https://github.com/mozilla/geckodriver/releases/download/${gecko}/geckodriver-${gecko}-${gk_arch}.tar.gz" \
        | tar -xz -C "${GECKOWEBDRIVER}" \
 && ln -sf "${GECKOWEBDRIVER}/geckodriver" /usr/local/bin/geckodriver \
 && mkdir -p /usr/share/java \
 && curl -fsSL -o "${SELENIUM_JAR_PATH}" \
        "https://github.com/SeleniumHQ/selenium/releases/download/selenium-4.47.0/selenium-server-4.47.0.jar"

RUN if [ "${TARGETARCH}" = "amd64" ]; then \
        curl -fsSL -o /tmp/chrome.deb https://dl.google.com/linux/direct/google-chrome-stable_current_amd64.deb \
     && apt-get update \
     && apt-get install -y --no-install-recommends /tmp/chrome.deb \
     && rm /tmp/chrome.deb \
     && chrome_version="$(google-chrome --product-version)" \
     && mkdir -p /usr/local/share \
     && curl -fsSL -o /tmp/chromedriver.zip \
            "https://storage.googleapis.com/chrome-for-testing-public/${chrome_version}/linux64/chromedriver-linux64.zip" \
     && unzip -q /tmp/chromedriver.zip -d /usr/local/share \
     && rm /tmp/chromedriver.zip \
     && ln -sf "${CHROMEWEBDRIVER}/chromedriver" /usr/local/bin/chromedriver \
     && curl -fsSL https://packages.microsoft.com/keys/microsoft.asc \
            | gpg --dearmor -o /etc/apt/keyrings/microsoft-edge.gpg \
     && echo "deb [arch=amd64 signed-by=/etc/apt/keyrings/microsoft-edge.gpg] https://packages.microsoft.com/repos/edge stable main" \
            > /etc/apt/sources.list.d/microsoft-edge.list \
     && apt-get update \
     && apt-get install -y --no-install-recommends microsoft-edge-stable \
     && edge_version="$(microsoft-edge --version | awk '{print $3}')" \
     && mkdir -p "${EDGEWEBDRIVER}" \
     && curl -fsSL -o /tmp/edgedriver.zip \
            "https://msedgedriver.microsoft.com/${edge_version}/edgedriver_linux64.zip" \
     && unzip -q /tmp/edgedriver.zip -d "${EDGEWEBDRIVER}" \
     && rm /tmp/edgedriver.zip \
     && ln -sf "${EDGEWEBDRIVER}/msedgedriver" /usr/local/bin/msedgedriver \
     && rm -rf /var/lib/apt/lists/* ; \
    else \
        echo "arm64: no Chrome and no Edge published for linux; Firefox only" ; \
    fi

# The databases and web servers, installed and left stopped.
#
# GitHub's image has these present and their units inactive, and a job starts
# whichever it wants. Masked is wrong here: a masked unit cannot be started at
# all, which is the opposite of what a workflow expects.
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
        postgresql-18 postgresql-client-18 \
        mysql-server mysql-client \
        nginx apache2 \
 && rm -rf /var/lib/apt/lists/* \
 && systemctl disable postgresql mysql nginx apache2

# What every job's shell has to see.
#
# `setup-*` actions read AGENT_TOOLSDIRECTORY to find the cache, and a job runs
# as `runner`, so the PATH additions above have to be on that user's PATH too.
ENV AGENT_TOOLSDIRECTORY=/opt/hostedtoolcache \
    ImageOS=ubuntu26 \
    RUNNER_TOOL_CACHE=/opt/hostedtoolcache

RUN printf '%s\n' \
        'export PATH="/usr/share/rust/.cargo/bin:/usr/local/go/bin:$PATH"' \
        > /etc/profile.d/makecore-toolchains.sh \
 && chmod 0644 /etc/profile.d/makecore-toolchains.sh

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
