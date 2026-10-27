FROM mcr.microsoft.com/playwright/python:v1.64.1-noble@sha256:330d401ae23c905896a0c26c66c36fc971b621519e7b11b435a8328d7bf6e031
LABEL org.mobilellm.role="opensandbox-tools" org.mobilellm.image-version="1.0.0"
USER root
ARG TARGETARCH
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates curl xz-utils git \
    && rm -rf /var/lib/apt/lists/* \
    && case "$TARGETARCH" in \
         arm64) node_arch=arm64; node_sha=dbabf7a1cbf947e6059ffad2c27b80041db97dea1e553b62afdee7f13fca336e ;; \
         amd64) node_arch=x64; node_sha=6c172a9ab6718f7b801fb5a7bd486af2ee5e32758086a04b84fcce2aa77095e6 ;; \
         *) exit 1 ;; esac \
    && curl -fsS "https://nodejs.org/dist/v24.22.1/node-v24.22.1-linux-$node_arch.tar.xz" -o /tmp/node.tar.xz \
    && printf '%s  /tmp/node.tar.xz\n' "$node_sha" | sha256sum -c - \
    && tar -xJf /tmp/node.tar.xz -C /usr/local --strip-components=1 \
    && rm /tmp/node.tar.xz \
    && python3 -m pip install --no-cache-dir playwright==1.64.1 \
    && mkdir -p /workspace/project /workspace/data /opt/mobilellm \
    && chown -R 1000:1000 /workspace
COPY guest.py /opt/mobilellm/guest.py
RUN chmod 0555 /opt/mobilellm/guest.py
ENV MOBILELLM_DATA_DIR=/workspace/data
ENV NPM_CONFIG_CACHE=/workspace/data/npm-cache NPM_CONFIG_AUDIT=false NPM_CONFIG_FUND=false
WORKDIR /workspace/project
