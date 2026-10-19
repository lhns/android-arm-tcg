# Build/run container for android-arm-tcg.
# Mount the repo at /work and run the numbered scripts from there.
#
#   docker build -t android-arm-tcg docker/
#   docker run --rm -it -v "$PWD:/work" -w /work android-arm-tcg \
#     sh -c 'scripts/00-setup.sh && scripts/10-patch-image.sh && \
#            scripts/20-build-ramdisk.sh && scripts/30-launch.sh && scripts/40-bringup.sh'
FROM eclipse-temurin:21-jdk

ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update -qq && apt-get install -y -qq \
      # download + image tooling
      curl unzip e2fsprogs qemu-utils file xxd cpio perl python3 \
      # aarch64 cross-compiler for initwrap.c and tcg-probe.c
      gcc-aarch64-linux-gnu binutils-aarch64-linux-gnu \
      # the "headless" emulator still links libX11 and dlopens a host GL/EGL
      # (libgfxstream bootstraps its dispatch via libGL/libEGL/libGLESv2), so a
      # software GL stack (Mesa/llvmpipe) is required even with -gpu off
      libx11-6 libxext6 libxfixes3 libxdamage1 libxshmfence1 \
      libgl1-mesa-dri libglx-mesa0 libegl-mesa0 libegl1 libgles2 libgbm1 libdrm2 \
      libglvnd0 libopengl0 \
    && rm -rf /var/lib/apt/lists/*

# The scripts download the SDK into ./sdk under the working directory by default;
# override with SDK_ROOT (e.g. a mounted volume) to cache it across runs.
ENV SDK_ROOT=/work/sdk
WORKDIR /work
