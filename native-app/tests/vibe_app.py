"""Run a throwaway copy of the app and drive it over its local API (used by the end-to-end checks).

The app runs with VIBEFLOAT_HOME pointing at a temporary folder, so it never touches your real
data, port file or token, and with VIBEFLOAT_NO_CATALOG=1, so no catalogue window opens.
"""
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import threading
import time
import urllib.parse
import urllib.request

ROOT = Path(__file__).resolve().parents[1]


class VibeApp:
    def __init__(self, binary=None, extra_env=None):
        self.binary = Path(binary) if binary else ROOT / '.build/debug/FloatVideo'
        self.extra_env = extra_env or {}
        self.logs = []
        self.process = None
        self._folder = None

    def __enter__(self):
        self._folder = tempfile.TemporaryDirectory(prefix='vibefloat-e2e-')
        base = Path(self._folder.name)
        bundle = base / 'VibeFloatTest.app/Contents'
        (bundle / 'MacOS').mkdir(parents=True)
        shutil.copy2(self.binary, bundle / 'MacOS/FloatVideo')
        shutil.copy2(ROOT / 'Support/Info.plist', bundle / 'Info.plist')
        subprocess.run(['codesign', '--force', '--sign', '-', str(bundle.parent)],
                       check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        self.home = base / 'home'
        self.home.mkdir()
        env = {**os.environ, 'VIBEFLOAT_HOME': str(self.home), 'VIBEFLOAT_NO_CATALOG': '1', **self.extra_env}
        self.process = subprocess.Popen([str(bundle / 'MacOS/FloatVideo')], env=env,
                                        stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
        threading.Thread(target=lambda: self.logs.extend(line.decode('utf-8', 'replace').rstrip()
                                                         for line in self.process.stderr), daemon=True).start()
        self._wait_for_server()
        return self

    def _wait_for_server(self, timeout=20):
        port_file, token_file = self.home / '.floatvideo_port', self.home / '.floatvideo_token'
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            if self.process.poll() is not None:
                raise RuntimeError('The app exited during start-up.\n' + '\n'.join(self.logs[-15:]))
            if port_file.is_file() and token_file.is_file() and port_file.read_text().strip() and token_file.read_text().strip():
                self.port = int(port_file.read_text().strip())
                self.token = token_file.read_text().strip()
                return
            time.sleep(.2)
        raise RuntimeError('The local API did not start.\n' + '\n'.join(self.logs[-15:]))

    def api(self, command, **params):
        # %20, not '+': the app decodes percent escapes only.
        query = urllib.parse.urlencode({k: v if isinstance(v, str) else json.dumps(v) for k, v in params.items()},
                                       quote_via=urllib.parse.quote)
        request = urllib.request.Request(f'http://127.0.0.1:{self.port}/api/{command}' + (f'?{query}' if query else ''),
                                         headers={'X-VibeFloat-Token': self.token})
        with urllib.request.urlopen(request, timeout=15) as response:
            return json.loads(response.read())

    def open_player(self, **payload):
        """Same fields the catalogue sends: url, videoSrc, embedUrl, site, title, width, height, ..."""
        result = self.api('open', payload=json.dumps(payload))
        if not result.get('success'):
            raise AssertionError('Open was refused: ' + repr(result))
        return result

    def status(self):
        return self.api('status')

    def __exit__(self, *exc):
        if self.process and self.process.poll() is None:
            self.process.terminate()
            try:
                self.process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                self.process.kill()
        self._folder.cleanup()
        return False
