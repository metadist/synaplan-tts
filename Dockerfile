FROM python:3.11-slim-bookworm

LABEL maintainer="Synaplan"
LABEL description="Synaplan TTS - Piper-based multi-language text-to-speech HTTP API"

# Install minimal system dependencies
RUN apt-get update && \
    apt-get install -y --no-install-recommends curl && \
    rm -rf /var/lib/apt/lists/*

# Install Python dependencies
COPY requirements.txt /app/requirements.txt
RUN pip install --no-cache-dir -r /app/requirements.txt

# Copy application code
COPY server.py /app/server.py

WORKDIR /app

# Voices are mounted at runtime
VOLUME /voices

EXPOSE 10200

HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
    CMD curl -f http://localhost:10200/health || exit 1

CMD ["uvicorn", "server:app", "--host", "0.0.0.0", "--port", "10200", "--log-level", "info"]
