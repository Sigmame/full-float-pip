const assert = require('node:assert/strict');
const AIDubbingEngine = require('../ai-dubbing.js');

const tick = () => new Promise(resolve => setImmediate(resolve));
const deferred = () => {
    let resolve;
    const promise = new Promise(done => { resolve = done; });
    return { promise, resolve };
};

async function run() {
    const engine = new AIDubbingEngine();
    assert.equal(engine.enabled, false, 'dubbing defaults to off');
    engine.enabled = true;
    const video = { currentTime: 2, paused: false, seeking: false, textTracks: [] };
    engine.targetVideo = video;
    const spoken = [];
    engine.speak = text => spoken.push(text);
    engine.prefetchBatch = () => {};
    engine.timelineCues = [{ start: 1, end: 4, text: 'Hello there', spoken: false }];

    const first = deferred();
    engine.translateToVi = () => first.promise;
    engine.checkTimeline();
    assert.deepEqual(spoken, [], 'do not speak untranslated text while translation is pending');
    video.currentTime = 5;
    first.resolve('Xin chào');
    await tick();
    assert.deepEqual(spoken, [], 'discard a translation that missed its cue');

    video.currentTime = 2;
    const second = deferred();
    engine.translateToVi = () => second.promise;
    engine.timelineCues = [{ start: 1, end: 4, text: 'Good morning', spoken: false }];
    engine.checkTimeline();
    engine.onVideoSeeking();
    second.resolve('Chào buổi sáng');
    await tick();
    assert.deepEqual(spoken, [], 'seeking invalidates in-flight translation');

    video.seeking = false;
    video.currentTime = 2;
    engine.timelineCues = [{ start: 1, end: 4, text: 'See you', viText: 'Hẹn gặp lại', spoken: false }];
    engine.checkTimeline();
    await tick();
    assert.deepEqual(spoken, ['Hẹn gặp lại'], 'current cue speaks once when ready');
    engine.checkTimeline();
    await tick();
    assert.equal(spoken.length, 1);

    const english = { kind: 'subtitles', language: 'en', mode: 'disabled' };
    const vietnamese = { kind: 'subtitles', language: 'vi', mode: 'disabled' };
    const other = { kind: 'metadata', language: 'en', mode: 'disabled' };
    const selected = engine.selectedTextTrack({ textTracks: [other, english, vietnamese] });
    assert.equal(selected, vietnamese);
    assert.equal(vietnamese.mode, 'hidden');
    assert.equal(english.mode, 'disabled', 'do not activate multiple subtitle languages');

    const batches = [];
    engine.prefetchBatch = texts => batches.push(texts);
    engine.timelineCues = Array.from({ length: 20 }, (_, index) => ({
        start: index + 1, end: index + 1.8, text: `Line ${index + 1}`, prefetched: false
    }));
    video.currentTime = 0;
    engine.pollChunkAhead(video);
    await tick();
    assert.deepEqual(batches.flat(), engine.timelineCues.slice(0, 8).map(cue => cue.text),
        'only the nearest eight cues should occupy prefetch capacity');

    console.log('ai-dubbing-sync: 6 scenarios passed');
}

run().catch(error => { console.error(error); process.exitCode = 1; });
