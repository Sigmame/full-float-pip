#!/usr/bin/env bash
# vibe-sync.sh — Remote CLI control & AI Agent automation for FullFloatPiP / VibeWatch
# Usage: ./vibe-sync.sh [play|pause|toggle|duck|unduck|ghost|boss|opacity <val>|bigger|smaller|size <w>|preset <mini|standard|wide|pocket>|autoNext [on|off]|skipIntro [on|off]|skipIntroNow|next|prev|status]

PORT_FILE="$HOME/.floatvideo_port"
TOKEN_FILE="$HOME/.floatvideo_token"
if [ ! -f "$PORT_FILE" ]; then
    echo '{"error": "FloatVideo is not currently running. Please launch a video first."}'
    exit 1
fi

PORT=$(cat "$PORT_FILE" | tr -d '[:space:]')
if [ -z "$PORT" ]; then
    echo '{"error": "Invalid port in '"$PORT_FILE"'"}'
    exit 1
fi

if [ ! -f "$TOKEN_FILE" ]; then
    echo '{"error": "FloatVideo control token is missing. Reinstall and reopen the player."}'
    exit 1
fi
TOKEN=$(cat "$TOKEN_FILE" | tr -d '[:space:]')
if [ -z "$TOKEN" ]; then
    echo '{"error": "Invalid FloatVideo control token."}'
    exit 1
fi

CMD="${1:-toggle}"

case "$CMD" in
    play|pause|toggle|forward|backward|duck|unduck|ghost|boss|status|bigger|smaller|grow|shrink|next|prev|nextEpisode|prevEpisode|skipIntroNow|skipintronow|aidub|aiDub|toggleAIDub)
        ENDPOINT="api/$CMD"
        ;;
    dubVoice|edgeVoice|voice)
        if [ -n "${2:-}" ]; then
            ENDPOINT="api/dubVoice?voice=$2"
        else
            ENDPOINT="api/dubVoice"
        fi
        ;;
    opacity)
        VAL="${2:-0.6}"
        ENDPOINT="api/opacity?val=$VAL"
        ;;
    size|resize)
        if [ -n "${2:-}" ]; then
            ENDPOINT="api/size?w=$2"
        else
            ENDPOINT="api/size"
        fi
        ;;
    preset|sizePreset)
        VAL="${2:-standard}"
        ENDPOINT="api/preset?val=$VAL"
        ;;
    autoNext|autonext)
        if [ -n "${2:-}" ]; then
            ENDPOINT="api/autoNext?val=$2"
        else
            ENDPOINT="api/autoNext"
        fi
        ;;
    skipIntro|skipintro|autoSkipIntro)
        if [ -n "${2:-}" ]; then
            ENDPOINT="api/skipIntro?val=$2"
        else
            ENDPOINT="api/skipIntro"
        fi
        ;;
    *)
        ENDPOINT="api/$CMD"
        ;;
esac

curl -s -m 2 -H "X-VibeFloat-Token: $TOKEN" "http://127.0.0.1:$PORT/$ENDPOINT"
echo ""
