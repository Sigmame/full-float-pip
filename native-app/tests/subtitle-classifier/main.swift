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

func subHit(_ text: String, x: Double = 0.5, y: Double = 0.2, w: Double = 0.5, h: Double = 0.1) -> SubtitleTextHit {
    SubtitleTextHit(text: text, box: CGRect(x: x - w / 2, y: y, width: w, height: h))
}

print("subtitle classifier: unit tests")

// 1. Vietnamese dialogue detection
check(SubtitleClassifier.isLikelyVietnameseDialogue("Tại một trường đại học hẻo lánh, một cô gái trẻ xuất hiện."),
      "detects authentic accented Vietnamese subtitle")
check(SubtitleClassifier.isLikelyVietnameseDialogue("Anh co sao khong? Toi khong sao."),
      "detects authentic unaccented Vietnamese subtitle with common words")
check(SubtitleClassifier.isLikelyVietnameseDialogue("Đi thôi!"),
      "detects short accented Vietnamese exclamation")
check(SubtitleClassifier.isLikelyVietnameseDialogue("Cảm ơn bạn rất nhiều."),
      "detects common Vietnamese courtesy")

// 2. Reject English text and Kindle / book synopsis garbage
let kindleGarbage1 = "Want to read Kindle $14.99 \"Tại một trường đại học quiet isolati (ane rhythms nights of subtle bifting hẻo lánh, một cổ gái trổ n hnn"
let kindleGarbage2 = "Kindle $14.- Rate this book ****й At an elite college nestled in quiet isolatio young woman drifts through the rhythms d meaning lies athing Is red secrets, and shifting e circle of classmates ates bleed into late nights of subtle cademia, entangled in the lives of a small,"

check(!SubtitleClassifier.isLikelyVietnameseDialogue(kindleGarbage1), "rejects mixed Kindle ad / English blurb")
check(!SubtitleClassifier.isLikelyVietnameseDialogue(kindleGarbage2), "rejects pure English book review synopsis")
check(!SubtitleClassifier.isLikelyVietnameseDialogue("Hello how are you today my friend"), "rejects pure English dialogue")
check(!SubtitleClassifier.isLikelyVietnameseDialogue("Subtitles by KKPhim"), "rejects English subtitle credit")
check(!SubtitleClassifier.isLikelyVietnameseDialogue("12:34"), "rejects timestamp")
check(!SubtitleClassifier.isLikelyVietnameseDialogue("http://phimmoi.com"), "rejects URL")
check(!SubtitleClassifier.isLikelyVietnameseDialogue("Only $9.99 per month"), "rejects price tag")

// 3. Subtitle extraction from OCR hits
let cleanHits = [
    subHit("Tại một trường đại học hẻo lánh,", x: 0.5, y: 0.30, w: 0.5, h: 0.08),
    subHit("một cô gái trẻ đã phát hiện bí mật.", x: 0.5, y: 0.18, w: 0.55, h: 0.08)
]
let extractedClean = SubtitleClassifier.extractCleanSubtitle(from: cleanHits)
check(extractedClean == "Tại một trường đại học hẻo lánh, một cô gái trẻ đã phát hiện bí mật.",
      "extracts and joins multiline Vietnamese subtitle in top-to-bottom order")

// 4. Subtitle extraction filters out Kindle / ad hit
let mixedHits = [
    subHit("Kindle $14.99 - Rate this book", x: 0.1, y: 0.85, w: 0.4, h: 0.1),
    subHit("Chúng ta phải đi ngay bây giờ.", x: 0.5, y: 0.20, w: 0.5, h: 0.08)
]
let extractedMixed = SubtitleClassifier.extractCleanSubtitle(from: mixedHits)
check(extractedMixed == "Chúng ta phải đi ngay bây giờ.",
      "extracts only the centered Vietnamese subtitle, dropping ad hit")

// 5. Total ad frame produces nil
let adOnlyHits = [
    subHit("Kindle $14.99", x: 0.5, y: 0.2, w: 0.3, h: 0.1),
    subHit("At an elite college nestled in quiet isolation", x: 0.5, y: 0.1, w: 0.7, h: 0.1)
]
check(SubtitleClassifier.extractCleanSubtitle(from: adOnlyHits) == nil,
      "ad only frame produces nil subtitle")

// 6. Normalization for dubbing deduplication
let norm1 = SubtitleClassifier.normalizedForDubbing("Tại một trường đại học hẻo lánh!")
let norm2 = SubtitleClassifier.normalizedForDubbing("tai mot truong dai hoc heo lanh")
check(norm1 == norm2, "normalization matches accented and unaccented forms for deduplication")

// 7. Levenshtein similarity and near-duplicate detection
check(SubtitleClassifier.similarity("tai mot truong dai hoc", "tai mot truong dai hoc") == 1.0,
      "exact match similarity is 1.0")
check(SubtitleClassifier.isNearDuplicate("Tại một trường đại học hẻo lánh",
                                        of: "Tại một trường đại học hẻo lanh!"),
      "detects near duplicate subtitle with slight OCR jitter")
check(!SubtitleClassifier.isNearDuplicate("Tại một trường đại học hẻo lánh",
                                         of: "Tôi phải rời khỏi đây ngay lập tức"),
      "different dialogue lines are not considered duplicates")


// 8. SubtitleDeduplicator sliding window & multi-source suppression
check(SubtitleClassifier.isSameDisplayedCue("Tớ biết.", as: "Tớ biết"),
      "OCR punctuation jitter is one displayed cue")
check(!SubtitleClassifier.isSameDisplayedCue("Tớ biết là cậu sai", as: "Tớ biết là cậu đúng"),
      "adjacent sentences with shared words stay separate")
check(!SubtitleClassifier.isSameDisplayedCue("Tớ biết.", as: "Tớ biết rồi."),
      "a new short subtitle is not swallowed by its prefix")

let dedup = SubtitleDeduplicator(windowSeconds: 10.0)
let t0 = Date()

// First arrival: should be dubbed
check(dedup.shouldDub(text: "Tại một trường đại học hẻo lánh", now: t0),
      "deduplicator accepts new dialogue line")

// Exact duplicate at t0 + 2s: should be rejected
check(!dedup.shouldDub(text: "Tại một trường đại học hẻo lánh", now: t0.addingTimeInterval(2.0)),
      "deduplicator rejects exact duplicate within window")

// Near-duplicate (OCR jitter / punctuation variation) at t0 + 4s: should be rejected
check(!dedup.shouldDub(text: "Tại một trường đại học hẻo lánh...", now: t0.addingTimeInterval(4.0)),
      "deduplicator rejects near-duplicate within 7.5s")

// Substring / partial dialogue fragment at t0 + 5s: should be rejected
check(!dedup.shouldDub(text: "Tại một trường đại học", now: t0.addingTimeInterval(5.0)),
      "deduplicator rejects partial prefix of recently dubbed sentence")

// Distinct new dialogue line at t0 + 6s: should be accepted
check(dedup.shouldDub(text: "Cô ấy nhìn thấy một điều kỳ lạ trong phòng thí nghiệm", now: t0.addingTimeInterval(6.0)),
      "deduplicator accepts distinct new dialogue line")

// Original sentence after window expiration (t0 + 12s): should be accepted again
check(dedup.shouldDub(text: "Tại một trường đại học hẻo lánh", now: t0.addingTimeInterval(12.0)),
      "deduplicator allows repeated sentence after sliding window expires")

if failures > 0 {
    print("subtitle classifier: \(failures) check(s) failed")
    exit(1)
}
print("subtitle classifier scenarios passed")
