#!/usr/bin/env bash
# Builds the offline frame diagnostic into .build/vibefloat-diagnose.
#
# The tool has to report what the app's OWN detectors decide, so it compiles
# three of them straight out of Sources/FloatWindow.swift. They are pure
# functions of a CGImage and are only inaccessible because the class around
# them needs AppKit and a running app — so they are extracted verbatim (not
# copied) and compiled as free functions. If either extraction ever fails the
# build stops rather than silently diagnosing with stale logic.
set -euo pipefail
cd "$(dirname "$0")/.."

generated=.build/diagnose/Heuristics.swift
mkdir -p .build/diagnose

extract() {
  local name="$1"
  awk -v start="private static func $name(" '
    !capture && index($0, start) { capture = 1 }
    capture {
      print
      copy = $0
      nOpen = gsub(/\{/, "{", copy)
      nClose = gsub(/\}/, "}", copy)
      depth += nOpen - nClose
      if (depth == 0) exit
    }
  ' Sources/FloatWindow.swift
}

{
  echo "import AppKit"
  echo "import Foundation"
  echo ""
  for name in looksLike9922Splash looksLikeSlotFrame renderedLetterbox; do
    echo "// --- extracted from Sources/FloatWindow.swift ---"
    body="$(extract "$name" | sed 's/private static func /func /')"
    if [[ "$body" != *"func $name("* ]]; then
      echo "extraction failed: $name" >&2
      exit 1
    fi
    echo "$body"
    echo ""
  done
} > "$generated"

swiftc -O -o .build/vibefloat-diagnose \
  Sources/AdClassifier.swift \
  "$generated" \
  tools/diagnose/main.swift

echo "built .build/vibefloat-diagnose"
