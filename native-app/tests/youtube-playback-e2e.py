#!/usr/bin/env python3
"""Open a curated YouTube movie in the actual native WebView and verify its clock."""
import argparse
import json
import os
from pathlib import Path
import shutil
import struct
import subprocess
import tempfile
import threading
import time

ROOT = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser()
parser.add_argument('--binary', type=Path, default=ROOT / '.build/debug/FloatVideo')
parser.add_argument('--video', default='4bjvj11fdV4')
parser.add_argument('--timeout', type=float, default=35)
parser.add_argument('--controls', action='store_true', help='Also verify pause, ten-second seek, and resume')
args = parser.parse_args()

# Test processes publish the same local-control files as the companion. Restore
# the running app's private files after testing, without printing their contents.
control_files = [Path.home() / '.floatvideo_port', Path.home() / '.floatvideo_token']
previous = {p: p.read_bytes() if p.is_file() else None for p in control_files}
with tempfile.TemporaryDirectory(prefix='vibefloat-youtube-test-') as folder:
    bundle = Path(folder) / 'VibeFloatTest.app/Contents'
    (bundle / 'MacOS').mkdir(parents=True)
    shutil.copy2(args.binary, bundle / 'MacOS/FloatVideo')
    shutil.copy2(ROOT / 'Support/Info.plist', bundle / 'Info.plist')
    subprocess.run(['codesign', '--force', '--sign', '-', str(bundle.parent)],
                   check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    process = subprocess.Popen([str(bundle / 'MacOS/FloatVideo'), '--native-messaging'],
                               stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    responses, logs = [], []
    def read_responses():
        while True:
            header = process.stdout.read(4)
            if len(header) != 4:
                return
            size = struct.unpack('<I', header)[0]
            responses.append(json.loads(process.stdout.read(size)))
    threading.Thread(target=read_responses, daemon=True).start()
    threading.Thread(target=lambda: logs.extend(line.decode('utf-8', 'replace').rstrip()
                                               for line in process.stderr), daemon=True).start()
    def send(action, **values):
        payload = json.dumps({'action': action, **values}).encode()
        process.stdin.write(struct.pack('<I', len(payload)) + payload)
        process.stdin.flush()
    try:
        send('open', site='youtube', url=f'https://www.youtube.com/watch?v={args.video}',
             embedUrl=f'https://www.youtube.com/embed/{args.video}', preferEmbed=True,
             aiDubEnabled=False, title='YouTube playback check', width=640, height=360)
        deadline = time.monotonic() + args.timeout
        baseline = None
        while time.monotonic() < deadline and process.poll() is None:
            send('getStatus')
            time.sleep(.5)
            states = [r for r in responses if r.get('type') == 'status' and 'currentTime' in r]
            if not states:
                continue
            state = states[-1]
            if state.get('isPlaying') and state.get('currentTime', 0) > .5:
                if baseline is None:
                    baseline = state['currentTime']
                elif state['currentTime'] > baseline + 1:
                    assert state.get('duration', 0) > 60, 'verify movie duration, not just an empty player'
                    assert state.get('isGhost') is False
                    print(json.dumps({'passed': True, 'video': args.video, 'currentTime': state['currentTime'],
                                      'duration': state['duration'], 'isGhost': state['isGhost']}))
                    break
        else:
            raise AssertionError('Movie clock did not advance. Status: ' + repr(states[-1:] if states else [])
                                 + '\n' + '\n'.join(line for line in logs if any(word in line for word in ['Blocked', 'loaded', 'unhealthy', 'failed', 'Loading preferred'])))
        if args.controls:
            def await_state(predicate, description):
                limit = time.monotonic() + 10
                while time.monotonic() < limit:
                    start = len(responses)
                    send('getStatus')
                    time.sleep(.3)
                    for response in responses[start:]:
                        if response.get('type') == 'status' and predicate(response):
                            return response
                raise AssertionError(description)
            send('pause')
            paused_state = await_state(lambda s: s.get('isPlaying') is False and s.get('duration', 0) > 60,
                                       'Pause did not reach the actual player')
            paused_at = paused_state['currentTime']
            time.sleep(1)
            stable = await_state(lambda s: s.get('isPlaying') is False, 'Player did not stay paused')
            assert abs(stable['currentTime'] - paused_at) < 1, 'Paused movie clock kept moving'
            send('skipForward')
            seeked = await_state(lambda s: s.get('currentTime', 0) >= paused_at + 8,
                                 'Ten-second seek did not reach the actual player')
            send('play')
            await_state(lambda s: s.get('isPlaying') and s.get('currentTime', 0) > seeked['currentTime'] + 1,
                        'Resume did not advance the clock')
            print(json.dumps({'controlsPassed': True, 'pause': True, 'seekForward': True, 'resume': True}))
    finally:
        process.stdin.close()
        try:
            process.wait(timeout=3)
        except subprocess.TimeoutExpired:
            process.terminate()
            process.wait(timeout=3)
        for path, content in previous.items():
            if content is None:
                path.unlink(missing_ok=True)
            else:
                path.write_bytes(content)
                os.chmod(path, 0o600)
