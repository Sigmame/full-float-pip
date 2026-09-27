import Foundation

func testDubbingTranslatorVietnamesePassThrough() {
    let translator = DubbingTranslator.shared
    let text = "Xin chào các bạn, hôm nay thời tiết rất đẹp."
    let sem = DispatchSemaphore(value: 0)
    var resultText = ""

    translator.translateToVietnamese(text: text) { translated in
        resultText = translated
        sem.signal()
    }

    _ = sem.wait(timeout: .now() + 2.0)
    assert(resultText == text, "Vietnamese text should pass through without modification")
    print("  ok   Vietnamese dialogue pass-through verified")
}

func testDubbingTranslatorEnglishToVietnamese() {
    let translator = DubbingTranslator.shared
    let englishText = "I will come back to help you tomorrow."
    let sem = DispatchSemaphore(value: 0)
    var resultText = ""

    translator.translateToVietnamese(text: englishText) { translated in
        resultText = translated
        sem.signal()
    }

    let waitResult = sem.wait(timeout: .now() + 5.0)
    assert(waitResult == .success, "Translation should complete within 5s")
    assert(!resultText.isEmpty, "Translation should not be empty")
    assert(SubtitleClassifier.isLikelyVietnameseDialogue(resultText), "Result should be Vietnamese dialogue (was: \(resultText))")
    print("  ok   English to Vietnamese translation verified: '\(resultText)'")

    // Test cache hit
    let start = Date()
    let sem2 = DispatchSemaphore(value: 0)
    var cacheResult = ""
    translator.translateToVietnamese(text: englishText) { translated in
        cacheResult = translated
        sem2.signal()
    }
    _ = sem2.wait(timeout: .now() + 1.0)
    let elapsed = Date().timeIntervalSince(start)
    assert(cacheResult == resultText, "Cached result should match")
    assert(elapsed < 0.05, "Cache hit should be instantaneous (< 50ms, took \(elapsed)s)")
    print("  ok   instant translation cache hit verified (\(String(format: "%.3f", elapsed))s)")
}

func testDubbingTranslatorBatch() {
    let translator = DubbingTranslator.shared
    let inputs = [
        "Good morning everyone",
        "We are ready for the presentation",
        "Let us start right now"
    ]
    let sem = DispatchSemaphore(value: 0)
    var batchResults: [String: String] = [:]

    translator.translateBatch(texts: inputs) { results in
        batchResults = results
        sem.signal()
    }

    let waitResult = sem.wait(timeout: .now() + 6.0)
    assert(waitResult == .success, "Batch translation should complete within 6s")
    assert(batchResults.count == inputs.count, "All inputs should be translated")
    for text in inputs {
        let res = batchResults[text] ?? ""
        assert(!res.isEmpty, "Result for '\(text)' should not be empty")
    }
    print("  ok   batch translation verified (\(batchResults.count) sentences)")
}

print("dubbing-translator: unit tests")
testDubbingTranslatorVietnamesePassThrough()
testDubbingTranslatorEnglishToVietnamese()
testDubbingTranslatorBatch()
print("dubbing-translator scenarios passed")
exit(0)
