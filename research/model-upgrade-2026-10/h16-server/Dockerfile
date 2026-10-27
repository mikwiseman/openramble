# The Linux server's toolchain, as CI's linux-server job has it, on arm64 like
# wai-stt (Hetzner CAX21).
FROM rust:1.97.1-bookworm
RUN apt-get update \
 && apt-get install -y --no-install-recommends bc cmake ffmpeg curl python3 \
 && rm -rf /var/lib/apt/lists/*
COPY measure.sh sample.py /
