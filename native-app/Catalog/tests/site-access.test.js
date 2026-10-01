const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const policy = require('../site-access.js');

async function run() {
    for (const domain of policy.movieDomains) {
        assert.equal(policy.allowsPage(`https://${domain}/watch`), true);
        assert.equal(policy.allowsPage(`https://player.${domain}/watch`), true);
        for (const raw of [`https://${domain}.evil.com/`, `https://evil${domain}/`,
            `https://evil.com/?next=https://${domain}`, `http://${domain}/`,
            `https://${domain}@evil.com/`, `https://evil@${domain}/`]) {
            assert.equal(policy.allowsPage(raw), false, raw);
        }
    }
    for (const raw of ['https://www.youtube.com/watch?v=x', 'https://mail.google.com/',
        'file:///private/data', 'javascript:alert(1)', 'not a URL']) {
        assert.equal(policy.allowsPage(raw), false);
    }

    // The curated YouTube films: only these exact ids, only watch / embed forms, never lookalike hosts.
    const selected = policy.youtubeMovies[0].id;
    assert.equal(policy.youtubeMovieID(`https://www.youtube.com/watch?v=${selected}`), selected);
    assert.equal(policy.youtubeMovieID(`https://www.youtube.com/embed/${selected}`), selected);
    assert.equal(policy.youtubeMovieID(`https://www.youtube-nocookie.com/embed/${selected}`), selected);
    for (const raw of [`https://www.youtube.com/watch?v=rFZHOHl-L8A`, `http://www.youtube.com/watch?v=${selected}`,
        `https://www.youtube.com.evil.com/watch?v=${selected}`, `https://evil.com/watch?v=${selected}`,
        `https://user@www.youtube.com/watch?v=${selected}`, `https://www.youtube.com:8443/watch?v=${selected}`,
        `https://www.youtube.com/shorts/${selected}`, 'https://www.youtube.com/watch', 'not a URL', '']) {
        assert.equal(policy.youtubeMovieID(raw), '', `must reject ${raw}`);
    }
    // Playback is allowed for provider pages and curated films, nothing else.
    assert.equal(policy.allowsPlayback('https://phimapi.com/phim/x'), true);
    assert.equal(policy.allowsPlayback(`https://www.youtube.com/watch?v=${selected}`), true);
    assert.equal(policy.allowsPlayback('https://www.youtube.com/watch?v=rFZHOHl-L8A'), false);
    assert.equal(policy.allowsPlayback('https://example.com/'), false);
    // The list itself is frozen and every entry has the fields the catalogue renders.
    assert(Object.isFrozen(policy.youtubeMovies) && policy.youtubeMovies.length > 0);
    for (const movie of policy.youtubeMovies) {
        assert.match(movie.id, /^[A-Za-z0-9_-]{11}$/);
        for (const field of ['name', 'year', 'cast', 'audio', 'region', 'channel', 'durationMinutes']) assert(movie[field], `${movie.id} lacks ${field}`);
    }
    // The player (Swift) and the catalogue (JS) must permit exactly the same films.
    const native = fs.readFileSync(path.join(__dirname, '../../Sources/FloatWindow.swift'), 'utf8');
    const nativeIDs = native.match(/curatedYouTubeMovieIDs: Set<String> = \[(.*?)\]/)[1].match(/[a-zA-Z0-9_-]{11}/g);
    assert.deepEqual(nativeIDs, policy.youtubeMovies.map(movie => movie.id), 'the player and the catalogue permit the same movies');
    console.log('site-access: host boundaries, the curated YouTube films, and the Swift/JS allow-lists passed');
}
run().catch(error => { console.error(error); process.exitCode = 1; });
