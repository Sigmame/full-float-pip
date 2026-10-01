#!/usr/bin/env python3
"""Verify Offline Dub releases a video inside a cross-origin iframe."""

import http.server
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import threading
import time

sys.path.insert(0, str(Path(__file__).resolve().parent))
from vibe_app import VibeApp  # noqa: E402

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

        try:
            with VibeApp(binary=APP, extra_env={"VIBEFLOAT_DUB_TEST": "1"}) as app:
                def wait_status(predicate, timeout=15):
                    deadline = time.monotonic() + timeout
                    last = None
                    while time.monotonic() < deadline:
                        last = app.status()
                        if predicate(last):
                            return last
                        time.sleep(0.3)
                    raise AssertionError(f"Playback state did not arrive: {last}\n{app.logs[-15:]}")

                app.open_player(url=f"http://127.0.0.1:{server.server_port}/index.html",
                                site="movie", title="Cross-origin iframe test", width=640, height=360)
                time.sleep(2)
                app.api("play")
                playing = wait_status(lambda s: s["isPlaying"] and s["currentTime"] > 0.4)
                app.api("aidub")
                paused = wait_status(lambda s: not s["isPlaying"])
                time.sleep(1)
                still_paused = wait_status(lambda s: not s["isPlaying"])
                assert still_paused["currentTime"] - paused["currentTime"] < 0.3, (
                    "Offline Dub failed to pause the iframe video", paused, still_paused)
                app.api("aidub")
                resumed = wait_status(lambda s: s["isPlaying"] and
                    s["currentTime"] > still_paused["currentTime"] + 0.5)
                print("embedded-media-e2e: passed", playing["currentTime"],
                      paused["currentTime"], resumed["currentTime"])
        finally:
            server.shutdown()

if __name__ == "__main__":
    run()
