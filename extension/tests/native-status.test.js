const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

function el(extra = {}) {
    const classes = new Set(); const attrs = {}; const events = {};
    return Object.assign({
        hidden: false, disabled: false, title: '', textContent: '', events, attrs, classes,
        classList: { add: (...c) => c.forEach(x => classes.add(x)), remove: (...c) => c.forEach(x => classes.delete(x)), contains: c => classes.has(c) },
        setAttribute(k, v) { attrs[k] = v; },
        querySelector() { return text; },
        addEventListener(t, cb) { events[t] = cb; }
    }, extra);
}
const text = { textContent: '' };

async function run(response, options = {}) {
    const nodes = {
        'native-status': el({ disabled: true }), 'native-help': el({ hidden: true }),
        'native-help-msg': el(), 'native-help-retry': el(), 'native-help-copy': el()
    };
    let copied = null, listener = null, current = response;
    const context = vm.createContext({
        document: { getElementById: id => nodes[id] },
        navigator: { clipboard: { async writeText(v) { if (options.copyFails) throw new Error('no'); copied = v; } } },
        chrome: { runtime: { async sendMessage() { if (current instanceof Error) throw current; return current; },
            onMessage: { addListener(cb) { listener = cb; } } } }
    });
    vm.runInContext(fs.readFileSync(path.join(__dirname, '../native-status.js'), 'utf8'), context);
    const seen = [];
    const api = context.NativeStatus.init({ onResult: r => seen.push(r) });
    return { nodes, api, text, seen, get copied() { return copied; }, listener: () => listener, set: v => { current = v; } };
}

(async () => {
    // Disconnected: help opens on click, retry reconnects and closes it.
    let t = await run({ success: false, isGhost: true });
    assert.equal(await t.api.check(), false);
    assert(t.nodes['native-status'].classes.has('status-disconnected'));
    assert.equal(t.nodes['native-status'].disabled, false);
    assert.equal(text.textContent, 'Chưa kết nối · Sửa');
    assert.deepEqual(t.seen, [{ success: false, isGhost: true }], 'onResult receives the native answer');
    t.nodes['native-status'].events.click();
    assert.equal(t.nodes['native-help'].hidden, false);
    assert.equal(t.nodes['native-status'].attrs['aria-expanded'], 'true');
    t.nodes['native-help-copy'].events.click(); await Promise.resolve();
    await t.nodes['native-help-copy'].events.click();
    assert.equal(t.copied, './scripts/install.sh');
    await t.nodes['native-help-retry'].events.click();
    assert.match(t.nodes['native-help-msg'].textContent, /Vẫn chưa kết nối/);
    assert.equal(t.nodes['native-help-retry'].disabled, false, 'Retry re-enables after checking');
    t.set({ success: true });
    await t.nodes['native-help-retry'].events.click();
    assert.equal(t.nodes['native-help'].hidden, true);
    assert(t.nodes['native-status'].classes.has('status-ready'));
    assert.equal(t.nodes['native-status'].disabled, true);

    // Errors count as disconnected; broadcast updates the state; clipboard failure is reported.
    t = await run(new Error('no port'), { copyFails: true });
    assert.equal(await t.api.check(), false);
    await t.nodes['native-help-copy'].events.click();
    assert.match(t.nodes['native-help-msg'].textContent, /Không sao chép/);
    t.listener()({ type: 'NATIVE_STATUS_BROADCAST', connected: true });
    assert(t.nodes['native-status'].classes.has('status-ready'));
    console.log('native-status: disconnect help, retry, copy, error and broadcast paths passed');
})().catch(e => { console.error(e); process.exitCode = 1; });
