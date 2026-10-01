#!/usr/bin/env bash
# Runs every test in this folder.
#
#   tests/run.sh                 # all of them
#   tests/run.sh black-bars      # only the files whose name matches
#
# Two kinds of test live here:
#   * tests/ad-classifier/       real native unit tests, compiled with swiftc
#     tests/watch-assist/        against the same pure sources the app builds
#                                (neither pulls in AppKit, and that is on purpose);
#   * tests/*.test.js            player-script scenarios, run in node by pulling
#                                the embedded JavaScript out of FloatWindow.swift.
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build

filter="${1:-}"

if [[ -z "$filter" || "ad-classifier" == *"$filter"* ]]; then
  echo "== swiftc: ad-classifier"
  swiftc -o .build/ad-classifier-test Sources/AdClassifier.swift tests/ad-classifier/main.swift
  ./.build/ad-classifier-test
fi

if [[ -z "$filter" || "watch-assist" == *"$filter"* ]]; then
  echo "== swiftc: watch-assist"
  swiftc -o .build/watch-assist-test Sources/WatchAssist.swift tests/watch-assist/main.swift
  ./.build/watch-assist-test
fi

if [[ -z "$filter" || "subtitle-classifier" == *"$filter"* ]]; then
  echo "== swiftc: subtitle-classifier"
  swiftc -o .build/subtitle-classifier-test Sources/AdClassifier.swift Sources/SubtitleClassifier.swift tests/subtitle-classifier/main.swift
  ./.build/subtitle-classifier-test
fi

if [[ -z "$filter" || "edge-tts" == *"$filter"* ]]; then
  echo "== swiftc: edge-tts"
  swiftc -o .build/edge-tts-test Sources/EdgeTTSManager.swift tests/edge-tts/main.swift
  ./.build/edge-tts-test
fi

if [[ -z "$filter" || "dubbing-translator" == *"$filter"* ]]; then
  echo "== swiftc: dubbing-translator"
  swiftc -o .build/dubbing-translator-test Sources/AdClassifier.swift Sources/SubtitleClassifier.swift Sources/DubbingTranslator.swift tests/dubbing-translator/main.swift
  ./.build/dubbing-translator-test
fi

if [[ -z "$filter" || "offline-dub-session" == *"$filter"* ]]; then
  echo "== swiftc: offline-dub-session"
  swiftc -o .build/offline-dub-session-test Sources/AdClassifier.swift Sources/SubtitleClassifier.swift Sources/DubbingTranslator.swift Sources/EdgeTTSManager.swift Sources/OfflineDubSession.swift tests/offline-dub-session/main.swift
  ./.build/offline-dub-session-test
fi


for test_file in tests/*.test.js; do
  name="$(basename "$test_file")"
  if [[ -n "$filter" && "$name" != *"$filter"* ]]; then continue; fi
  echo "== node: $name"
  node "$test_file"
done
