// The AI dubbing preference: whether new floating players start with offline dubbing on.
// The dubbing itself runs inside the player; this only remembers the choice and tells the page.
(function (root) {
    const KEY = 'vibe_ai_dubbing_enabled_v2';   // off until the reader turns it on
    const area = () => root.chrome && root.chrome.storage && root.chrome.storage.local;
    const announce = enabled => root.dispatchEvent(new CustomEvent('aidub-state-change', { detail: { enabled } }));

    const preference = {
        enabled: false,
        ready: null,
        toggle() { return this.set(!this.enabled); },
        set(enabled) {
            this.enabled = !!enabled;
            const storage = area();
            if (storage) storage.set({ [KEY]: this.enabled });
            announce(this.enabled);
            return this.enabled;
        },
        // The menu bar changed it: take the value without writing it back.
        adopt(enabled) {
            this.enabled = !!enabled;
            announce(this.enabled);
        }
    };

    const storage = area();
    preference.ready = storage
        ? Promise.resolve(storage.get(KEY)).then(stored => { preference.enabled = !!stored && stored[KEY] === true; }).catch(() => {})
        : Promise.resolve();
    root.aiDubbing = preference;
    if (root.chrome && root.chrome.runtime && root.chrome.runtime.onMessage) {
        root.chrome.runtime.onMessage.addListener(message => {
            if (message && message.type === 'AI_DUB_PREF') preference.adopt(message.enabled);
        });
    }
})(window);
