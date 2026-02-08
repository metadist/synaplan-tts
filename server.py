"""
Synaplan TTS — Piper-based multi-language text-to-speech HTTP API.

Provides a simple REST API that wraps Piper TTS voice models.
Supports multiple voices/languages with automatic model discovery.

Endpoints:
    GET  /health       — Health check + loaded voices
    GET  /api/voices   — List available voices with language info
    POST /api/tts      — Synthesize speech (JSON body) → WAV audio
    GET  /api/tts      — Synthesize speech (query params) → WAV audio
"""

import asyncio
import io
import json
import logging
import os
import wave
import threading
import subprocess
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
from typing import Optional

from fastapi import FastAPI, HTTPException, Query, Response
from fastapi.responses import StreamingResponse
from fastapi.middleware.cors import CORSMiddleware
from pydantic import BaseModel, Field

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(name)s: %(message)s",
)
logger = logging.getLogger("synaplan-tts")

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
VOICES_DIR = Path(os.getenv("VOICES_DIR", "/voices"))
DEFAULT_VOICE = os.getenv("DEFAULT_VOICE", "en_US-lessac-medium")
MAX_TEXT_LENGTH = int(os.getenv("MAX_TEXT_LENGTH", "5000"))

# Thread pool for CPU-bound synthesis (piper is synchronous)
_synth_pool = ThreadPoolExecutor(max_workers=int(os.getenv("SYNTH_WORKERS", "4")))

# ---------------------------------------------------------------------------
# Language / locale metadata
# ---------------------------------------------------------------------------
LANGUAGE_MAP: dict[str, dict] = {
    "en_US": {"name": "English (US)", "code": "en"},
    "en_GB": {"name": "English (UK)", "code": "en"},
    "de_DE": {"name": "German", "code": "de"},
    "es_ES": {"name": "Spanish", "code": "es"},
    "es_MX": {"name": "Spanish (Mexico)", "code": "es"},
    "tr_TR": {"name": "Turkish", "code": "tr"},
    "ru_RU": {"name": "Russian", "code": "ru"},
    "fa_IR": {"name": "Persian", "code": "fa"},
    "fr_FR": {"name": "French", "code": "fr"},
    "it_IT": {"name": "Italian", "code": "it"},
    "pt_BR": {"name": "Portuguese (Brazil)", "code": "pt"},
    "zh_CN": {"name": "Chinese (Mandarin)", "code": "zh"},
    "ar_JO": {"name": "Arabic", "code": "ar"},
}

# ---------------------------------------------------------------------------
# Voice registry
# ---------------------------------------------------------------------------
voices: dict = {}       # voice_key → PiperVoice instance
voice_meta: dict = {}   # voice_key → metadata dict


def _parse_voice_key(key: str) -> dict:
    """Extract locale, speaker and quality from a voice key like 'en_US-lessac-medium'."""
    parts = key.split("-")
    locale = parts[0] if parts else key
    speaker = parts[1] if len(parts) > 1 else "default"
    quality = parts[2] if len(parts) > 2 else "unknown"
    lang_info = LANGUAGE_MAP.get(locale, {"name": locale, "code": locale[:2].lower()})
    return {
        "key": key,
        "locale": locale,
        "language": lang_info["code"],
        "language_name": lang_info["name"],
        "speaker": speaker,
        "quality": quality,
    }


def load_voices() -> None:
    """Scan VOICES_DIR for .onnx models and load them via piper-tts."""
    from piper import PiperVoice  # type: ignore[import-untyped]

    if not VOICES_DIR.exists():
        logger.warning("Voices directory does not exist: %s", VOICES_DIR)
        return

    for onnx_path in sorted(VOICES_DIR.glob("*.onnx")):
        # Skip .onnx.json companion files (glob shouldn't match, but guard anyway)
        if onnx_path.suffixes == [".onnx", ".json"]:
            continue

        config_path = onnx_path.parent / f"{onnx_path.name}.json"
        if not config_path.exists():
            logger.warning("Missing config for %s — skipping", onnx_path.name)
            continue

        voice_key = onnx_path.stem  # e.g. "en_US-lessac-medium"
        try:
            voice = PiperVoice.load(str(onnx_path), config_path=str(config_path))
            voices[voice_key] = voice
            voice_meta[voice_key] = _parse_voice_key(voice_key)

            # Read sample rate from config
            try:
                with open(config_path) as f:
                    cfg = json.load(f)
                voice_meta[voice_key]["sample_rate"] = cfg.get("audio", {}).get(
                    "sample_rate", 22050
                )
            except Exception:
                voice_meta[voice_key]["sample_rate"] = 22050

            logger.info(
                "Loaded voice: %s (%s)",
                voice_key,
                voice_meta[voice_key]["language_name"],
            )
        except Exception:
            logger.exception("Failed to load voice %s", voice_key)


# ---------------------------------------------------------------------------
# FastAPI app
# ---------------------------------------------------------------------------
app = FastAPI(
    title="Synaplan TTS",
    description="Multi-language text-to-speech API powered by Piper",
    version="1.0.0",
)

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_methods=["*"],
    allow_headers=["*"],
)


@app.on_event("startup")
async def _startup() -> None:
    load_voices()
    if voices:
        logger.info("Ready — %d voice(s): %s", len(voices), ", ".join(voices.keys()))
    else:
        logger.warning(
            "No voices loaded! Place .onnx + .onnx.json files in %s", VOICES_DIR
        )


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
def _resolve_voice(
    voice_key: Optional[str], language: Optional[str]
) -> tuple[str, object]:
    """Return (key, PiperVoice) matching the request parameters."""
    if not voices:
        raise HTTPException(503, detail="No voices loaded on server")

    # Exact voice key
    if voice_key and voice_key in voices:
        return voice_key, voices[voice_key]

    if voice_key:
        raise HTTPException(
            404,
            detail=f"Voice '{voice_key}' not found. Available: {list(voices.keys())}",
        )

    # Match by language code
    if language:
        lang = language.lower().strip()
        for key, meta in voice_meta.items():
            if meta["language"] == lang or meta["locale"].lower() == lang:
                return key, voices[key]
        raise HTTPException(
            404,
            detail=f"No voice for language '{language}'. Available: "
            + ", ".join(sorted({m['language'] for m in voice_meta.values()})),
        )

    # Fall back to configured default
    if DEFAULT_VOICE in voices:
        return DEFAULT_VOICE, voices[DEFAULT_VOICE]

    # Ultimate fallback: first loaded voice
    key = next(iter(voices))
    return key, voices[key]


def _synthesize_wav(
    voice: object,
    text: str,
    speaker_id: Optional[int] = None,
    length_scale: Optional[float] = None,
    noise_scale: Optional[float] = None,
    noise_w_scale: Optional[float] = None,
    volume: float = 1.0,
) -> bytes:
    """Run Piper synthesis and return raw WAV bytes (piper-tts ≥ 1.4)."""
    from piper.config import SynthesisConfig  # type: ignore[import-untyped]

    syn_config = SynthesisConfig(
        speaker_id=speaker_id,
        length_scale=length_scale,
        noise_scale=noise_scale,
        noise_w_scale=noise_w_scale,
        volume=volume,
    )

    buf = io.BytesIO()
    wav_file = wave.open(buf, "wb")
    try:
        voice.synthesize_wav(text, wav_file, syn_config=syn_config)  # type: ignore[union-attr]
    finally:
        wav_file.close()
    return buf.getvalue()


async def _stream_opus(
    voice: object,
    text: str,
    speaker_id: Optional[int] = None,
    length_scale: Optional[float] = None,
    noise_scale: Optional[float] = None,
    noise_w_scale: Optional[float] = None,
    volume: float = 1.0,
):
    """Generate Opus/WebM audio stream via ffmpeg."""
    from piper.config import SynthesisConfig  # type: ignore[import-untyped]

    syn_config = SynthesisConfig(
        speaker_id=speaker_id,
        length_scale=length_scale,
        noise_scale=noise_scale,
        noise_w_scale=noise_w_scale,
        volume=volume,
    )

    # Start ffmpeg process
    # Input: 16-bit little-endian PCM, 22050Hz, mono
    # Output: Opus in WebM container
    ffmpeg_proc = await asyncio.create_subprocess_exec(
        "ffmpeg", "-f", "s16le", "-ar", "22050", "-ac", "1", "-i", "-",
        "-c:a", "libopus", "-b:a", "64k", "-f", "webm", "-",
        stdin=asyncio.subprocess.PIPE,
        stdout=asyncio.subprocess.PIPE,
        stderr=asyncio.subprocess.DEVNULL
    )

    queue = asyncio.Queue()
    loop = asyncio.get_running_loop()

    def synth_thread():
        """Run synthesis in a separate thread and push PCM chunks to queue."""
        try:
            # synthesize_stream_raw yields bytes
            for chunk in voice.synthesize_stream_raw(text, syn_config=syn_config): # type: ignore
                loop.call_soon_threadsafe(queue.put_nowait, chunk)
            loop.call_soon_threadsafe(queue.put_nowait, None) # Sentinel
        except Exception as e:
            logger.error(f"Synthesis error: {e}")
            loop.call_soon_threadsafe(queue.put_nowait, None)

    # Start synthesis thread
    threading.Thread(target=synth_thread, daemon=True).start()

    async def feed_ffmpeg():
        """Pull PCM chunks from queue and write to ffmpeg stdin."""
        try:
            while True:
                chunk = await queue.get()
                if chunk is None:
                    break
                if ffmpeg_proc.stdin:
                    ffmpeg_proc.stdin.write(chunk)
                    await ffmpeg_proc.stdin.drain()
            if ffmpeg_proc.stdin:
                ffmpeg_proc.stdin.close()
        except Exception as e:
            logger.error(f"Feed ffmpeg error: {e}")

    # Start feeding ffmpeg in background
    feed_task = asyncio.create_task(feed_ffmpeg())

    # Yield output from ffmpeg stdout
    chunk_size = 4096
    try:
        while True:
            if ffmpeg_proc.stdout:
                data = await ffmpeg_proc.stdout.read(chunk_size)
                if not data:
                    break
                yield data
            else:
                break
    finally:
        await feed_task
        if ffmpeg_proc.returncode is None:
            try:
                ffmpeg_proc.terminate()
            except ProcessLookupError:
                pass
        await ffmpeg_proc.wait()


# ---------------------------------------------------------------------------
# Endpoints
# ---------------------------------------------------------------------------
@app.get("/health")
async def health():
    """Health check — returns loaded voice count."""
    return {
        "status": "ok" if voices else "no_voices",
        "voices_loaded": len(voices),
        "available_voices": list(voices.keys()),
        "default_voice": DEFAULT_VOICE,
    }


@app.get("/api/voices")
async def list_voices():
    """Return metadata for every loaded voice."""
    return list(voice_meta.values())


class TTSRequest(BaseModel):
    """JSON body for POST /api/tts."""

    text: str = Field(..., min_length=1, max_length=MAX_TEXT_LENGTH)
    voice: Optional[str] = Field(
        None, description="Exact voice key, e.g. 'de_DE-thorsten-medium'"
    )
    language: Optional[str] = Field(
        None, description="Language shortcode: de, en, es, tr, ru"
    )
    speaker_id: Optional[int] = Field(None, description="Multi-speaker voice index")
    length_scale: Optional[float] = Field(
        None, description="Speed — <1.0 = faster, >1.0 = slower"
    )
    noise_scale: Optional[float] = Field(None, description="Phoneme noise")
    noise_w_scale: Optional[float] = Field(None, description="Phoneme width noise")
    volume: float = Field(1.0, ge=0.0, le=5.0, description="Output volume multiplier")
    stream: bool = Field(False, description="Stream audio as Opus/WebM instead of returning WAV")


@app.post("/api/tts")
async def tts_post(req: TTSRequest):
    """Synthesize speech from JSON body — returns WAV audio or Opus stream."""
    voice_key, voice_obj = _resolve_voice(req.voice, req.language)

    if req.stream:
        return StreamingResponse(
            _stream_opus(
                voice_obj,
                req.text,
                req.speaker_id,
                req.length_scale,
                req.noise_scale,
                req.noise_w_scale,
                req.volume,
            ),
            media_type="audio/webm",
            headers={"X-Voice": voice_key},
        )

    loop = asyncio.get_event_loop()
    audio = await loop.run_in_executor(
        _synth_pool,
        _synthesize_wav,
        voice_obj,
        req.text,
        req.speaker_id,
        req.length_scale,
        req.noise_scale,
        req.noise_w_scale,
        req.volume,
    )

    return Response(
        content=audio,
        media_type="audio/wav",
        headers={
            "X-Voice": voice_key,
            "Content-Disposition": 'inline; filename="tts.wav"',
        },
    )


@app.get("/api/tts")
async def tts_get(
    text: str = Query(..., min_length=1, max_length=MAX_TEXT_LENGTH),
    voice: Optional[str] = Query(None, description="Voice key"),
    language: Optional[str] = Query(None, description="Language code (de, en, es, tr, ru)"),
    length_scale: Optional[float] = Query(None, description="Speed factor"),
    volume: float = Query(1.0, ge=0.0, le=5.0),
    stream: bool = Query(False, description="Stream audio as Opus/WebM"),
):
    """Synthesize speech from query parameters — returns WAV audio or Opus stream.

    Handy for quick browser testing:
        http://localhost:10200/api/tts?text=Hallo+Welt&language=de&stream=true
    """
    voice_key, voice_obj = _resolve_voice(voice, language)

    if stream:
        return StreamingResponse(
            _stream_opus(
                voice_obj,
                text,
                None,           # speaker_id
                length_scale,
                None,           # noise_scale
                None,           # noise_w_scale
                volume,
            ),
            media_type="audio/webm",
            headers={"X-Voice": voice_key},
        )

    loop = asyncio.get_event_loop()
    audio = await loop.run_in_executor(
        _synth_pool,
        _synthesize_wav,
        voice_obj,
        text,
        None,           # speaker_id
        length_scale,
        None,           # noise_scale
        None,           # noise_w_scale
        volume,
    )

    return Response(
        content=audio,
        media_type="audio/wav",
        headers={
            "X-Voice": voice_key,
            "Content-Disposition": 'inline; filename="tts.wav"',
        },
    )
