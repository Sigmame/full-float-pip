import Foundation

/// How the episode length was measured.
///
/// This is the difference between "the film is 45 minutes" and "the player has
/// buffered 6 minutes ahead". Both arrive as a `Double` called `dur`, and the
/// old code treated them as the same number: it placed the end-credits window
/// at `dur - 180` regardless. With a buffered-window length that lands in the
/// middle of the story, so auto-next either fires minutes before the credits or
/// (when the window under-reports badly) never fires at all.
///
/// Only a length the player *knows* can place the credits. A `seekable` end is
/// a moving buffer edge — for a live stream it is the DVR window, which is
/// never an episode length — so it is not allowed to place the window.
enum EpisodeDurationSource: String {
    /// `HTMLMediaElement.duration`, a finite file length.
    case media
    /// The provider's own player (`getDuration`, a jwplayer playlist item, or a
    /// site script reporting its state). It publishes the episode length.
    case clock
    /// `seekable.end()`, kept only as a label for the progress bar.
    case seekable
    /// Nothing usable was reported.
    case unknown

    /// Whether this number is an episode length the credits can be measured
    /// from.
    var placesOutro: Bool {
        switch self {
        case .media, .clock: return true
        case .seekable, .unknown: return false
        }
    }
}

enum WatchAssistAction: Equatable {
    case none
    case skipIntro(to: Double)
    case advanceToNextEpisode
}

/// Why the assist did (or did not) act. Logged on every change, so one real
/// credits roll says which of these it was instead of nothing at all.
enum WatchAssistReason: String {
    case suppressed = "suppressed (page we just left)"
    case noMovie = "not a movie session"
    case notPlaying = "not playing"
    case noDuration = "no usable duration"

    case introDisabled = "intro skip off"
    case introSeekedByViewer = "viewer seeked"
    case introDone = "intro already handled"
    case introTooShort = "too short for an intro"
    case introSkipped = "skipped intro"
    case introPassed = "intro passed"

    case nextDisabled = "auto-next off"
    case noPlaylist = "no playlist to advance to"
    case alreadyAdvanced = "already advanced this episode"
    case tooEarly = "less than half the episode watched"
    case outroWindowUntrusted = "no real episode length to place the credits"
    case tooShortForOutro = "too short for credits"
    case midEpisode = "mid episode"
    case outroSkipped = "skipped end credits"
    case fileEnded = "file ended"
}

struct WatchAssistSample {
    var hasMovie: Bool
    var ct: Double
    var dur: Double
    var durSource: EpisodeDurationSource
    /// Resolved by the caller: the remembered intro end for this slug, or the
    /// default, capped by the episode length.
    var introEnd: Double
    var paused: Bool
    var ended: Bool
    /// The viewer scrubbed, or is scrubbing right now.
    var userSeeked: Bool
    /// The page we just left still reports "at the credits" for a moment.
    var suppress: Bool
    var autoSkipIntro: Bool
    var autoNext: Bool
    var hasPlaylist: Bool
    var didSkipIntro: Bool
    var didAdvance: Bool
}

struct WatchAssistDecision {
    var action: WatchAssistAction = .none
    var reason: WatchAssistReason = .midEpisode
    /// The intro is behind us for this episode and must not be looked at again.
    var introPassed = false
}

/// Decides what the watch assist should do with one playback sample.
///
/// Apart from the duration-source rule above, the behaviour is the one the app
/// already shipped, kept literal so the log can be compared with the old
/// numbers: skip the intro once per episode at `ct >= 0.8` for anything long
/// enough to have one, and only ever advance after half the episode has been
/// watched.
///
/// Deliberately pure — no AppKit, no web view, no I/O — so every branch can be
/// exercised with real timeline numbers by `tests/watch-assist/main.swift`.
enum WatchAssist {
    /// Used when this slug has never had its intro measured.
    static let defaultIntroSeconds: Double = 90
    /// Credits and "next episode" previews run about this long. If they turn
    /// out shorter, `endTolerance` still catches the real end.
    static let defaultOutroSeconds: Double = 180
    /// Below this there is no intro worth skipping (clips, teasers).
    static let minEpisodeSeconds: Double = 360
    /// How much of the episode has to be behind the viewer before an advance is
    /// considered at all.
    static let watchedFraction: Double = 0.5
    /// A player that stops at the end without ever firing `ended` still counts
    /// as finished this close to the reported length.
    static let endTolerance: Double = 15

    static func decide(_ s: WatchAssistSample) -> WatchAssistDecision {
        guard !s.suppress else { return WatchAssistDecision(reason: .suppressed) }
        guard s.hasMovie else { return WatchAssistDecision(reason: .noMovie) }
        guard !s.paused || s.ended else { return WatchAssistDecision(reason: .notPlaying) }
        guard s.dur.isFinite, s.dur > 1 else { return WatchAssistDecision(reason: .noDuration) }

        // The intro is only this sample's business until it is skipped or the
        // playhead is past it; after that the outro still has to be considered,
        // so the flag is carried into whatever comes next instead of ending the
        // decision here.
        var introPassed = false
        if let intro = decideIntro(s) {
            if intro.action != .none { return intro }
            introPassed = intro.introPassed
        }
        func carrying(_ decision: WatchAssistDecision) -> WatchAssistDecision {
            var decision = decision
            guard introPassed else { return decision }
            decision.introPassed = true
            // Nothing to do, and the sample is the first one past the intro:
            // say that rather than "less than half watched" at 20:00.
            if decision.action == .none { decision.reason = .introPassed }
            return decision
        }

        guard s.autoNext else { return carrying(WatchAssistDecision(reason: .nextDisabled)) }
        guard s.hasPlaylist else { return carrying(WatchAssistDecision(reason: .noPlaylist)) }
        guard !s.didAdvance else { return carrying(WatchAssistDecision(reason: .alreadyAdvanced)) }
        guard s.ct > max(defaultIntroSeconds + 30, s.dur * watchedFraction) else {
            return carrying(WatchAssistDecision(reason: .tooEarly))
        }
        // The element says it is over: the strongest signal there is, and it
        // does not depend on knowing the length.
        if s.ended, s.ct > 60 {
            return carrying(WatchAssistDecision(action: .advanceToNextEpisode, reason: .fileEnded))
        }
        // A player that stops a second before the end without firing `ended`.
        if s.durSource.placesOutro, s.ct >= s.dur - endTolerance {
            return carrying(WatchAssistDecision(action: .advanceToNextEpisode, reason: .fileEnded))
        }
        guard s.durSource.placesOutro else {
            return carrying(WatchAssistDecision(reason: .outroWindowUntrusted))
        }
        guard s.dur >= minEpisodeSeconds else {
            return carrying(WatchAssistDecision(reason: .tooShortForOutro))
        }
        if s.ct >= s.dur - defaultOutroSeconds {
            return carrying(WatchAssistDecision(action: .advanceToNextEpisode, reason: .outroSkipped))
        }
        return carrying(WatchAssistDecision(reason: .midEpisode))
    }

    /// Returns the intro's decision, or `nil` when the intro is not this
    /// sample's business and the outro should be considered on its own.
    private static func decideIntro(_ s: WatchAssistSample) -> WatchAssistDecision? {
        guard s.autoSkipIntro else { return nil }
        guard !s.didSkipIntro else { return nil }
        // Once the viewer scrubs, the intro is theirs to keep.
        guard !s.userSeeked else { return nil }
        guard s.dur >= minEpisodeSeconds else { return nil }
        if s.ct >= 0.8, s.ct < s.introEnd - 1 {
            return WatchAssistDecision(action: .skipIntro(to: s.introEnd), reason: .introSkipped)
        }
        if s.ct >= s.introEnd {
            return WatchAssistDecision(reason: .introPassed, introPassed: true)
        }
        return nil
    }
}
