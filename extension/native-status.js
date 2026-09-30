// Shared Native Companion status button + inline help, used by popup and catalog.
(function (root) {
    const INSTALL_COMMAND = './scripts/install.sh';

    function init({ onResult } = {}) {
        const statusEl = document.getElementById('native-status');
        if (!statusEl) return null;
        const help = document.getElementById('native-help');
        const msg = document.getElementById('native-help-msg');
        const retryBtn = document.getElementById('native-help-retry');

        function toggleHelp(open) {
            if (!help) return;
            help.hidden = !open;
            statusEl.setAttribute('aria-expanded', open ? 'true' : 'false');
        }

        function setStatus(connected) {
            statusEl.classList.remove('status-unknown', 'status-ready', 'status-disconnected');
            statusEl.disabled = connected;
            const text = statusEl.querySelector('.status-text');
            if (connected) {
                statusEl.classList.add('status-ready');
                if (text) text.textContent = 'Native: Sẵn sàng';
                statusEl.title = 'Native Companion App đã kết nối và sẵn sàng phát nổi.';
                toggleHelp(false);
            } else {
                statusEl.classList.add('status-disconnected');
                if (text) text.textContent = 'Chưa kết nối · Sửa';
                statusEl.title = 'Chưa kết nối macOS App. Bấm để xem cách kết nối.';
            }
        }

        async function check() {
            let res = null;
            try {
                res = await chrome.runtime.sendMessage({ type: 'GET_NATIVE_STATUS' });
            } catch {}
            const ok = Boolean(res && res.success);
            setStatus(ok);
            if (res && onResult) onResult(res);
            return ok;
        }

        statusEl.addEventListener('click', () => {
            if (statusEl.classList.contains('status-disconnected')) toggleHelp(help?.hidden !== false);
        });

        document.getElementById('native-help-copy')?.addEventListener('click', async () => {
            try {
                await navigator.clipboard.writeText(INSTALL_COMMAND);
                if (msg) msg.textContent = 'Đã sao chép lệnh.';
            } catch {
                if (msg) msg.textContent = 'Không sao chép được. Hãy chọn và sao chép lệnh thủ công.';
            }
        });

        retryBtn?.addEventListener('click', async () => {
            retryBtn.disabled = true;
            if (msg) msg.textContent = 'Đang kiểm tra kết nối…';
            const ok = await check();
            if (msg && !ok) msg.textContent = 'Vẫn chưa kết nối. Hãy chạy lệnh cài đặt và tải lại tiện ích.';
            retryBtn.disabled = false;
        });

        chrome.runtime.onMessage.addListener((m) => {
            if (m?.type === 'NATIVE_STATUS_BROADCAST' && typeof m.connected === 'boolean') setStatus(m.connected);
        });

        return { check };
    }

    root.NativeStatus = { init };
})(typeof window !== 'undefined' ? window : globalThis);
