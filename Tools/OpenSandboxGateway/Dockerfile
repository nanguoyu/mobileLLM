FROM mcr.microsoft.com/playwright/python:v1.64.1-noble@sha256:330d401ae23c905896a0c26c66c36fc971b621519e7b11b435a8328d7bf6e031
LABEL org.mobilellm.role="opensandbox-tools" org.mobilellm.image-version="1.0.0"
USER root
RUN apt-get update && apt-get install -y --no-install-recommends nodejs npm git \
    && rm -rf /var/lib/apt/lists/* \
    && python3 -m pip install --no-cache-dir playwright==1.64.1 \
    && mkdir -p /workspace/project /workspace/data /opt/mobilellm \
    && chown -R 1000:1000 /workspace
COPY guest.py /opt/mobilellm/guest.py
RUN chmod 0555 /opt/mobilellm/guest.py
ENV MOBILELLM_DATA_DIR=/workspace/data
WORKDIR /workspace/project
