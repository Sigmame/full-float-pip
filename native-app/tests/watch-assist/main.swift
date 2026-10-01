// Unit test for WatchAssist, run natively because the window class that feeds
// it needs AppKit and a running app (the policy itself is deliberately pure).
//
// The timeline numbers below are a VN drama episode: 45 minutes, a 90 second
// intro, credits in the last three minutes. They are the numbers the shipped
// rules were written for, so a change here is a change to real behaviour.
//
// `durSrc` matters as much as `dur`, and that is the bug this file pins down:
// the old code compared `ct` against `dur - 180` whatever `dur` was. When the
// player only reported a buffered window (or a live DVR edge), "the last three
// minutes" landed in the middle of the story, or nowhere at all.

import Foundation

var failures = 0
func check(_ condition: Bool, _ label: String) {
    if condition {
        print("  ok   \(label)")
    } else {
        failures += 1
        print("  FAIL \(label)")
    }
}

let episode: Double = 2700        // 45:00
let intro: Double = 90

/// A mid-episode sample with everything switched on, so each test only spoils
/// the one field it is about.
func sample(ct: Double = 1200,
            dur: Double = episode,
            durSrc: EpisodeDurationSource = .media,
            introEnd: Double = intro,
            paused: Bool = false,
            ended: Bool = false,
            userSeeked: Bool = false,
            suppress: Bool = false,
            autoSkipIntro: Bool = true,
            autoNext: Bool = true,
            hasPlaylist: Bool = true,
            hasMovie: Bool = true,
            // By the time the credits are on screen the intro was handled long
            // ago, so this is the realistic default; the intro cases below ask
            // for the other one explicitly.
            didSkipIntro: Bool = true,
            didAdvance: Bool = false) -> WatchAssistSample {
    WatchAssistSample(hasMovie: hasMovie, ct: ct, dur: dur, durSource: durSrc,
                      introEnd: introEnd, paused: paused, ended: ended,
                      userSeeked: userSeeked, suppress: suppress,
                      autoSkipIntro: autoSkipIntro, autoNext: autoNext,
                      hasPlaylist: hasPlaylist, didSkipIntro: didSkipIntro,
                      didAdvance: didAdvance)
}

func decision(_ s: WatchAssistSample) -> WatchAssistDecision { WatchAssist.decide(s) }

print("watch assist; 45 minute episode, 90s intro, credits in the last 3 minutes")

// 1. Mid episode: nothing to do, and the reason says so.
let mid = decision(sample(ct: 1500))
check(mid.action == .none && mid.reason == .midEpisode, "25:00 into a 45:00 episode is mid episode")

// 1b. Before half the episode has played nothing may advance, however close to
//     the reported end the numbers look.
let halfWay = decision(sample(ct: 1200))
check(halfWay.action == .none && halfWay.reason == .tooEarly, "20:00 is not far enough to advance")

// 2. The credits window fires on a real file length. 42:00 is exactly
//    45:00 - 3:00, the first sample the shipped rule acted on.
let credits = decision(sample(ct: 2520))
check(credits.action == .advanceToNextEpisode && credits.reason == .outroSkipped,
      "42:00 of 45:00 skips the credits")

// 3. One second earlier is still the story.
let before = decision(sample(ct: 2519))
check(before.action == .none && before.reason == .midEpisode, "41:59 is left alone")

// 4. A player that stops a second before the reported end without ever firing
//    `ended` still counts as finished.
let stopped = decision(sample(ct: 2692))
check(stopped.action == .advanceToNextEpisode && stopped.reason == .fileEnded,
      "a stalled player near the reported end still advances")

// 5. The element's own end is the strongest signal, and needs no length.
let ended = decision(sample(ct: 2690, ended: true))
check(ended.action == .advanceToNextEpisode && ended.reason == .fileEnded, "ended advances")

// 6. An ad's own `ended` early in the episode must never advance the episode.
let preroll = decision(sample(ct: 30, ended: true, didSkipIntro: true))
check(preroll.action == .none && preroll.reason == .tooEarly, "an early 'ended' is not the episode")

// 7. THE BUG: with only a buffered window for a length, the old code advanced at
//    `ct >= dur - 180` on a number that is not an episode length. 42:00 into the
//    story is not the credits, so this must do nothing.
let buffered = decision(sample(ct: 2520, dur: 2700, durSrc: .seekable))
check(buffered.action == .none && buffered.reason == .outroWindowUntrusted,
      "a buffered window does not place the credits")

// 8. The same buffered window at the very end of a live stream (a DVR edge that
//    is always a couple of seconds ahead of the playhead) must not advance
//    either — this is the case that fired on every poll once.
let live = decision(sample(ct: 7190, dur: 7200, durSrc: .seekable, hasPlaylist: true))
check(live.action == .none && live.reason == .outroWindowUntrusted,
      "a live DVR edge never advances the episode")

// 9. But the end still works there: the file ending is not a guess.
let liveEnded = decision(sample(ct: 7199, dur: 7200, durSrc: .seekable, ended: true))
check(liveEnded.action == .advanceToNextEpisode && liveEnded.reason == .fileEnded,
      "the end of a buffered-length stream still advances")

// 10. The provider's own length is trusted, like the file's.
let providerClock = decision(sample(ct: 2520, durSrc: .clock))
check(providerClock.action == .advanceToNextEpisode, "the provider's own length places the credits")

// 11. Intro: a fresh episode inside the intro skips to the remembered end.
let introSkip = decision(sample(ct: 5, didSkipIntro: false))
check(introSkip.action == .skipIntro(to: 90), "5s in skips the intro to 90s")

// 12. The per-slug remembered intro wins over the default.
let remembered = decision(sample(ct: 5, introEnd: 45, didSkipIntro: false))
check(remembered.action == .skipIntro(to: 45), "a remembered 45s intro is used")

// 13. Past the intro it is marked handled, so the intro is not revisited after
//     a deliberate rewind, and nothing else happens at 10:00.
let passed = decision(sample(ct: 600, introEnd: 90, didSkipIntro: false))
check(passed.action == .none && passed.introPassed && passed.reason == .introPassed,
      "past the intro it is marked handled")

// 14. Once handled, a rewind into the intro is the viewer's business.
let rewound = decision(sample(ct: 20, didSkipIntro: true))
check(rewound.action == .none && !rewound.introPassed, "a rewind after the intro is not re-skipped")

// 15. A manual seek cancels the intro skip without advancing the episode.
let seeked = decision(sample(ct: 20, userSeeked: true, didSkipIntro: false))
check(seeked.action == .none, "a viewer seek cancels the intro skip")

// 16. Too short to have an intro: clips and teasers are left alone.
let clip = decision(sample(ct: 5, dur: 300, durSrc: .media, didSkipIntro: false))
check(clip.action == .none && clip.reason == .tooEarly, "a 5 minute clip has no intro to skip")

// 17. A short clip still advances at its real end.
let clipEnd = decision(sample(ct: 295, dur: 300, durSrc: .media))
check(clipEnd.action == .advanceToNextEpisode && clipEnd.reason == .fileEnded,
      "a short clip advances at its real end")

// 18. The intro is decided before the outro, so a first sample cannot advance
//     an episode that has not started.
let firstSample = decision(sample(ct: 0.5, ended: true, didSkipIntro: true))
check(firstSample.action == .none, "0.5s in never advances")

// 19. Guards: a page we just left, a non-movie session, a paused player and a
//     duration that never resolved.
check(decision(sample(ct: 2520, suppress: true)).reason == .suppressed,
      "the page we just left is suppressed")
check(decision(sample(ct: 2520, hasMovie: false)).reason == .noMovie,
      "a non-movie session is not assisted")
check(decision(sample(ct: 2520, paused: true)).reason == .notPlaying,
      "a paused player is left alone")
check(decision(sample(ct: 2520, paused: true, ended: true)).action == .advanceToNextEpisode,
      "a paused player at its end still advances")
check(decision(sample(ct: 2520, dur: .infinity)).reason == .noDuration,
      "an infinite duration is not a length")
check(decision(sample(ct: 2520, durSrc: .unknown)).reason == .outroWindowUntrusted,
      "an unknown duration does not place the credits")

// 20. Switches and playlist state, which the user toggles from the strip.
check(decision(sample(ct: 2520, autoNext: false)).reason == .nextDisabled,
      "auto-next off does not advance")
check(decision(sample(ct: 2520, hasPlaylist: false)).reason == .noPlaylist,
      "a single episode has nowhere to advance to")
check(decision(sample(ct: 2520, didAdvance: true)).reason == .alreadyAdvanced,
      "an episode is advanced once")
check(decision(sample(ct: 5, autoSkipIntro: false, didSkipIntro: false)).action == .none,
      "auto-skip-intro off does not seek")

if failures > 0 {
    print("watch assist: \(failures) check(s) failed")
    exit(1)
}
print("watch assist scenarios passed")
