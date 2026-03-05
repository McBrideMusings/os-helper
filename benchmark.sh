#!/bin/bash
set -e

cd "$(dirname "$0")/Benchmark"

if [ $# -eq 0 ]; then
    echo "Usage: ./benchmark.sh <audio-file> [options]"
    echo ""
    echo "Accepts WAV, M4A, MP3, CAF, AIFF, or any ffmpeg-supported format."
    echo "Non-WAV files are auto-converted to 16kHz mono WAV."
    echo ""
    echo "Options:"
    echo "  --whisper-model <name>   WhisperKit model (default: openai_whisper-base)"
    echo "  --runs <n>               Runs per engine (default: 1)"
    echo "  --compute <mode>         CoreML compute: all, cpu-ane, cpu-gpu, cpu (default: all)"
    echo "  --qwen-variant <v>       Qwen3 variant: f32, int8 (default: f32)"
    echo "  --skip-parakeet          Skip Parakeet engine"
    echo "  --skip-whisper           Skip WhisperKit engine"
    echo "  --skip-qwen              Skip Qwen3 engine"
    echo ""
    echo "Examples:"
    echo "  ./benchmark.sh ~/recording.m4a"
    echo "  ./benchmark.sh ~/test.wav --runs 5"
    echo "  ./benchmark.sh ~/test.wav --whisper-model openai_whisper-large-v3-v20240930"
    echo "  ./benchmark.sh ~/test.wav --compute cpu-ane    # ANE only (power efficient)"
    echo "  ./benchmark.sh ~/test.wav --skip-whisper       # Parakeet + Qwen3 only"
    exit 1
fi

AUDIO_FILE="$1"
shift

if [ ! -f "$AUDIO_FILE" ]; then
    echo "Error: File not found: $AUDIO_FILE"
    exit 1
fi

# Convert non-WAV to 16kHz mono WAV
CLEANUP_WAV=""
EXT="${AUDIO_FILE##*.}"
if [ "$(echo "$EXT" | tr '[:upper:]' '[:lower:]')" != "wav" ]; then
    WAV_FILE="/tmp/benchmark_$(date +%s).wav"
    echo "Converting ${EXT} → WAV (16kHz mono)..."
    ffmpeg -i "$AUDIO_FILE" -ar 16000 -ac 1 -y "$WAV_FILE" 2>&1 | grep -E "Duration|Output|size=" || true
    echo ""
    AUDIO_FILE="$WAV_FILE"
    CLEANUP_WAV="$WAV_FILE"
fi

echo "Building benchmark tool..."
swift build 2>&1 | grep -E "Build|Compil|Link|error:|warning:" || true
echo ""

swift run benchmark "$AUDIO_FILE" "$@"

# Clean up temp WAV
if [ -n "$CLEANUP_WAV" ]; then
    rm -f "$CLEANUP_WAV"
fi
