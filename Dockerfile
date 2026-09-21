# Synaplan TTS — multi-arch image (linux/amd64 + linux/arm64).
#
# Both stages build from multi-arch base images (alpine, python:slim) and the
# Python dependencies (piper-tts, onnxruntime, fastapi, uvicorn) all ship
# linux/aarch64 wheels, so this Dockerfile needs no arch-specific branches.
# CI builds each platform natively (amd64 + ARM runners, no QEMU) and merges
# them into one manifest list — Docker then pulls the matching arch
# automatically, so Apple Silicon Macs run the ARM image with no extra config.
# Keep both FROM images multi-arch; never pin a per-arch digest here.
#
# ── Stage 1: bake the five product voices into the image ──────────────
# English, German, Spanish, French, Turkish. Extra languages are mounted
# at runtime via EXTRA_VOICES_DIR (see README).
FROM alpine:3.24 AS voices

RUN apk add --no-cache curl ca-certificates

WORKDIR /voices

# HuggingFace piper-voices. Fail the build if any required file is missing
# so we never publish an image that starts with "No voices loaded".
ARG HF_BASE=https://huggingface.co/rhasspy/piper-voices/resolve/main
RUN set -eu; \
    download() { \
      voice="$1"; path="$2"; \
      echo "↓ $voice"; \
      curl -fL --retry 5 --retry-delay 5 --max-time 600 \
        -o "${voice}.onnx" "${HF_BASE}/${path}/${voice}.onnx"; \
      curl -fL --retry 5 --retry-delay 5 --max-time 120 \
        -o "${voice}.onnx.json" "${HF_BASE}/${path}/${voice}.onnx.json"; \
    }; \
    download en_US-lessac-medium   en/en_US/lessac/medium; \
    download de_DE-kerstin-low     de/de_DE/kerstin/low; \
    download es_ES-davefx-medium   es/es_ES/davefx/medium; \
    download fr_FR-siwis-medium    fr/fr_FR/siwis/medium; \
    download tr_TR-dfki-medium     tr/tr_TR/dfki/medium; \
    for v in en_US-lessac-medium de_DE-kerstin-low es_ES-davefx-medium fr_FR-siwis-medium tr_TR-dfki-medium; do \
      test -s "${v}.onnx" && test -s "${v}.onnx.json"; \
    done; \
    echo "Baked voices:"; ls -lh *.onnx

# ── Stage 2: TTS HTTP API ─────────────────────────────────────────────
FROM python:3.14-slim-bookworm

LABEL maintainer="Synaplan"
LABEL description="Synaplan TTS — Piper-based multi-language text-to-speech HTTP API (5 baked voices: en, de, es, fr, tr)"
LABEL org.opencontainers.image.source="https://github.com/metadist/synaplan-tts"

RUN apt-get update && \
    apt-get install -y --no-install-recommends curl ffmpeg && \
    rm -rf /var/lib/apt/lists/*

COPY requirements.txt /app/requirements.txt
RUN pip install --no-cache-dir -r /app/requirements.txt

COPY server.py /app/server.py
COPY --from=voices /voices /voices

WORKDIR /app

# Extra voices (optional host mount) live beside the baked set
VOLUME /voices-extra

EXPOSE 10200

HEALTHCHECK --interval=30s --timeout=5s --start-period=15s --retries=3 \
    CMD curl -f http://localhost:10200/health || exit 1

CMD ["uvicorn", "server:app", "--host", "0.0.0.0", "--port", "10200", "--log-level", "info"]
