# Synaplan TTS

> Part of the [Synaplan](https://web.synaplan.com) AI knowledge management platform.

Self-hosted multi-language text-to-speech service powered by [Piper](https://github.com/rhasspy/piper). Provides an HTTP REST API for the [Synaplan platform](https://web.synaplan.com) to generate speech audio.

**Supported languages:** English, German, Spanish, Turkish, Russian, Persian

## Quick Start

```bash
docker compose up -d
```

First run downloads voice models (~350 MB total). Subsequent starts skip the download.

Verify the service is running:

```bash
curl http://127.0.0.1:10200/health
```

Test speech synthesis:

```bash
# English
curl "http://127.0.0.1:10200/api/tts?text=Hello+world&language=en" -o test_en.wav

# German
curl "http://127.0.0.1:10200/api/tts?text=Hallo+Welt&language=de" -o test_de.wav

# Spanish
curl "http://127.0.0.1:10200/api/tts?text=Hola+mundo&language=es" -o test_es.wav

# Turkish
curl "http://127.0.0.1:10200/api/tts?text=Merhaba+dünya&language=tr" -o test_tr.wav

# Russian
curl "http://127.0.0.1:10200/api/tts?text=Привет+мир&language=ru" -o test_ru.wav

# Persian
curl "http://127.0.0.1:10200/api/tts?text=سلام+دنیا&language=fa" -o test_fa.wav
```

## API Reference

### `GET /health`

Health check — returns loaded voice count and available voices.

```json
{
  "status": "ok",
  "voices_loaded": 6,
  "available_voices": ["en_US-lessac-medium", "de_DE-thorsten-medium", ...],
  "default_voice": "en_US-lessac-medium"
}
```

### `GET /api/voices`

List all loaded voices with language metadata.

```json
[
  {
    "key": "en_US-lessac-medium",
    "locale": "en_US",
    "language": "en",
    "language_name": "English (US)",
    "speaker": "lessac",
    "quality": "medium",
    "sample_rate": 22050
  }
]
```

### `POST /api/tts`

Synthesize speech. Returns `audio/wav`.

**Request body:**
```json
{
  "text": "Hello, this is a test.",
  "voice": "en_US-lessac-medium",
  "language": "en",
  "length_scale": 1.0,
  "volume": 1.0
}
```

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `text` | string | ✅ | Text to synthesize (max 5000 chars) |
| `voice` | string | – | Exact voice key (overrides language) |
| `language` | string | – | Language shortcode: `en`, `de`, `es`, `tr`, `ru`, `fa` |
| `length_scale` | float | – | Speed factor — <1.0 faster, >1.0 slower |
| `volume` | float | – | Output volume multiplier (default 1.0) |
| `speaker_id` | int | – | Speaker index for multi-speaker models |
| `noise_scale` | float | – | Phoneme noise (affects expressiveness) |
| `noise_w_scale` | float | – | Phoneme width noise |

**Resolution order:** `voice` → `language` → default voice → first available.

### `GET /api/tts`

Same as POST but with query parameters. Convenient for browser testing:

```
http://localhost:10200/api/tts?text=Guten+Tag&language=de&length_scale=0.9
```

## Voice Models

| Language | Voice Key | Speaker | Quality |
|----------|-----------|---------|---------|
| 🇺🇸 English | `en_US-lessac-medium` | lessac | medium |
| 🇩🇪 German | `de_DE-thorsten-medium` | thorsten | medium |
| 🇪🇸 Spanish | `es_ES-davefx-medium` | davefx | medium |
| 🇹🇷 Turkish | `tr_TR-dfki-medium` | dfki | medium |
| 🇷🇺 Russian | `ru_RU-irina-medium` | irina | medium |
| 🇮🇷 Persian | `fa_IR-reza_ibrahim-medium` | reza_ibrahim | medium |

Models are downloaded automatically on first `docker compose up`. To add more voices, download `.onnx` + `.onnx.json` files from [Piper Voices](https://huggingface.co/rhasspy/piper-voices/tree/main) into `voices/`.

### Manual Voice Download

If you prefer to download voices manually (e.g. on a server without Docker):

```bash
chmod +x download-voices.sh
./download-voices.sh            # all languages
./download-voices.sh en de      # only English + German
```

## Integration with Synaplan

This service is designed to work with the [Synaplan platform](https://web.synaplan.com). The TTS service runs on `127.0.0.1:10200`. From the Synaplan backend Docker container, reach it via:

```
http://host.docker.internal:10200
```

The Synaplan backend already has `host.docker.internal` configured.

## Configuration

All settings via environment variables in `docker-compose.yml`:

| Variable | Default | Description |
|----------|---------|-------------|
| `TTS_BIND_ADDRESS` | `127.0.0.1` | IP to bind the service to (set in `.env`) |
| `VOICES_DIR` | `/voices` | Path to voice model directory |
| `DEFAULT_VOICE` | `en_US-lessac-medium` | Fallback voice when none specified |
| `MAX_TEXT_LENGTH` | `5000` | Maximum characters per request |
| `SYNTH_WORKERS` | `4` | Thread pool size for synthesis |

### Environment-based deployment

The same `docker-compose.yml` works for both local development and production:

| Environment | `.env` file | Binds to |
|---|---|---|
| Local dev | None needed | `127.0.0.1:10200` (default) |
| GPU server | `TTS_BIND_ADDRESS=10.0.1.10` | `10.0.1.10:10200` |

Copy `.env.example` to `.env` on the server and set `TTS_BIND_ADDRESS` to your LAN IP.

## Directory Structure

```
synaplan-tts/
├── docker-compose.yml    # Service configuration
├── Dockerfile            # TTS server image build
├── server.py             # FastAPI HTTP API
├── requirements.txt      # Python dependencies
├── download-voices.sh    # Manual voice download script
├── .env.example          # Environment template for deployment
├── voices/               # Voice models (gitignored)
│   ├── en_US-lessac-medium.onnx
│   ├── en_US-lessac-medium.onnx.json
│   ├── de_DE-thorsten-medium.onnx
│   └── ...
├── data/                 # Runtime data
├── LICENSE
└── README.md
```

## GPU Server Deployment

1. Push code to your server (voices are gitignored):
   ```bash
   rsync -av --exclude voices synaplan-tts/ user@gpu:/opt/synaplan-tts/
   ```

2. On the GPU server, copy voice models:
   ```bash
   scp -r voices/ user@gpu:/opt/synaplan-tts/voices/
   ```

3. Configure the bind address:
   ```bash
   cp .env.example .env
   # Edit .env — set TTS_BIND_ADDRESS to your LAN IP
   ```

4. Start the service:
   ```bash
   cd /opt/synaplan-tts
   docker compose up -d
   docker compose logs -f
   ```

5. Lock down access:
   - Bind to LAN IP only (never `0.0.0.0`)
   - Firewall: allow only Synaplan nodes to port `10200/tcp`

## License

Apache License 2.0
