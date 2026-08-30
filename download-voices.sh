#!/usr/bin/env bash
# ───────────────────────────────────────────────────────────────
# download-voices.sh — Download extra Piper TTS voice models
#
# The published Docker image already ships five voices:
#   en  en_US-lessac-medium
#   de  de_DE-kerstin-low
#   es  es_ES-davefx-medium
#   fr  fr_FR-siwis-medium
#   tr  tr_TR-dfki-medium
# Re-running this script for those languages is a no-op when the files exist.
#
# Extra voices (the male German Thorsten, Russian, Persian, or any Piper model)
# go in ./voices/ which
# the container mounts as EXTRA_VOICES_DIR. Each voice needs an .onnx model
# plus a matching .onnx.json config.
#
# Usage:
#   ./download-voices.sh              # bundled + extra catalog entries
#   ./download-voices.sh ru fa        # only Russian + Persian
#   VOICES_DIR=/my/path ./download-voices.sh
#
# Any other Piper voice: download the pair from
#   https://huggingface.co/rhasspy/piper-voices/tree/main
# into ./voices/ and restart the container. No rebuild required.
# ───────────────────────────────────────────────────────────────
set -euo pipefail

VOICES_DIR="${VOICES_DIR:-./voices}"
BASE_URL="https://huggingface.co/rhasspy/piper-voices/resolve/main"

# ── Voice definitions ─────────────────────────────────────────
# Format: LANG_CODE|VOICE_KEY|HF_PATH
# First five are the bundled set; the rest are extras you opt into.
VOICE_DEFS=(
  "en|en_US-lessac-medium|en/en_US/lessac/medium"
  "de|de_DE-kerstin-low|de/de_DE/kerstin/low"
  "es|es_ES-davefx-medium|es/es_ES/davefx/medium"
  "fr|fr_FR-siwis-medium|fr/fr_FR/siwis/medium"
  "tr|tr_TR-dfki-medium|tr/tr_TR/dfki/medium"
  "ru|ru_RU-irina-medium|ru/ru_RU/irina/medium"
  "fa|fa_IR-reza_ibrahim-medium|fa/fa_IR/reza_ibrahim/medium"
  # Male German, medium quality — the former bundled voice, opt in with "de-male"
  "de-male|de_DE-thorsten-medium|de/de_DE/thorsten/medium"
)

# ── Parse optional language filter ────────────────────────────
FILTER_LANGS=()
if [[ $# -gt 0 ]]; then
  FILTER_LANGS=("$@")
  echo "Downloading voices for: ${FILTER_LANGS[*]}"
else
  echo "Downloading catalog voices (bundled five are skipped if already present)"
fi

mkdir -p "$VOICES_DIR"

download_file() {
  local url="$1" dest="$2"
  if [[ -f "$dest" ]]; then
    echo "  ✓ Already exists: $(basename "$dest")"
    return 0
  fi
  echo "  ↓ Downloading: $(basename "$dest")"
  curl -fL --retry 3 --retry-delay 5 --max-time 600 \
    --progress-bar \
    -o "$dest" "$url"
}

# ── Download loop ─────────────────────────────────────────────
TOTAL=0
DOWNLOADED=0
SKIPPED=0
FAILED=0

for def in "${VOICE_DEFS[@]}"; do
  IFS='|' read -r lang voice_key hf_path <<< "$def"

  if [[ ${#FILTER_LANGS[@]} -gt 0 ]]; then
    match=false
    for fl in "${FILTER_LANGS[@]}"; do
      if [[ "$fl" == "$lang" ]]; then match=true; break; fi
    done
    if ! $match; then continue; fi
  fi

  TOTAL=$((TOTAL + 1))
  echo ""
  echo "[$lang] $voice_key"

  onnx_url="${BASE_URL}/${hf_path}/${voice_key}.onnx"
  json_url="${BASE_URL}/${hf_path}/${voice_key}.onnx.json"
  onnx_dest="${VOICES_DIR}/${voice_key}.onnx"
  json_dest="${VOICES_DIR}/${voice_key}.onnx.json"

  if [[ -f "$onnx_dest" && -f "$json_dest" ]]; then
    echo "  ✓ Already downloaded"
    SKIPPED=$((SKIPPED + 1))
    continue
  fi

  if download_file "$onnx_url" "$onnx_dest" && \
     download_file "$json_url" "$json_dest"; then
    DOWNLOADED=$((DOWNLOADED + 1))
  else
    echo "  ✗ FAILED to download $voice_key"
    FAILED=$((FAILED + 1))
    rm -f "$onnx_dest" "$json_dest"
  fi
done

echo ""
echo "════════════════════════════════════════════"
echo "  Total:      $TOTAL voice(s)"
echo "  Downloaded: $DOWNLOADED"
echo "  Skipped:    $SKIPPED (already present)"
echo "  Failed:     $FAILED"
echo "  Directory:  $VOICES_DIR"
echo "════════════════════════════════════════════"
echo ""
echo "Restart the container to load new voices:"
echo "  docker compose restart piper"

if [[ $FAILED -gt 0 ]]; then
  echo ""
  echo "⚠  Some downloads failed. Re-run the script to retry."
  exit 1
fi
