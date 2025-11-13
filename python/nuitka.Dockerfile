# syntax=docker/dockerfile:1
# This Containerfile is crafted to handle SELinux
# If you're not in this situation, simply remove both `,Z` and `,z`
# https://docs.docker.com/engine/storage/bind-mounts/#configure-the-selinux-label
# https://docs.docker.com/reference/cli/dockerd/#:~:text=Enable%20selinux%20support
ARG UID=1001
ARG VERSION=EDGE
ARG RELEASE=0

########################################
# Build stage
########################################
FROM docker.io/library/python:3.11-slim-bookworm AS build

# RUN mount cache for multi-arch: https://github.com/docker/buildx/issues/549#issuecomment-1788297892
ARG TARGETARCH
ARG TARGETVARIANT

WORKDIR /app

# Install uv
COPY --from=ghcr.io/astral-sh/uv:latest /uv /uvx /bin/

ENV UV_PROJECT_ENVIRONMENT=/venv
ENV VIRTUAL_ENV=/venv
ENV UV_LINK_MODE=copy
ENV UV_PYTHON_DOWNLOADS=0

# Install build dependencies
RUN --mount=type=cache,id=apt-$TARGETARCH$TARGETVARIANT,sharing=locked,target=/var/cache/apt \
    --mount=type=cache,id=aptlists-$TARGETARCH$TARGETVARIANT,sharing=locked,target=/var/lib/apt/lists \
    apt-get update && apt-get upgrade -y && \
    apt-get install -y --no-install-recommends \
    # https://pillow.readthedocs.io/en/stable/installation/building-from-source.html
    libjpeg62-turbo-dev libwebp-dev zlib1g-dev \
    build-essential git curl

# Install dependencies using uv sync
RUN --mount=type=cache,id=uv-$TARGETARCH$TARGETVARIANT,sharing=locked,target=/root/.cache/uv \
    --mount=type=bind,source=pyproject.toml,target=pyproject.toml \
    --mount=type=bind,source=uv.lock,target=uv.lock \
    uv sync --frozen --no-dev --no-install-project --no-editable

# Replace pillow with pillow-simd (Only for x86)
ARG TARGETPLATFORM
RUN --mount=type=cache,id=uv-$TARGETARCH$TARGETVARIANT,sharing=locked,target=/root/.cache/uv \
    if [ "$TARGETPLATFORM" = "linux/amd64" ]; then \
    uv pip uninstall pillow && \
    CC="cc -mavx2" uv pip install pillow-simd; \
    fi

########################################
# Compile with Nuitka
########################################
FROM build AS compile

ARG TARGETARCH
ARG TARGETVARIANT

# https://nuitka.net/user-documentation/tips.html#control-where-caches-live
ENV NUITKA_CACHE_DIR_CCACHE=/cache
ENV NUITKA_CACHE_DIR_DOWNLOADS=/cache
ENV NUITKA_CACHE_DIR_CLCACHE=/cache
ENV NUITKA_CACHE_DIR_BYTECODE=/cache
ENV NUITKA_CACHE_DIR_DLL_DEPENDENCIES=/cache

# Install build dependencies for Nuitka
RUN --mount=type=cache,id=apt-$TARGETARCH$TARGETVARIANT,sharing=locked,target=/var/cache/apt \
    --mount=type=cache,id=aptlists-$TARGETARCH$TARGETVARIANT,sharing=locked,target=/var/lib/apt/lists \
    echo 'deb http://deb.debian.org/debian bookworm-backports main' > /etc/apt/sources.list.d/backports.list && \
    apt-get update && apt-get install -y --no-install-recommends \
    build-essential \
    patchelf ccache clang upx-ucl

# Install Nuitka
RUN --mount=type=cache,id=uv-$TARGETARCH$TARGETVARIANT,sharing=locked,target=/root/.cache/uv \
    uv pip install nuitka

# Prevent cache reused
ARG RELEASE

# Compile with nuitka
RUN --mount=type=cache,id=nuitka-$TARGETARCH$TARGETVARIANT,target=/cache \
    --mount=source=.,target=.,rw,Z \
    /venv/bin/python3 -m nuitka \
    --python-flag=nosite,-O \
    --clang \
    --lto=no \
    --include-package-data=gradio \
    --include-package-data=gradio_client \
    --output-dir=/ \
    --report=/compilationreport.xml \
    --standalone \
    --deployment \
    --remove-output \
    main.py

########################################
# Report stage
########################################
FROM scratch AS report

ARG UID
COPY --chown=$UID:0 --chmod=775 --from=compile /compilationreport.xml /

########################################
# Final stage
########################################
FROM docker.io/library/debian:bookworm-slim AS final

# RUN mount cache for multi-arch: https://github.com/docker/buildx/issues/549#issuecomment-1788297892
ARG TARGETARCH
ARG TARGETVARIANT

# Install runtime dependencies
RUN --mount=type=cache,id=apt-$TARGETARCH$TARGETVARIANT,sharing=locked,target=/var/cache/apt \
    --mount=type=cache,id=aptlists-$TARGETARCH$TARGETVARIANT,sharing=locked,target=/var/lib/apt/lists \
    apt-get update && apt-get upgrade -y && \
    apt-get install -y --no-install-recommends \
    # https://pillow.readthedocs.io/en/stable/installation/building-from-source.html
    libjpeg62-turbo-dev libwebp-dev zlib1g-dev \
    libxcb1 dumb-init

# Create directories with correct permissions
ARG UID
RUN install -d -m 775 -o $UID -g 0 /data && \
    install -d -m 775 -o $UID -g 0 /licenses && \
    install -d -m 775 -o $UID -g 0 /app

# Copy licenses (OpenShift Policy)
# COPY --chown=$UID:0 --chmod=775 LICENSE /licenses/Dockerfile.LICENSE

# Copy dependencies and code (and support arbitrary uid for OpenShift best practice)
COPY --chown=$UID:0 --chmod=775 --from=compile /main.dist /app

ENV PATH="/app${PATH:+:${PATH}}"
ENV LANG=en_US.UTF-8
ENV LC_ALL=en_US.UTF-8
ENV PYTHONIOENCODING=utf-8

# Remove these to prevent the container from executing arbitrary commands
RUN rm /bin/echo /bin/ln /bin/rm /bin/sh /bin/bash /usr/bin/apt-get

WORKDIR /app

VOLUME [ "/app/data", "/app/data_sc" ]

EXPOSE 8080

USER $UID

STOPSIGNAL SIGINT

# Use dumb-init as PID 1 to handle signals properly
ENTRYPOINT ["dumb-init", "--", "/app/main.bin", "--host", "0.0.0.0", "--port", "8080"]

ARG VERSION
ARG RELEASE
LABEL name="jim60105/standalone-civitai-shortcut" \
    # Authors for civitai-shortcut
    vendor="sunnyark,jim60105" \
    # Maintainer for this docker image
    maintainer="jim60105" \
    # Dockerfile source repository
    url="https://github.com/jim60105/standalone-civitai-shortcut" \
    version=${VERSION} \
    # This should be a number, incremented with each change
    release=${RELEASE} \
    io.k8s.display-name="standalone-civitai-shortcut" \
    summary="Stable Diffusion Webui Extension for Civitai, to download civitai shortcut and models." \
    description="You can save the model URL of the Civitai site for future reference and storage. This allows you to download the model when needed and check if the model has been updated to the latest version. The downloaded models are saved to the designated storage location. For more information about this tool, please visit the following website: https://github.com/jim60105/standalone-civitai-shortcut"
