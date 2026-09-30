const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const path = require('node:path');
const policy = require('../site-access.js');
const storage = {};
const context = vm.createContext({
    VibeSiteAccess: policy, console, URL, Date,
    chrome: { storage: { local: {
        async get(key) { return { [key]: storage[key] }; },
        async set(value) { Object.assign(storage, value); }
    } } }
});
vm.runInContext(fs.readFileSync(path.join(__dirname, '../movie-service.js'), 'utf8') + '\nthis.service = MovieService;', context);

async function run() {
    const service = context.service;
    let calls = 0;
    service._getKKPhimList = async category => {
        calls++;
        if (category === 'le') throw new Error('provider down');
        return [{ slug: 'same-movie', name: 'Movie', source: 'kkphim', year: 2026, rating: 8 }];
    };
    service._getNguonCList = async () => [{ slug: 'another-movie', name: 'Another', source: 'nguonc', rating: 9 }];
    let result = await service.getPopupHotMovies();
    assert.equal(result.stale, false);
    assert.equal(result.items.length, 2, 'deduplicate overlapping movie pools');
    assert.equal(result.items[0].slug, 'another-movie', 'rank by available rating');
    await service.getPopupHotMovies();
    assert.equal(calls, 6, 'refresh provider data every time, including with a saved list');
    service._getKKPhimList = service._getNguonCList = async () => { throw new Error('offline'); };
    result = await service.getPopupHotMovies();
    assert.equal(result.stale, true);
    assert.equal(result.items.length, 2, 'keep last good list when providers fail');
    delete storage.vibe_popup_hot_movies;
    assert.equal((await service.getPopupHotMovies()).items.length, 0, 'empty first-run failure stays empty');
    const selectedSources = [];
    service._getKKPhimList = async category => { selectedSources.push(`kk:${category}`); return []; };
    service._getNguonCList = async category => { selectedSources.push(`nguonc:${category}`); return []; };
    await service.getPopupHotMovies(8, 'nguonc');
    assert.deepEqual(selectedSources, ['nguonc:moi'], 'respect the selected movie provider');
    selectedSources.length = 0;
    await service.getPopupHotMovies(8, 'thuyetminh');
    assert.deepEqual(selectedSources, ['kk:thuyetminh'], 'respect the selected audio catalogue');
    for (const movie of service.getYouTubeMovies()) {
        assert.equal(policy.allowsPage(movie.url), false, 'never grant inspection of YouTube pages');
        assert.equal(policy.allowsPlayback(movie.url), true);
        const payload = service.buildYouTubeMovieFloatInfo(movie);
        assert.equal(policy.youtubeMovieID(payload.embedUrl), movie.id);
        assert.equal(payload.preferEmbed, true);
        assert.equal(payload.focusSession, false);
        assert.equal(payload.aiDubEnabled, false);
    }
    const hkMovies = service.getYouTubeMovies('', 'hongkong');
    assert.ok(hkMovies.length >= 5, 'offer a useful Hong Kong cast selection');
    assert.ok(hkMovies.every(movie => movie.hongKongCast));
    assert.equal(service.getYouTubeMovies('ngo tran vu')[0].id, '4bjvj11fdV4', 'search Vietnamese cast without accents');
    assert.equal(service.getYouTubeMovies('目中无人2')[0].id, 'Z40GTe-gsNo', 'search original titles');
    assert.ok(service.getYouTubeMovies('', 'vietnamese').every(movie => movie.audio.includes('Việt')));
    assert.equal(service.getYouTubeMovies('khong-co-phim-nay').length, 0);
    for (const id of ['kf-zU-Y1vLc', '30iZ-gLFU3A', '12YtcfVWdY4']) {
        assert.equal(policy.allowsPlayback(`https://www.youtube.com/watch?v=${id}`), false, 'retired movies cannot return through stored links');
        assert.throws(() => service.buildYouTubeMovieFloatInfo({ id }));
    }
    for (const url of ['https://www.youtube.com/watch?v=rFZHOHl-L8A',
        'https://evil.com/watch?v=erso59uFW-0', 'https://www.youtube.com/embed/erso59uFW-0/other',
        'https://www.youtube.com/results?search_query=phim', 'https://www.youtube.com/@channel']) {
        assert.equal(policy.allowsPlayback(url), false, url);
    }
    assert.throws(() => service.buildYouTubeMovieFloatInfo({ id: 'rFZHOHl-L8A' }));
    const native = fs.readFileSync(path.join(__dirname, '../../native-app/Sources/FloatWindow.swift'), 'utf8');
    const nativeIDs = native.match(/curatedYouTubeMovieIDs: Set<String> = \[(.*?)\]/)[1].match(/[a-zA-Z0-9_-]{11}/g);
    assert.deepEqual(nativeIDs, policy.youtubeMovies.map(movie => movie.id), 'native and extension permit the same movies');
    console.log('popup-hot: fresh fetch, ranking, deduplication, offline cache, and curated YouTube scope passed');
}
run().catch(error => { console.error(error); process.exitCode = 1; });
