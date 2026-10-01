#!/usr/bin/env python3
"""Open a curated YouTube movie in the actual native WebView and verify its clock.

Runs a throwaway copy of the app (see vibe_app.py) and drives it over the local API.
Needs network access to YouTube and a display.
"""
import argparse
import json
from pathlib import Path
import sys
import time

sys.path.insert(0, str(Path(__file__).resolve().parent))
from vibe_app import ROOT, VibeApp  # noqa: E402

parser = argparse.ArgumentParser()
parser.add_argument('--binary', type=Path, default=ROOT / '.build/debug/FloatVideo')
parser.add_argument('--video', default='4bjvj11fdV4')
parser.add_argument('--timeout', type=float, default=35)
parser.add_argument('--controls', action='store_true', help='Also verify pause, ten-second seek, and resume')
args = parser.parse_args()

with VibeApp(binary=args.binary) as app:
    app.open_player(site='youtube', url=f'https://www.youtube.com/watch?v={args.video}',
                    embedUrl=f'https://www.youtube.com/embed/{args.video}', preferEmbed=True,
                    aiDubEnabled=False, title='YouTube playback check', width=640, height=360)
    deadline = time.monotonic() + args.timeout
    baseline = None
    state = None
    while time.monotonic() < deadline and app.process.poll() is None:
        time.sleep(.5)
        state = app.status()
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
        raise AssertionError('Movie clock did not advance. Status: ' + repr(state) + '\n'
                             + '\n'.join(line for line in app.logs
                                         if any(word in line for word in ['Blocked', 'loaded', 'unhealthy', 'failed', 'Loading preferred'])))

    if args.controls:
        def await_state(predicate, description):
            limit = time.monotonic() + 10
            while time.monotonic() < limit:
                time.sleep(.3)
                current = app.status()
                if predicate(current):
                    return current
            raise AssertionError(description)

        app.api('pause')
        paused_state = await_state(lambda s: s.get('isPlaying') is False and s.get('duration', 0) > 60,
                                   'Pause did not reach the actual player')
        paused_at = paused_state['currentTime']
        time.sleep(1)
        stable = await_state(lambda s: s.get('isPlaying') is False, 'Player did not stay paused')
        assert abs(stable['currentTime'] - paused_at) < 1, 'Paused movie clock kept moving'
        app.api('forward')
        seeked = await_state(lambda s: s.get('currentTime', 0) >= paused_at + 8,
                             'Ten-second seek did not reach the actual player')
        app.api('play')
        await_state(lambda s: s.get('isPlaying') and s.get('currentTime', 0) > seeked['currentTime'] + 1,
                    'Resume did not advance the clock')
        print(json.dumps({'controlsPassed': True, 'pause': True, 'seekForward': True, 'resume': True}))
