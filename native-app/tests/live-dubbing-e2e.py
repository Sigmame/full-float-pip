#!/usr/bin/env python3
"""Drive the release app against a local video and timed Vietnamese captions.

Requires macOS GUI, ffmpeg, and the Edge TTS network dependency. Does not
replace the installed app.
"""

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

        try:
            with VibeApp(binary=APP, extra_env={"VIBEFLOAT_DUB_DEBUG": "1", "VIBEFLOAT_DUB_TEST": "1"}) as app:
                lines = app.logs          # stderr lines, appended by a reader thread
                printed = 0
                statuses = []             # every status reply, oldest first

                def check_status():
                    statuses.append(app.status())

                app.open_player(url=page, site="movie", title="Local dubbing test",
                                width=640, height=360, aiDubEnabled=False)
                began = time.monotonic()
                deadline = began + 90
                offline_sent = False
                pause_status_sent = False
                play_sent = False
                toggled_off_after_ready = False
                toggled_on_after_ready = False
                toggled_off_at = 0.0
                last_off_status_at = 0.0
                off_status_index = 0
                resumed_after_off = False
                reused_progress_index = None
                hidden_after_reenable = False
                while time.monotonic() < deadline and app.process.poll() is None:
                    for line in list(lines[printed:]):
                        if "[AIDub]" in line or "[OfflineDub]" in line:
                            print(line, flush=True)
                    printed = len(lines)
                    if not offline_sent and time.monotonic() >= began + 2:
                        app.api("aidub")
                        offline_sent = True
                    ready = any("Hoàn tất 100%" in line and "audio 3/3 câu" in line for line in lines)
                    if ready and statuses and not toggled_off_after_ready:
                        app.api("aidub")
                        toggled_off_after_ready = True
                        toggled_off_at = time.monotonic()
                        off_status_index = len(statuses)
                    if (toggled_off_after_ready and not resumed_after_off and
                            time.monotonic() - toggled_off_at >= 1.3 and
                            time.monotonic() - last_off_status_at >= 0.8):
                        check_status()
                        last_off_status_at = time.monotonic()
                    if last_off_status_at and not resumed_after_off:
                        resumed_after_off = any(
                            r.get("isPlaying") is True and
                            r.get("currentTime", 0) > statuses[0].get("currentTime", 0) + 0.4
                            for r in statuses[off_status_index:]
                        )
                    if resumed_after_off and not toggled_on_after_ready:
                        app.api("aidub")
                        toggled_on_after_ready = True
                    if toggled_on_after_ready and reused_progress_index is None:
                        reused_progress_index = next((i for i, line in enumerate(lines)
                            if "[OfflineDub] progress Offline Dub • Audio 3 câu đã sẵn sàng" in line), None)
                    hidden_after_reenable = reused_progress_index is not None and any(
                        "[OfflineDub] progress (hidden)" in line for line in lines[reused_progress_index + 1:])
                    if hidden_after_reenable and not play_sent:
                        app.api("play")
                        play_sent = True
                    if offline_sent and not pause_status_sent and time.monotonic() >= began + 2.5:
                        check_status()
                        pause_status_sent = True
                    if sum("[OfflineDub] audio scheduled cue" in line for line in lines) >= 3:
                        break
                    time.sleep(0.1)
                scheduled = [line for line in lines if "[OfflineDub] audio scheduled cue" in line]
                print(f"Offline scheduled cues: {len(scheduled)}")
                if len(scheduled) < 2:
                    print(f"App exit code: {app.process.poll()}")
                    print("TTS diagnostics:\n" + "\n".join(line for line in lines if "TTS" in line or "AIDub" in line))
                    print("Relevant app logs:\n" + "\n".join(lines[-30:]))
                    raise AssertionError("Expected at least two offline scheduled cues")
                assert len(scheduled) >= 3, "Offline Dub should speak all adjacent timeline cues"
                assert statuses and statuses[0].get("isPlaying") is False, statuses
                assert resumed_after_off, "Video must resume after Offline Dub is switched off"
                progress = [line for line in lines if "[OfflineDub] progress" in line]
                assert any("đang dịch và tạo giọng (0%)" in line for line in progress), progress
                assert any("100%" in line and "audio 3/3 câu" in line for line in progress), progress
                assert reused_progress_index is not None and hidden_after_reenable, progress
                assert sum("Đã lấy 3 câu — đang dịch" in line for line in progress) == 1, progress
                print("offline-dubbing-e2e: passed")
        finally:
            server.shutdown()


if __name__ == "__main__":
    run()
