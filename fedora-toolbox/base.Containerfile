# syntax=docker/dockerfile:1
ARG UID=1000
ARG VERSION=EDGE
ARG RELEASE=0
ARG BASE_IMAGE=registry.fedoraproject.org/fedora-toolbox:42

########################################
# Base stage
########################################
FROM ${BASE_IMAGE} AS base

# Set dnf config
RUN cat <<-"EOF" > /etc/dnf/dnf.conf
[main]
install_weak_deps=False
tsflags=nodocs
EOF

########################################
# Font unpack stage
########################################
FROM base AS font-unpacker

WORKDIR /fonts

ADD https://github.com/ButTaiwan/iansui/releases/download/v1.000/iansui.zip /tmp/iansui.zip

ADD https://github.com/ryanoasis/nerd-fonts/releases/download/v3.3.0/Hack.zip /tmp/hack.zip

RUN unzip -uo /tmp/iansui.zip -d /fonts/iansui && \
    unzip -uo /tmp/hack.zip -d /fonts/hack

########################################
# Host runner stage
########################################
FROM base AS host-runner

COPY --chown=$UID:0 --chmod=775 base/host-runner /host-runner

WORKDIR /host-runner

# Setup host-runner script and symlinks
RUN bins=( \
    "flatpak" \
    # "podman" \
    "buildah" \
    "skopeo" \
    "docker" \
    "rpm-ostree" \
    "systemctl" \
    "xdg-open" \
    "kitty" \
    "waveterm" \
    "chrome" \
    "firefox" \
    "brave" \
    ); \
    for f in "${bins[@]}"; do \
    ln -s host-runner "/host-runner/$f";\
    done

########################################
# Final stage
########################################
FROM base AS final

# Create directories with correct permissions
ARG UID
RUN install -d -m 775 -o $UID -g 0 /licenses

# Copy licenses (OpenShift Policy)
COPY --chown=$UID:0 --chmod=775 LICENSE /licenses/Containerfile.LICENSE

# COPY host-runner
COPY --chown=$UID:0 --chmod=775 --from=host-runner /host-runner /usr/local/bin

# RUN mount cache for multi-arch: https://github.com/docker/buildx/issues/549#issuecomment-1788297892
ARG TARGETARCH
ARG TARGETVARIANT

# Make sure the cache is refreshed
ARG RELEASE

# Install utilities
RUN --mount=type=cache,id=dnf-$TARGETARCH$TARGETVARIANT,sharing=locked,target=/var/cache/dnf \
    dnf -y upgrade && \
    dnf -y install \
    xdg-utils \
    jq \
    zsh \
    vim

# Install gh-cli
RUN --mount=type=cache,id=dnf-$TARGETARCH$TARGETVARIANT,sharing=locked,target=/var/cache/dnf \
    dnf config-manager addrepo --from-repofile=https://cli.github.com/packages/rpm/gh-cli.repo && \
    dnf -y install gh --repo gh-cli

# Fonts
COPY --chown=$UID:0 --chmod=775 --from=font-unpacker /fonts /usr/local/share/fonts
RUN --mount=type=cache,id=dnf-$TARGETARCH$TARGETVARIANT,sharing=locked,target=/var/cache/dnf \
    dnf -y install \
    google-noto-sans-cjk-fonts \
    google-noto-color-emoji-fonts \
    cascadia-fonts-all \
    hanamin-fonts

# Install os keyring
ENV GCM_CREDENTIAL_STORE=gpg
RUN --mount=type=cache,id=dnf-$TARGETARCH$TARGETVARIANT,sharing=locked,target=/var/cache/dnf \
    dnf -y install seahorse

# Install development tools
RUN --mount=type=cache,id=dnf-$TARGETARCH$TARGETVARIANT,sharing=locked,target=/var/cache/dnf \
    dnf -y install @development-tools @c-development openssl-devel cmake ninja-build pkg-config

# Install .NET
RUN --mount=type=cache,id=dnf-$TARGETARCH$TARGETVARIANT,sharing=locked,target=/var/cache/dnf \
    dnf -y install dotnet-sdk-8.0 dotnet-sdk-9.0

# Install Java 21
RUN --mount=type=cache,id=dnf-$TARGETARCH$TARGETVARIANT,sharing=locked,target=/var/cache/dnf \
    dnf -y install java-21-openjdk

# Install nodejs
RUN --mount=type=cache,id=dnf-$TARGETARCH$TARGETVARIANT,sharing=locked,target=/var/cache/dnf \
    dnf -y install nodejs nodejs-npm yarnpkg

# Install git-credential-manager (This needs .NET 8)
RUN curl -L https://aka.ms/gcm/linux-install-source.sh | sh && \
    git-credential-manager configure

# Install aria2
RUN --mount=type=cache,id=dnf-$TARGETARCH$TARGETVARIANT,sharing=locked,target=/var/cache/dnf \
    dnf -y install aria2

# Copy toolbox runners
COPY --chown=$UID:0 --chmod=775 base/runner /copy-to-host

# Input method for JetBrains IDE
ENV XMODIFIERS=@im=fcitx

ARG VERSION
ARG RELEASE
LABEL name="jim60105/toolbx" \
    org.opencontainers.image.name="jim60105/toolbx" \
    # Authors for toolbox
    vendor="Fedora Project" \
    # Maintainer for this container image
    maintainer="jim60105" \
    # Containerfile source repository
    url="https://github.com/jim60105/toolbx" \
    version=${VERSION} \
    # This should be a number, incremented with each change
    release=${RELEASE} \
    io.k8s.display-name="toolbx" \
    summary="toolbx: My Personal Fedora Toolbox (Containerfile)" \
    description="Toolbx is a tool for Linux, which allows the use of interactive command line environments for software development and troubleshooting the host operating system, without having to install software on the host. These are my personal Fedora toolbox images, which I use for development and daily usage. For more information about this tool, please visit the following website: https://github.com/jim60105/toolbx" \
    license="GPL-3.0" \
    org.opencontainers.image.license="GPL-3.0"
