#!/usr/bin/env python3
"""Verify Offline Dub releases a video inside a cross-origin iframe."""

import http.server
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
APP = ROOT / ".build/release/FloatVideo"


class QuietHandler(http.server.SimpleHTTPRequestHandler):
    def log_message(self, *_args):
        pass


def run():
    if not APP.exists() or not shutil.which("ffmpeg"):
        raise SystemExit("Build the release app and install ffmpeg before running this test")
    with tempfile.TemporaryDirectory(prefix="vibefloat-iframe-test-") as folder:
        fixture = Path(folder)
        subprocess.run([
            "ffmpeg", "-hide_banner", "-loglevel", "error", "-y",
            "-f", "lavfi", "-i", "color=c=blue:s=640x360:r=24:d=25",
            "-c:v", "libx264", "-pix_fmt", "yuv420p", "-movflags", "+faststart",
            str(fixture / "video.mp4"),
        ], check=True)
        (fixture / "inner.html").write_text(
            '<!doctype html><meta charset="utf-8">'
            '<video id="movie" autoplay muted playsinline width="640" height="360" '
            'src="/video.mp4"></video>'
            '<script>const v=document.getElementById("movie");setInterval(()=>'
            'parent.postMessage({floatTestClock:true,ct:v.currentTime,dur:v.duration,'
            'paused:v.paused},"*"),100)</script>', encoding="utf-8")
        server = http.server.ThreadingHTTPServer(("127.0.0.1", 0),
            lambda *args, **kwargs: QuietHandler(*args, directory=folder, **kwargs))
        threading.Thread(target=server.serve_forever, daemon=True).start()
        (fixture / "index.html").write_text(
            '<!doctype html><meta charset="utf-8">'
            '<script>window.addEventListener("message",e=>{if(e.data?.floatTestClock)'
            'window.__floatClock=e.data})</script>'
            f'<iframe src="http://localhost:{server.server_port}/inner.html" '
            'allow="autoplay *" width="640" height="360"></iframe>', encoding="utf-8")

        bundle = fixture / "VibeFloatTest.app" / "Contents"
        (bundle / "MacOS").mkdir(parents=True)
        shutil.copy2(APP, bundle / "MacOS" / "FloatVideo")
        shutil.copy2(ROOT / "Support" / "Info.plist", bundle / "Info.plist")
        subprocess.run(["codesign", "--force", "--sign", "-", str(bundle.parent)],
                       check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        proc = subprocess.Popen([str(bundle / "MacOS" / "FloatVideo"), "--native-messaging"],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            env={**os.environ, "VIBEFLOAT_DUB_TEST": "1"})
        responses = []
        logs = []
        def read_responses():
            while True:
                header = proc.stdout.read(4)
                if len(header) != 4:
                    break
                size = struct.unpack("<I", header)[0]
                responses.append(json.loads(proc.stdout.read(size)))
        threading.Thread(target=read_responses, daemon=True).start()
        threading.Thread(target=lambda: logs.extend(
            line.decode("utf-8", "replace").rstrip() for line in proc.stderr), daemon=True).start()
        def send(action, **kwargs):
            data = json.dumps({"action": action, **kwargs}).encode()
            proc.stdin.write(struct.pack("<I", len(data)) + data)
            proc.stdin.flush()
        def wait_status(predicate, timeout=15):
            deadline = time.monotonic() + timeout
            while time.monotonic() < deadline and proc.poll() is None:
                send("getStatus")
                time.sleep(0.3)
                states = [r for r in responses if r.get("type") == "status" and "currentTime" in r]
                if states and predicate(states[-1]):
                    return states[-1]
            raise AssertionError(f"Playback state did not arrive: {responses[-8:]}\n{logs[-15:]}")
        try:
            send("open", url=f"http://127.0.0.1:{server.server_port}/index.html",
                 site="movie", title="Cross-origin iframe test", width=640, height=360)
            time.sleep(2)
            send("play")
            playing = wait_status(lambda s: s["isPlaying"] and s["currentTime"] > 0.4)
            send("toggleAIDub")
            paused = wait_status(lambda s: not s["isPlaying"])
            time.sleep(1)
            still_paused = wait_status(lambda s: not s["isPlaying"])
            assert still_paused["currentTime"] - paused["currentTime"] < 0.3, (
                "Offline Dub failed to pause the iframe video", paused, still_paused)
            send("toggleAIDub")
            resumed = wait_status(lambda s: s["isPlaying"] and
                s["currentTime"] > still_paused["currentTime"] + 0.5)
            print("embedded-media-e2e: passed", playing["currentTime"],
                  paused["currentTime"], resumed["currentTime"])
        finally:
            proc.stdin.close()
            try:
                proc.wait(timeout=3)
            except subprocess.TimeoutExpired:
                proc.terminate()
                proc.wait(timeout=3)
            server.shutdown()


if __name__ == "__main__":
    run()
