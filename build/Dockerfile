# syntax=docker/dockerfile:1
# docker build . -t rootrmc/docker-android:emulator_14
FROM debian:trixie-slim

ENV DEBIAN_FRONTEND=noninteractive

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

# ============================
# Basic envs
# ============================
ENV ANDROID_SDK_ROOT=/opt/android \
    ANDROID_HOME=/opt/android \
    EMULATOR_NAME=nexus \
    EMULATOR_DEVICE="Nexus 6" \
    ANDROID_API_LEVEL=34 \
    ANDROID_BUILD_TOOLS=34.0.0 \
    EMULATOR_PORT=5558 \
    FRIDA_VERSION=17.2.16 \
    FRIDA_ARCH=android-x86_64 \
    FRIDA_PORT=27042 \
    FRIDA_SERVER_PATH=/opt/frida/frida-server \
    MAGISK_DIR=/opt/magisk \
    MAGISK_GIT=https://github.com/topjohnwu/Magisk \
    MAGISK_REF=v30.6 \
    QBDI_TAG=v0.12.0 \
    QBDI_DIR=/opt/qbdi \
    ANDROID_CMD=commandlinetools-linux-11076708_latest.zip

ENV PATH="$PATH:$ANDROID_SDK_ROOT/cmdline-tools/latest/bin:$ANDROID_SDK_ROOT/emulator:$ANDROID_SDK_ROOT/platform-tools"

# ============================
# Basic Packages
# ============================
RUN set -eux; \
    apt-get -qqy update; \
    apt-get -qqy install --no-install-recommends \
      ca-certificates wget unzip curl xz-utils zip \
      bash git \
      socat supervisor \
      python3 python3-pip python3-venv \
      procps file \
      build-essential clang lld cmake ninja-build pkg-config \
      libpulse0 libnss3 libnspr4 libnss3-tools \
      libx11-6 libxext6 libxrender1 libxrandr2 libxfixes3 \
      libxi6 libxcursor1 libxinerama1 libfontconfig1 \
      libglu1-mesa libxcomposite1 libxdamage1 libxkbcommon0 \
      libdbus-1-3 libdrm2 libgbm1 libasound2 libxss1 libxtst6 \
      e2fsprogs; \
    \
    # Java (your logs showed openjdk-17-jdk missing on Debian 13/trixie in your setup)
    # Try 17 first, then fall back to 21, then default-jdk.
    (apt-get -qqy install --no-install-recommends openjdk-17-jdk-headless || \
     apt-get -qqy install --no-install-recommends openjdk-21-jdk-headless || \
     apt-get -qqy install --no-install-recommends default-jdk-headless); \
    \
    apt-get clean; \
    rm -rf /var/lib/apt/lists/*; \
    update-alternatives --install /usr/bin/pip pip /usr/bin/pip3 1

# (Debug bits you pasted)
RUN set -eux; \
    cat /etc/os-release; \
    apt-cache policy openjdk-17-jdk || true; \
    apt-cache search openjdk-17 | head || true

# ============================
# Python tooling (PEP 668 -> use venv)
# ============================
RUN set -eux; \
    python3 -m venv /opt/venv; \
    /opt/venv/bin/pip install --no-cache-dir --upgrade pip setuptools wheel; \
    /opt/venv/bin/pip install --no-cache-dir "frida==${FRIDA_VERSION}" frida-tools
ENV PATH="/opt/venv/bin:${PATH}"

# ============================
# Android SDK / Emulator
# ============================
RUN set -eux; \
    mkdir -p "${ANDROID_SDK_ROOT}/cmdline-tools/latest"; \
    wget -q "https://dl.google.com/android/repository/${ANDROID_CMD}" -O /tmp/cmdline.zip; \
    unzip -q /tmp/cmdline.zip -d /tmp/cmdline; \
    mv /tmp/cmdline/cmdline-tools/* "${ANDROID_SDK_ROOT}/cmdline-tools/latest/"; \
    rm -rf /tmp/cmdline /tmp/cmdline.zip; \
    \
    set +o pipefail; \
    yes | sdkmanager --sdk_root="${ANDROID_SDK_ROOT}" --licenses; \
    lic_rc=${PIPESTATUS[1]}; \
    set -o pipefail; \
    test "$lic_rc" -eq 0; \
    \
    set +o pipefail; \
    yes | sdkmanager --sdk_root="${ANDROID_SDK_ROOT}" \
      "platform-tools" \
      "emulator" \
      "platforms;android-${ANDROID_API_LEVEL}" \
      "build-tools;${ANDROID_BUILD_TOOLS}" \
      "system-images;android-${ANDROID_API_LEVEL};google_apis;x86_64"; \
    inst_rc=${PIPESTATUS[1]}; \
    set -o pipefail; \
    test "$inst_rc" -eq 0; \
    \
    echo "no" | avdmanager --verbose create avd \
      --name "${EMULATOR_NAME}" \
      --device "${EMULATOR_DEVICE}" \
      --package "system-images;android-${ANDROID_API_LEVEL};google_apis;x86_64"

# ============================
# Frida server (android-x86_64)
# ============================
RUN set -eux; \
    mkdir -p /opt/frida; \
    wget -q "https://github.com/frida/frida/releases/download/${FRIDA_VERSION}/frida-server-${FRIDA_VERSION}-${FRIDA_ARCH}.xz" \
      -O "/opt/frida/frida-server-${FRIDA_VERSION}-${FRIDA_ARCH}.xz"; \
    unxz "/opt/frida/frida-server-${FRIDA_VERSION}-${FRIDA_ARCH}.xz"; \
    mv "/opt/frida/frida-server-${FRIDA_VERSION}-${FRIDA_ARCH}" "${FRIDA_SERVER_PATH}"; \
    chmod +x "${FRIDA_SERVER_PATH}"

# ============================
# QBDI fetch (expects fetch_qbdi.py in build context)
# ============================
COPY ./scripts/fetch_qbdi.py /opt/fetch_qbdi.py
RUN set -eux; \
    python3 /opt/fetch_qbdi.py "${QBDI_TAG}" "${QBDI_DIR}"

# ============================
# Magisk sources
# ============================
RUN set -eux; \
    git clone --depth 1 --branch "${MAGISK_REF}" "${MAGISK_GIT}" "${MAGISK_DIR}"; \
    sed -i \
      's/env\["PATH"\] = f"{rust_sysroot \/ "bin"}{os.pathsep}{env\["PATH"\]}"/env["PATH"] = f"{rust_sysroot \/ '\''bin'\''}{os.pathsep}{env['\''PATH'\'']}"/' \
      /opt/magisk/build.py


# ============================
# Scripts
# ============================
COPY ./scripts/entrypoint.sh /entrypoint.sh
COPY ./scripts/run-emulator.sh /usr/local/bin/run-emulator.sh
COPY ./scripts/supervisord.conf /etc/supervisor/supervisord.conf
COPY ./scripts/adb-frida-forward.sh /usr/local/bin/adb-frida-forward.sh
COPY ./scripts/installapps.sh /usr/local/bin/installapps.sh
RUN chmod +x /entrypoint.sh /usr/local/bin/run-emulator.sh /usr/local/bin/installapps.sh /usr/local/bin/adb-frida-forward.sh

# ============================
# Ports
# 5554/5555 expose via socat (emulator bind 127.0.0.1)
# ============================
EXPOSE 5554 5555 37043

CMD ["/entrypoint.sh"]
