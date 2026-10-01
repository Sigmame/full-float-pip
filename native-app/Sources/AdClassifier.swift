import CoreGraphics
import Foundation

/// One recognized line: the text plus its normalized box (Vision convention —
/// origin at the bottom-left, size relative to the frame).
struct AdTextHit {
    let text: String
    let box: CGRect
}

/// What the frame looks like: nothing ad-like, a sponsor line, or a full-frame
/// gambling spot.
enum AdFrameKind {
    case none
    case banner
    case splash
}

/// Classifies an OCR'd frame as the `9922.com` banner or splash.
///
/// Thresholds come from the real creative this app has to handle, measured by
/// running `VNRecognizeTextRequest` over an actual capture:
///
/// * the splash paints a giant `9922` wordmark — 0.210 of the frame height at
///   native size, still 0.228 when the page downscales it to 280x158 and
///   re-encodes it as JPEG — 30-40 px wide out of a 1434 px frame, with
///   `9922,COM - NƠI CƠ HỘI BẮT ĐẦU TỪ MỘT CÚ CHẠM.` underneath;
/// * the sponsor banner is the same brand inside a long caption sentence pinned
///   to the top of the picture, so its box is wide and its line height is a
///   fraction of the wordmark's.
///
/// Both dimensions matter. The wordmark box is *tall* (>= 0.10 of the frame)
/// and *narrow* (<= 0.6); a caption sentence is short and spans most of the
/// width even when its line height happens to be large, so testing the height
/// alone would turn the banner into a splash and seek the story away.
///
/// Geometry decides which is which, on purpose. The colour signature that the
/// old heuristic looked for (the neon green ornaments) measures 0.038 of the
/// frame at native resolution but only 0.023-0.026 once downscaled to the 280,
/// 420 or 640 px the app actually samples, so it never fired. And the two
/// outcomes must stay apart: a banner is burned in for the whole episode, so
/// seeking on it would eat the story, while a splash is a spot that has to be
/// skipped. A banner is therefore blurred and a splash is skipped.
///
/// This type is deliberately pure — no AppKit, no web view, no I/O — so it can
/// be compiled and exercised on its own by `tests/ad-classifier/main.swift`.
enum AdClassifier {
    /// Diacritics stripped and lowercased, so OCR variants of the Vietnamese
    /// call to action all fold to one form.
    static func folded(_ text: String) -> String {
        text.folding(options: .diacriticInsensitive, locale: Locale(identifier: "vi"))
            .lowercased()
    }

    /// `9922`, `9 9 2 2`, `99 22`, `9922,com`, or the spelled-out form, plus common gambling sponsor domains.
    static func mentionsBrand(_ text: String) -> Bool {
        let folded = Self.folded(text)
        if folded.range(of: #"9\s*9\s*2\s*2"#, options: .regularExpression) != nil { return true }
        if folded.range(of: #"9\s*2\s*2\s*(\.|\,)?\s*com"#, options: .regularExpression) != nil { return true }
        if folded.range(of: #"w\s*2\s*2\s*(\.|\,)?\s*com"#, options: .regularExpression) != nil { return true }
        if folded.range(of: #"\b(chin|9)\s*(chin|9)\s*(hai|2)\s*(hai|2)\b"#,
                            options: .regularExpression) != nil { return true }
        if folded.range(of: #"\b(888b|okvip|bet88|kubet|shbet|new88|jun88|hi88|f8bet|789bet)\b"#, options: .regularExpression) != nil { return true }
        return false
    }

    /// The landing page's call to action, `NƠI CƠ HỘI BẮT ĐẦU TỪ MỘT CÚ CHẠM`.
    /// Deliberately narrow and requiring both halves: the sponsor banner's
    /// `tài trợ` / `nổ hũ` / `rút tiền` wording and an ordinary subtitle saying
    /// one of these words alone must not land here.
    static func mentionsLandingPage(_ text: String) -> Bool {
        let folded = Self.folded(text)
        let offer = folded.range(of: #"c[oơ]\s*h[oộ]i"#, options: .regularExpression) != nil
        let start = folded.range(of: #"b[aắ]t\s*[dđ][aầ]u"#, options: .regularExpression) != nil
        let touch = folded.contains("cu cham")
        return offer && (start || touch)
    }

    /// Checks if a text hit is in the top band of the screen (typically top 25% where sponsor banners sit)
    /// and contains gambling sponsor keywords.
    static func isTopGamblingBanner(_ hit: AdTextHit) -> Bool {
        let isTop = hit.box.midY >= 0.70 || (hit.box.origin.y + hit.box.height) >= 0.75
        guard isTop else { return false }
        let folded = Self.folded(hit.text)
        let hasSponsor = folded.contains("tai tro") || folded.contains("cong bo")
        let gamblingTerms = ["no hu", "game bai", "ban ca", "song bai", "rut tien", "the thao", "tich tac", "ca cuoc", "nha cai"]
        let matches = gamblingTerms.filter { folded.contains($0) }.count
        return (hasSponsor && matches >= 1) || matches >= 2
    }

    /// Measured: the wordmark is 0.21-0.23 tall and 0.16-0.30 wide; the widest
    /// caption line of the banner stays under 0.08 tall.
    private static let splashHeight: CGFloat = 0.10
    private static let splashWidth: CGFloat = 0.6

    static func kind(for hits: [AdTextHit]) -> AdFrameKind {
        let brand = hits.filter { mentionsBrand($0.text) }
        let landing = hits.filter { mentionsLandingPage($0.text) }
        let topBanners = hits.filter { isTopGamblingBanner($0) }

        // The wordmark drawn at caption size is a banner; drawn huge and short,
        // it is the splash. This is the case that has to be right, so it is
        // checked first.
        if brand.contains(where: { $0.box.height >= splashHeight && $0.box.width <= splashWidth }) {
            return .splash
        }
        // Brand and call to action together are the landing page.
        if !brand.isEmpty && !landing.isEmpty { return .splash }
        if !brand.isEmpty || !topBanners.isEmpty { return .banner }
        // A call to action on its own could be dialogue: not actionable.
        return .none
    }
}
