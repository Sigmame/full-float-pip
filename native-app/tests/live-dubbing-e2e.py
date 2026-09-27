#!/usr/bin/env python3
"""Drive the release app against a local video and timed Vietnamese captions.

Requires macOS GUI, ffmpeg, and the Edge TTS network dependency. Does not
replace the installed app or Chrome extension.
"""

import http.server
import json
import os
from pathlib import Path
import re
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
    if not APP.exists():
        raise SystemExit("Build first: cd native-app && swift build -c release")
    if not shutil.which("ffmpeg"):
        raise SystemExit("ffmpeg is required for the local video fixture")

    with tempfile.TemporaryDirectory(prefix="vibefloat-dub-test-") as folder:
        fixture = Path(folder)
        subprocess.run([
            "ffmpeg", "-hide_banner", "-loglevel", "error", "-y",
            "-f", "lavfi", "-i", "color=c=black:s=640x360:r=24:d=13",
            "-c:v", "libx264", "-pix_fmt", "yuv420p", "-movflags", "+faststart",
            str(fixture / "video.mp4"),
        ], check=True)
        (fixture / "captions.vtt").write_text(
            "WEBVTT\n\n"
            "00:00:03.000 --> 00:00:04.000\nXin chào, đây là câu đầu tiên.\n\n"
            "00:00:04.000 --> 00:00:05.000\nCâu thứ hai nối ngay sau câu đầu.\n\n"
            "00:00:05.000 --> 00:00:07.000\nĐây là câu cuối của bài kiểm tra.\n",
            encoding="utf-8",
        )
        (fixture / "index.html").write_text(
            '<!doctype html><meta charset="utf-8"><title>Dub test</title>'
            '<video autoplay muted playsinline controls width="640" height="360">'
            '<source src="/video.mp4" type="video/mp4">'
            '<track src="/captions.vtt" kind="subtitles" srclang="vi" label="Tiếng Việt" default>'
            '</video>',
            encoding="utf-8",
        )

        handler = lambda *args, **kwargs: QuietHandler(*args, directory=folder, **kwargs)
        server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), handler)
        threading.Thread(target=server.serve_forever, daemon=True).start()
        page = f"http://127.0.0.1:{server.server_port}/index.html"

        # macOS requires the usage strings in an app bundle even when this test
        # only exercises dubbing. Running the bare SwiftPM binary triggers TCC.
        bundle = fixture / "VibeFloatTest.app" / "Contents"
        (bundle / "MacOS").mkdir(parents=True)
        shutil.copy2(APP, bundle / "MacOS" / "FloatVideo")
        shutil.copy2(ROOT / "Support" / "Info.plist", bundle / "Info.plist")
        subprocess.run(["codesign", "--force", "--sign", "-", str(bundle.parent)], check=True,
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

        env = os.environ.copy()
        env["VIBEFLOAT_DUB_DEBUG"] = "1"
        env["VIBEFLOAT_DUB_TEST"] = "1"
        proc = subprocess.Popen(
            [str(bundle / "MacOS" / "FloatVideo"), "--native-messaging"], stdin=subprocess.PIPE,
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=env,
        )
        lines = []
        responses = []
        def collect_logs():
            for raw in proc.stderr:
                line = raw.decode("utf-8", "replace").rstrip()
                lines.append(line)
                if "[AIDub]" in line or "[OfflineDub]" in line:
                    print(line, flush=True)
        threading.Thread(target=collect_logs, daemon=True).start()
        def collect_responses():
            while True:
                header = proc.stdout.read(4)
                if len(header) != 4:
                    return
                length = struct.unpack("<I", header)[0]
                payload = proc.stdout.read(length)
                if len(payload) != length:
                    return
                responses.append(json.loads(payload))
        threading.Thread(target=collect_responses, daemon=True).start()

        try:
            message = {
                "action": "open", "url": page, "site": "movie",
                "title": "Local dubbing test", "width": 640, "height": 360,
                "aiDubEnabled": False,
            }
            payload = json.dumps(message).encode()
            proc.stdin.write(struct.pack("<I", len(payload)) + payload)
            proc.stdin.flush()
            began = time.monotonic()
            deadline = began + 90
            offline_sent = False
            pause_status_sent = False
            play_sent = False
            toggled_off_after_ready = False
            toggled_on_after_ready = False
            toggled_off_at = 0.0
            reused_progress_index = None
            while time.monotonic() < deadline and proc.poll() is None:
                if not offline_sent and time.monotonic() >= began + 2:
                    offline_payload = json.dumps({"action": "toggleAIDub"}).encode()
                    proc.stdin.write(struct.pack("<I", len(offline_payload)) + offline_payload)
                    proc.stdin.flush()
                    offline_sent = True
                ready = any("Hoàn tất 100%" in line and "audio 3/3 câu" in line for line in lines)
                paused_status = [r for r in responses if r.get("type") == "status" and "progress" in r]
                if ready and paused_status and not toggled_off_after_ready:
                    off_payload = json.dumps({"action": "toggleAIDub"}).encode()
                    proc.stdin.write(struct.pack("<I", len(off_payload)) + off_payload)
                    proc.stdin.flush()
                    toggled_off_after_ready = True
                    toggled_off_at = time.monotonic()
                if toggled_off_after_ready and not toggled_on_after_ready and time.monotonic() - toggled_off_at >= 0.3:
                    on_payload = json.dumps({"action": "toggleAIDub"}).encode()
                    proc.stdin.write(struct.pack("<I", len(on_payload)) + on_payload)
                    proc.stdin.flush()
                    toggled_on_after_ready = True
                if toggled_on_after_ready and reused_progress_index is None:
                    reused_progress_index = next((i for i, line in enumerate(lines)
                        if "[OfflineDub] progress Offline Dub • Audio 3 câu đã sẵn sàng" in line), None)
                hidden_after_reenable = reused_progress_index is not None and any(
                    "[OfflineDub] progress (hidden)" in line for line in lines[reused_progress_index + 1:])
                if hidden_after_reenable and not play_sent:
                    play_payload = json.dumps({"action": "play"}).encode()
                    proc.stdin.write(struct.pack("<I", len(play_payload)) + play_payload)
                    proc.stdin.flush()
                    play_sent = True
                if offline_sent and not pause_status_sent and time.monotonic() >= began + 2.5:
                    status_payload = json.dumps({"action": "getStatus"}).encode()
                    proc.stdin.write(struct.pack("<I", len(status_payload)) + status_payload)
                    proc.stdin.flush()
                    pause_status_sent = True
                if sum("[OfflineDub] audio scheduled cue" in line for line in lines) >= 3:
                    break
                time.sleep(0.1)
            scheduled = [line for line in lines if "[OfflineDub] audio scheduled cue" in line]
            print(f"Offline scheduled cues: {len(scheduled)}")
            if len(scheduled) < 2:
                print(f"App exit code: {proc.poll()}")
                print("TTS diagnostics:\n" + "\n".join(line for line in lines if "TTS" in line or "AIDub" in line))
                print("Relevant app logs:\n" + "\n".join(lines[-30:]))
                raise AssertionError("Expected at least two offline scheduled cues")
            assert len(scheduled) >= 3, "Offline Dub should speak all adjacent timeline cues"
            paused_status = [r for r in responses if r.get("type") == "status" and "progress" in r]
            assert paused_status and paused_status[0].get("isPlaying") is False, paused_status
            progress = [line for line in lines if "[OfflineDub] progress" in line]
            assert any("đang dịch và tạo giọng (0%)" in line for line in progress), progress
            assert any("100%" in line and "audio 3/3 câu" in line for line in progress), progress
            assert reused_progress_index is not None and hidden_after_reenable, progress
            assert sum("Đã lấy 3 câu — đang dịch" in line for line in progress) == 1, progress
            print("offline-dubbing-e2e: passed")
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
