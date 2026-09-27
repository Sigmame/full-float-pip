// Unit test for AdClassifier, run natively because the classifier reads OCR
// output and the window class that calls it needs AppKit and a running app.
//
// Every fixture is a real measurement: the strings and boxes below are what
// `VNRecognizeTextRequest` actually returned for the two `9922.com` frames this
// app has been reported against. Run with `tests/run.sh`.

import CoreGraphics
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

/// Boxes are normalized to the frame with a bottom-left origin, exactly as
/// Vision reports them.
func hit(_ text: String, height: Double, width: Double, midY: Double) -> AdTextHit {
    AdTextHit(text: text,
              box: CGRect(x: 0.1, y: midY - height / 2, width: width, height: height))
}

print("ad classifier; measured frames")

// 1. The splash as the page's own 280x158 JPEG gives it to the accurate pass.
//    This is the reading the direct-video path never looked at, because it used
//    the fast pass, which returns nothing usable.
let splashSample = [hit("9922", height: 0.228, width: 0.156, midY: 0.544)]
check(AdClassifier.kind(for: splashSample) == .splash, "280x158 accurate OCR reads the splash")

// 2. The same sample through the fast pass: a single useless box. Nothing to
//    act on, which is why the fast OCR path silently missed the ad forever.
let fastSample = [hit("in", height: 0.633, width: 0.10, midY: 0.671)]
check(AdClassifier.kind(for: fastSample) == .none, "280x158 fast OCR yields no ad signal")

// 3. The splash at native size: huge wordmark plus the landing-page line, with
//    the window title also on screen.
let splashNative = [
    hit("Phù Sa - Tập 23", height: 0.035, width: 0.20, midY: 0.975),
    hit("9922", height: 0.210, width: 0.300, midY: 0.544),
    hit("9922,COM - NƠI CƠ HỘI BẮT ĐẦU TỪ MỘT CÚ CHẠM.", height: 0.066, width: 0.845, midY: 0.075),
]
check(AdClassifier.kind(for: splashNative) == .splash, "native-size splash is a splash")

// 4. The sponsor banner, exactly as measured (0.044-0.056 tall, 0.70 wide, high
//    up the frame). This is the frame that must never be skipped, or every
//    episode seeks itself away.
let banner = [
    hit("Bộ phim này do : 9922.com tài trợ và công bố. Sản phẩm: Nổ Hũ, Game Bài",
        height: 0.048, width: 0.704, midY: 0.92),
    hit("VNgo Bắn Cá, Sòng Bài, Thể Thao. Rút tiền 24/7 nhận tiền trong tích tắc",
        height: 0.056, width: 0.702, midY: 0.87),
]
check(AdClassifier.kind(for: banner) == .banner, "the measured sponsor banner is a banner, not a splash")

// 5. Boundary: if the recognizer merged both banner lines into one box, the box
//    can get as tall as the splash wordmark. It is still a banner, because a
//    caption sentence spans the width and the wordmark does not.
let mergedBanner = [hit("Bộ phim này do : 9922.com tài trợ và công bố. Sản phẩm: Nổ Hũ, Game Bài Bắn Cá, Sòng Bài, Thể Thao. Rút tiền 24/7 nhận tiền trong tích tắc",
                        height: 0.11, width: 0.70, midY: 0.90)]
check(AdClassifier.kind(for: mergedBanner) == .banner, "a wide line is a banner even when tall")

// 6. Real dialogue must never trip either detector.
check(AdClassifier.kind(for: [hit("cơ hội bắt đầu từ đây", height: 0.05, width: 0.5, midY: 0.1)]) == .none,
      "a subtitle with the call-to-action words alone is ignored")
check(AdClassifier.kind(for: [hit("Nổ Hũ, Game Bài Bắn Cá", height: 0.05, width: 0.5, midY: 0.1)]) == .none,
      "gambling vocabulary without the brand is ignored")
check(AdClassifier.kind(for: [hit("Rút tiền 24/7 nhận tiền trong tích tắc", height: 0.05, width: 0.6, midY: 0.1)]) == .none,
      "sponsor wording without the brand is ignored")
check(AdClassifier.kind(for: [hit("Phù Sa - Tập 23", height: 0.04, width: 0.2, midY: 0.95)]) == .none,
      "an ordinary title is ignored")
check(AdClassifier.kind(for: []) == .none, "an empty frame is ignored")

// 7. Brand spellings that OCR can produce.
check(AdClassifier.mentionsBrand("9922"), "digits")
check(AdClassifier.mentionsBrand("9 9 2 2"), "spaced digits")
check(AdClassifier.mentionsBrand("9922,com"), "comma variant")
check(AdClassifier.mentionsBrand("chín chín hai hai"), "spelled-out brand")
check(!AdClassifier.mentionsBrand("Phù Sa"), "unrelated text is not the brand")

// 8. The landing-page line needs both halves of the phrase.
check(AdClassifier.mentionsLandingPage("NƠI CƠ HỘI BẮT ĐẦU TỪ MỘT CÚ CHẠM."), "full call to action")
check(!AdClassifier.mentionsLandingPage("cơ hội"), "the word 'cơ hội' alone is not the call to action")

if failures > 0 {
    print("ad classifier: \(failures) check(s) failed")
    exit(1)
}
print("ad classifier scenarios passed")
