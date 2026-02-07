#!/usr/bin/env bash
# ───────────────────────────────────────────────────────────────
# download-voices.sh — Download Piper TTS voice models
#
# Downloads voice models for: English, German, Spanish, Turkish, Russian
# Each voice needs an .onnx model file + .onnx.json config file.
#
# Usage:
#   ./download-voices.sh              # download all voices
#   ./download-voices.sh en de        # download only English + German
#   VOICES_DIR=/my/path ./download-voices.sh   # custom output directory
# ───────────────────────────────────────────────────────────────
set -euo pipefail

VOICES_DIR="${VOICES_DIR:-./voices}"
BASE_URL="https://huggingface.co/rhasspy/piper-voices/resolve/main"

# ── Voice definitions ─────────────────────────────────────────
# Format: LANG_CODE|VOICE_KEY|HF_PATH
VOICE_DEFS=(
  "en|en_US-lessac-medium|en/en_US/lessac/medium"
  "de|de_DE-thorsten-medium|de/de_DE/thorsten/medium"
  "es|es_ES-davefx-medium|es/es_ES/davefx/medium"
  "tr|tr_TR-dfki-medium|tr/tr_TR/dfki/medium"
  "ru|ru_RU-irina-medium|ru/ru_RU/irina/medium"
  "fa|fa_IR-reza_ibrahim-medium|fa/fa_IR/reza_ibrahim/medium"
)

# ── Parse optional language filter ────────────────────────────
FILTER_LANGS=()
if [[ $# -gt 0 ]]; then
  FILTER_LANGS=("$@")
  echo "Downloading voices for: ${FILTER_LANGS[*]}"
else
  echo "Downloading all voices"
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

  # Apply language filter
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
    # Clean up partial downloads
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

if [[ $FAILED -gt 0 ]]; then
  echo ""
  echo "⚠  Some downloads failed. Re-run the script to retry."
  exit 1
fi
