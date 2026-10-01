#!/usr/bin/env python3
"""Build the actual production control strip in an isolated visual fixture."""
from pathlib import Path
import plistlib
import subprocess
import tempfile
import sys

root = Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory(prefix='vibefloat-controls-') as folder:
    bundle = Path(folder) / 'VibeFloatControlsPreview.app/Contents'
    (bundle / 'MacOS').mkdir(parents=True)
    info = plistlib.loads((root / 'Support/Info.plist').read_bytes())
    info['CFBundleIdentifier'] = 'com.aspect.floatvideo.controls-preview'
    info['CFBundleName'] = 'VibeFloat Controls Preview'
    (bundle / 'Info.plist').write_bytes(plistlib.dumps(info))
    sources = sorted(str(p) for p in (root / 'Sources').glob('*.swift') if p.name != 'main.swift')
    subprocess.run(['swiftc', '-swift-version', '5', *sources,
                    str(root / 'tests/floating-player-preview.swift'),
                    '-framework', 'Carbon', '-framework', 'MediaPlayer',
                    '-framework', 'ApplicationServices', '-framework', 'Speech',
                    '-framework', 'AVFoundation', '-o', str(bundle / 'MacOS/FloatVideo')], check=True)
    subprocess.run(['codesign', '--force', '--sign', '-', str(bundle.parent)], check=True)
    print('Preview bundle:', bundle.parent, flush=True)
    subprocess.run([str(bundle / 'MacOS/FloatVideo'), *sys.argv[1:]], check=True)
