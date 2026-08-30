# Synaplan TTS

> **Optional companion** to [Synaplan](https://github.com/metadist/synaplan) — only needed for voice output.
> Synaplan runs fully without it.
>
> **Image**: [`ghcr.io/metadist/synaplan-tts`](https://github.com/metadist/synaplan-tts/pkgs/container/synaplan-tts) &nbsp;|&nbsp; **Docs**: [docs.synaplan.com/tts](https://docs.synaplan.com/index.php/tts) &nbsp;|&nbsp; **Main app**: [github.com/metadist/synaplan](https://github.com/metadist/synaplan)

Self-hosted multi-language text-to-speech service powered by [Piper](https://github.com/rhasspy/piper). Exposes a small HTTP API that Synaplan calls to synthesize speech.

The published image **ships five voices** (English, German, Spanish, French, Turkish). No first-run download, no HuggingFace dependency at startup. Drop extra `.onnx` models into `./voices/` if you need more languages.

## Why a separate service?

TTS is optional, CPU-heavy, and language-pack heavy. Keeping it in its own image means:

- The main Synaplan stack stays small — people who only want chat and RAG never pull ~250 MB of voice models.
- You can run Piper on a different machine (a GPU box, a LAN appliance) and point several Synaplan nodes at it.
- Voice models update independently of the PHP/Vue app.
- Speech **input** (Whisper) already lives in the main image; speech **output** stays a choice.

Synaplan auto-enables the speaker button when this service answers on `SYNAPLAN_TTS_URL`.

## Quick Start

**With Synaplan** (same compose file, opt-in profile):

```bash
cd synaplan
docker compose --profile tts up -d
```

**Standalone** (this repo, or any host that should only speak):

```bash
git clone https://github.com/metadist/synaplan-tts.git
cd synaplan-tts
docker compose up -d
```

Or run the published image without cloning:

```bash
docker run -d --name synaplan-tts -p 127.0.0.1:10200:10200 ghcr.io/metadist/synaplan-tts:latest
```

Verify:

```bash
curl http://127.0.0.1:10200/health
```

You should see `"voices_loaded": 5` and the five keys below. Synaplan reaches the service via `SYNAPLAN_TTS_URL` (compose default: `http://host.docker.internal:10200`).

Test speech synthesis:

```bash
curl "http://127.0.0.1:10200/api/tts?text=Hello+world&language=en" -o test_en.wav
curl "http://127.0.0.1:10200/api/tts?text=Hallo+Welt&language=de" -o test_de.wav
curl "http://127.0.0.1:10200/api/tts?text=Hola+mundo&language=es" -o test_es.wav
curl "http://127.0.0.1:10200/api/tts?text=Bonjour+le+monde&language=fr" -o test_fr.wav
curl "http://127.0.0.1:10200/api/tts?text=Merhaba+dünya&language=tr" -o test_tr.wav
```

## Bundled voices

These five are **inside the image**. They match Synaplan's UI locales (`en`, `de`, `es`, `fr`, `tr`): the frontend language / detected reply language selects the voice automatically.

| Language | Voice key | Speaker | Quality |
|----------|-----------|---------|---------|
| English (US) | `en_US-lessac-medium` | lessac | medium |
| German | `de_DE-kerstin-low` | kerstin | low |
| Spanish | `es_ES-davefx-medium` | davefx | medium |
| French | `fr_FR-siwis-medium` | siwis | medium |
| Turkish | `tr_TR-dfki-medium` | dfki | medium |

German is a female voice at `low` quality (16 kHz) because Piper publishes no
medium-quality female German model — the only German voices above 16 kHz are the
male Thorsten and the multi-speaker `de_DE-mls-medium`, which drifts badly on short
prompts. To get the male Thorsten back, fetch him as an extra and request
`voice=de_DE-thorsten-medium`:

```bash
./download-voices.sh de-male
docker compose restart piper
```

How Synaplan picks a voice: the chat UI sends its locale; if the backend detects another reply language, that wins. Piper then maps `en` / `de` / `es` / `fr` / `tr` to the row above. An explicit `voice=` query still overrides everything.

## Adding more voices

1. Pick a model on [Piper Voices](https://huggingface.co/rhasspy/piper-voices/tree/main). You need **both** files: `<voice>.onnx` and `<voice>.onnx.json`.
2. Drop them into `./voices/` next to this compose file (the container mounts that folder as `/voices-extra`).
3. Restart: `docker compose restart piper`.
4. `GET /api/voices` lists every loaded model. Call TTS with `voice=<key>` or `language=<xx>`.

Helper for the catalog extras (male German, Russian, Persian) or to re-fetch a bundled voice onto the host:

```bash
./download-voices.sh            # catalog (skips files that already exist)
./download-voices.sh ru fa      # only those languages
./download-voices.sh de-male    # male German (de_DE-thorsten-medium)
```

Do **not** mount `./voices` over `/voices` — that hides the five baked models.

## API Reference

### `GET /health`

Health check — returns loaded voice count and available voices.

```json
{
  "status": "ok",
  "voices_loaded": 5,
  "available_voices": ["de_DE-kerstin-low", "en_US-lessac-medium", "es_ES-davefx-medium", "fr_FR-siwis-medium", "tr_TR-dfki-medium"],
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
| `language` | string | – | Language shortcode: `en`, `de`, `es`, `fr`, `tr`, plus any extra you added |
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

## Configuration

All settings via environment variables in `docker-compose.yml`:

| Variable | Default | Description |
|----------|---------|-------------|
| `TTS_BIND_ADDRESS` | `127.0.0.1` | IP to bind the service to (set in `.env`) |
| `VOICES_DIR` | `/voices` | Baked-in voice directory (do not overwrite) |
| `EXTRA_VOICES_DIR` | `/voices-extra` | Host-mounted extras (`./voices`) |
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
├── Dockerfile            # Bakes 5 voices + TTS server
├── server.py             # FastAPI HTTP API
├── requirements.txt      # Python dependencies
├── download-voices.sh    # Optional extra-voice helper
├── .env.example          # Environment template for deployment
├── voices/               # Extra voices only (gitignored)
├── data/                 # Runtime data
├── LICENSE
└── README.md
```

## GPU Server Deployment

1. Pull the image (voices are already inside):
   ```bash
   docker pull ghcr.io/metadist/synaplan-tts:latest
   ```

2. Optional: copy extra voice models:
   ```bash
   scp -r extra-voices/ user@gpu:/opt/synaplan-tts/voices/
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

6. Enable automatic updates (optional but recommended):
   - Use [`docker-compose.prod.yml`](docker-compose.prod.yml) (image-only, no local build) as the server's `docker-compose.yml`.
   - Install the watchguard timer so new GHCR images roll out within ~2 minutes. See [`deploy/README.md`](deploy/README.md).

## Related

- [Main app — synaplan](https://github.com/metadist/synaplan)
- [Public docs — docs.synaplan.com/tts](https://docs.synaplan.com/index.php/tts)
- [Plugin overview](https://docs.synaplan.com/index.php/plugins)

## License

Apache License 2.0
