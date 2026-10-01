import AppKit
import Foundation
import JavaScriptCore
import Vision

// Offline diagnostic for the three frame-level decisions the float player makes:
// black-bar cropping, the 9922.com splash/banner classification, and the colour
// heuristics that back them up.
//
// Everything reported here is the app's OWN code, not a re-implementation:
//   * `AdClassifier` is compiled straight out of Sources/AdClassifier.swift;
//   * `looksLike9922Splash`, `looksLikeSlotFrame` and `renderedLetterbox` are
//     extracted from Sources/FloatWindow.swift at build time (they are pure
//     functions of a CGImage, and are only unreachable because the class around
//     them needs AppKit and a running app);
//   * the in-page scanners are the real embedded JavaScript, run in
//     JavaScriptCore against pixels taken from the image.
//
// The numbers printed next to each decision are measured here purely so the
// thresholds can be tuned from real captures instead of guesses. The decisions
// themselves come from the code above.
//
// Build:  tools/build-diagnose.sh
// Run:    .build/vibefloat-diagnose shot.png [--content TOP% BOTTOM%] [--width 640]

// MARK: - Command line

var imagePath: String?
var contentTopPercent = 0.0
var contentBottomPercent = 100.0
var maxWidth = 640
var sourcePath = "Sources/FloatWindow.swift"

var iterator = CommandLine.arguments.dropFirst().makeIterator()
while let arg = iterator.next() {
    switch arg {
    case "--content":
        guard let top = iterator.next(), let bottom = iterator.next() else {
            FileHandle.standardError.write("--content needs TOP% BOTTOM%\n".data(using: .utf8)!)
            exit(2)
        }
        contentTopPercent = Double(top) ?? 0
        contentBottomPercent = Double(bottom) ?? 100
    case "--width":
        guard let width = iterator.next(), let value = Int(width) else {
            FileHandle.standardError.write("--width needs a number\n".data(using: .utf8)!)
            exit(2)
        }
        maxWidth = value
    case "--source":
        guard let path = iterator.next() else { exit(2) }
        sourcePath = path
    default:
        if imagePath == nil { imagePath = arg }
    }
}

guard let imagePath = imagePath else {
    print("""
    usage: vibefloat-diagnose <image> [--content TOP% BOTTOM%] [--width PX] [--source PATH]

      --content  the player area inside the capture, as percentages of the image
                 height. A screenshot of the whole window includes the AppKit
                 title bar at the top; the app's own snapshot does not, so pass
                 the bar's height here (e.g. --content 4 100). Default: whole image.
      --width    widest frame to analyse. The app caps its own snapshot at 640
                 (420 when no ad is recent), so 640 matches production. Default 640.
    """)
    exit(2)
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write("error: \(message)\n".data(using: .utf8)!)
    exit(1)
}

// MARK: - Frame

/// A frame held as top-down RGBA rows, which removes every ambiguity about
/// coordinate systems and matches what `NSBitmapImageRep.colorAt(y: 0)` means.
struct Frame {
    let width: Int
    let height: Int
    var rgba: [UInt8]
    let cgImage: CGImage

    func luma(_ x: Int, _ y: Int) -> Double {
        let i = (y * width + x) * 4
        return Double(rgba[i]) * 0.2126 + Double(rgba[i + 1]) * 0.7152 + Double(rgba[i + 2]) * 0.0722
    }
}

/// A CGImage whose row 0 is the first row of the buffer, so the app's own
/// `NSBitmapImageRep`-based heuristics see the same orientation this tool prints.
func imageFromRows(_ rgba: [UInt8], width: Int, height: Int) -> CGImage {
    let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                        bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    _ = rgba.withUnsafeBytes { source in
        memcpy(ctx.data!, source.baseAddress!, width * height * 4)
    }
    return ctx.makeImage()!
}

func frame(from cg: CGImage, maxWidth: Int) -> Frame {
    let width = min(maxWidth, cg.width)
    let height = max(1, Int((Double(cg.height) * Double(width) / Double(cg.width)).rounded()))
    let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                        bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.interpolationQuality = .medium
    ctx.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
    var rgba = [UInt8](repeating: 0, count: width * height * 4)
    _ = rgba.withUnsafeMutableBytes { destination in
        memcpy(destination.baseAddress!, ctx.data!, width * height * 4)
    }
    return Frame(width: width, height: height, rgba: rgba,
                 cgImage: imageFromRows(rgba, width: width, height: height))
}

/// Box-average a rectangle of the frame, the way `canvas.drawImage` would.
func sample(_ frame: Frame, sx: Double, sy: Double, sw: Double, sh: Double,
            dw: Int, dh: Int) -> [UInt8] {
    var out = [UInt8](repeating: 255, count: dw * dh * 4)
    guard dw > 0, dh > 0, sw > 0, sh > 0 else { return out }
    for y in 0..<dh {
        let y0 = sy + Double(y) * sh / Double(dh)
        let y1 = sy + Double(y + 1) * sh / Double(dh)
        for x in 0..<dw {
            let x0 = sx + Double(x) * sw / Double(dw)
            let x1 = sx + Double(x + 1) * sw / Double(dw)
            var r = 0.0, g = 0.0, b = 0.0, n = 0.0
            var py = Int(y0.rounded(.down))
            while Double(py) < max(y1, y0 + 1) {
                var px = Int(x0.rounded(.down))
                while Double(px) < max(x1, x0 + 1) {
                    let cx = min(frame.width - 1, max(0, px))
                    let cy = min(frame.height - 1, max(0, py))
                    let i = (cy * frame.width + cx) * 4
                    r += Double(frame.rgba[i]); g += Double(frame.rgba[i + 1]); b += Double(frame.rgba[i + 2])
                    n += 1
                    px += 1
                }
                py += 1
            }
            let i = (y * dw + x) * 4
            out[i] = UInt8(max(0, min(255, r / max(n, 1))))
            out[i + 1] = UInt8(max(0, min(255, g / max(n, 1))))
            out[i + 2] = UInt8(max(0, min(255, b / max(n, 1))))
            out[i + 3] = 255
        }
    }
    return out
}

// MARK: - Load

let url = URL(fileURLWithPath: imagePath)
guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
      let full = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
    fail("cannot read \(imagePath)")
}

var working = frame(from: full, maxWidth: maxWidth)
let fullHeight = working.height
let cropTop = Int(Double(fullHeight) * contentTopPercent / 100.0)
let cropBottom = Int(Double(fullHeight) * contentBottomPercent / 100.0)
if cropTop > 0 || cropBottom < fullHeight {
    let top = max(0, min(fullHeight - 1, cropTop))
    let bottom = max(top + 1, min(fullHeight, cropBottom))
    let height = bottom - top
    var rows = [UInt8](repeating: 0, count: working.width * height * 4)
    let start = top * working.width * 4
    rows.replaceSubrange(0..<(working.width * height * 4),
                         with: working.rgba[start..<(start + working.width * height * 4)])
    working = Frame(width: working.width, height: height, rgba: rows,
                    cgImage: imageFromRows(rows, width: working.width, height: height))
}

let frameWidth = working.width
let frameHeight = working.height

print("vibefloat-diagnose")
print("  image            \(imagePath) (\(full.width)x\(full.height))")
print("  player area      y \(contentTopPercent)%..\(contentBottomPercent)%")
print("  analysed frame   \(frameWidth)x\(frameHeight)  (client box assumed equal)")

// MARK: - Row profile

print("\n── row luma profile (each line = 2% of the frame) ──")
var profile = ""
for line in 0..<50 {
    let row = min(frameHeight - 1, Int(Double(frameHeight) * Double(line) / 50.0))
    var sum = 0.0, n = 0
    var x = 0
    while x < frameWidth {
        sum += working.luma(x, row); n += 1
        x += max(1, frameWidth / 120)
    }
    let mean = sum / Double(n)
    profile += mean < 12 ? "." : (mean < 40 ? ":" : (mean < 90 ? "o" : "#"))
}
print("  " + profile)
print("  . near black   : dark   o mid   # bright")

// MARK: - OCR + classifier

print("\n── OCR (accurate) + AdClassifier ──")
let ocr = VNRecognizeTextRequest()
ocr.recognitionLevel = .accurate
ocr.usesLanguageCorrection = false
ocr.recognitionLanguages = ["vi-VN", "en-US"]
try? VNImageRequestHandler(cgImage: working.cgImage, options: [:]).perform([ocr])
let hits: [AdTextHit] = (ocr.results ?? []).compactMap { observation in
    guard let text = observation.topCandidates(1).first?.string else { return nil }
    return AdTextHit(text: text, box: observation.boundingBox)
}
if hits.isEmpty {
    print("  (no text recognised)")
}
for hit in hits.sorted(by: { $0.box.midY > $1.box.midY }) {
    let brand = AdClassifier.mentionsBrand(hit.text) ? "brand" : "     "
    let landing = AdClassifier.mentionsLandingPage(hit.text) ? "cta" : "   "
    let splashShaped = hit.box.height >= 0.10 && hit.box.width <= 0.6 ? "wordmark-shaped" : ""
    print(String(format: "  h=%.3f w=%.3f midY=%.3f  %@ %@ %@  %@",
                 hit.box.height, hit.box.width, hit.box.midY, brand, landing, splashShaped,
                 hit.text))
}
let kind = AdClassifier.kind(for: hits)
print("  verdict: \(kind)")

// MARK: - Native heuristics (the app's own functions)

print("\n── native frame heuristics (real code) ──")
let band = renderedLetterbox(working.cgImage)
if let band = band {
    let span = band.1 - band.0
    print(String(format: "  renderedLetterbox: top=%.3f bottom=%.3f span=%.3f -> %@",
                 band.0, band.1, span, span < 0.999 ? "CROPS" : "no crop (full picture)"))
} else {
    print("  renderedLetterbox: nil (picture itself is dark here, nothing changes)")
}
let splash = looksLike9922Splash(working.cgImage)
let slot = looksLikeSlotFrame(working.cgImage)
print("  looksLike9922Splash: \(splash)")
print("  looksLikeSlotFrame:  \(slot)")

// Same numbers the two colour heuristics score on, measured here so the
// thresholds can be moved with evidence. The decisions above are the real ones.
func coverage(_ x0: Double, _ x1: Double, _ y0: Double, _ y1: Double,
              _ matches: (Double, Double, Double) -> Bool) -> Double {
    var count = 0, found = 0
    let step = max(2, frameWidth / 120)
    var y = Int(Double(frameHeight) * y0)
    while y < Int(Double(frameHeight) * y1) {
        var x = Int(Double(frameWidth) * x0)
        while x < Int(Double(frameWidth) * x1) {
            let i = (y * frameWidth + x) * 4
            let r = Double(working.rgba[i]) / 255, g = Double(working.rgba[i + 1]) / 255
            let b = Double(working.rgba[i + 2]) / 255
            count += 1
            if matches(r, g, b) { found += 1 }
            x += step
        }
        y += step
    }
    return count == 0 ? 0 : Double(found) / Double(count)
}
let pale = coverage(0.08, 0.92, 0.30, 0.67) { r, g, b in
    min(r, g, b) > 0.58 && max(r, g, b) - min(r, g, b) < 0.24
}
let darkBorder = coverage(0.08, 0.92, 0.13, 0.18) { r, g, b in max(r, g, b) < 0.25 }
let festive = coverage(0.08, 0.92, 0.01, 0.13) { r, g, b in
    (r > 0.58 && g > 0.35 && b < 0.45) || (r > 0.5 && g < 0.38 && b < 0.4)
}
var gold = 0.0, red = 0.0, neon = 0.0, samples = 0.0
var y = 0
while y < frameHeight {
    var x = 0
    while x < frameWidth {
        let i = (y * frameWidth + x) * 4
        let r = Double(working.rgba[i]) / 255, g = Double(working.rgba[i + 1]) / 255
        let b = Double(working.rgba[i + 2]) / 255
        samples += 1
        if r > 0.62 && g > 0.42 && b < 0.45 { gold += 1 }
        if r > 0.55 && g < 0.42 && b < 0.45 { red += 1 }
        if g > 0.58 && r < 0.5 && g > r + 0.16 { neon += 1 }
        x += 3
    }
    y += 3
}
print("  measured for tuning (not the decision):")
print(String(format: "    splash needs pale>0.88 darkBorder>=0.45 festive>0.30  ->  pale=%.3f darkBorder=%.3f festive=%.3f",
             pale, darkBorder, festive))
print(String(format: "    slot   needs gold>0.07 red>0.04 neon>0.03           ->  gold=%.3f red=%.3f neon=%.3f",
             gold / samples, red / samples, neon / samples))

// MARK: - In-page scanners (real embedded JavaScript)

func extractJavaScript(_ marker: String) -> String {
    guard let text = try? String(contentsOfFile: sourcePath, encoding: .utf8) else {
        fail("cannot read \(sourcePath) (run from native-app, or pass --source)")
    }
    guard let start = text.range(of: marker) else { fail("marker not found: \(marker)") }
    let rest = text[start.upperBound...]
    guard let end = rest.range(of: "    \"\"\"#") else { fail("script not terminated: \(marker)") }
    return String(rest[..<end.lowerBound])
}

let smartFillSource = extractJavaScript("    private static let smartFillJavaScript = #\"\"\"")
let bannerBlurSource = extractJavaScript("    private static let bannerBlurJavaScript = #\"\"\"")

let jsHarness = #"""
var __result = { smartFill: {}, adBlur: {} };
var __props = {};
var __timers = [];
var __frame = null;
var __overlay = null;

function __b64(s) {
    var key = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
    var map = {};
    for (var i = 0; i < key.length; i++) map[key[i]] = i;
    var pad = 0;
    while (s[s.length - 1 - pad] === '=') pad++;
    var out = new Uint8Array(((s.length / 4) | 0) * 3 - pad);
    var p = 0, buffer = 0, bits = 0;
    for (var i = 0; i < s.length; i++) {
        if (s[i] === '=') break;
        buffer = (buffer << 6) | map[s[i]];
        bits += 6;
        if (bits >= 8) { bits -= 8; out[p++] = (buffer >> bits) & 255; }
    }
    return out;
}

function __load() {
    __frame = __b64(__frameB64);
}

function __sample(sx, sy, sw, sh, dw, dh) {
    var out = new Uint8Array(dw * dh * 4);
    for (var y = 0; y < dh; y++) {
        var py = Math.min(__frameH - 1, Math.max(0, Math.round(sy + (y + 0.5) * sh / dh)));
        for (var x = 0; x < dw; x++) {
            var px = Math.min(__frameW - 1, Math.max(0, Math.round(sx + (x + 0.5) * sw / dw)));
            var s = (py * __frameW + px) * 4, d = (y * dw + x) * 4;
            out[d] = __frame[s]; out[d + 1] = __frame[s + 1]; out[d + 2] = __frame[s + 2]; out[d + 3] = 255;
        }
    }
    return out;
}

function __canvas() {
    var c = { width: 0, height: 0, sx: 0, sy: 0, sw: 0, sh: 0, dw: 0, dh: 0 };
    c.getContext = function() {
        return {
            drawImage: function(src, a, b, e, f, g, h, i, j) {
                if (arguments.length >= 9) {
                    c.sx = a; c.sy = b; c.sw = e; c.sh = f; c.dw = h; c.dh = i;
                } else {
                    c.sx = 0; c.sy = 0; c.sw = __frameW; c.sh = __frameH; c.dw = e; c.dh = f;
                }
            },
            getImageData: function(dx, dy, dw, dh) {
                return { data: __sample(c.sx, c.sy, c.sw, c.sh, dw, dh) };
            }
        };
    };
    return c;
}

var setInterval = function(fn, ms) { __timers.push({ fn: fn, ms: ms }); return __timers.length; };
var clearInterval = function() {};

var __video = {
    videoWidth: __frameW, videoHeight: __frameH,
    clientWidth: __clientW, clientHeight: __clientH,
    readyState: 4, paused: false, isConnected: true, currentSrc: 'diagnose-frame',
    addEventListener: function() {}, removeAttribute: function() {},
    style: { setProperty: function(name, value) { __props[name] = value; } }
};

var document = {
    body: { lastElementChild: null,
            appendChild: function(node) { this.lastElementChild = node; node.parentNode = this; } },
    getElementById: function(id) { return id === 'float-ad-blur' ? __overlay : null; },
    createElement: function(tag) {
        if (tag === 'canvas') return __canvas();
        var el = { style: {}, setAttribute: function() {}, parentNode: null };
        Object.defineProperty(el, 'id', {
            get: function() { return this._id; },
            set: function(value) { this._id = value; if (value === 'float-ad-blur') __overlay = el; }
        });
        return el;
    },
    querySelector: function() { return __video; },
    querySelectorAll: function() { return []; }
};

var window = { innerWidth: __clientW, innerHeight: __clientH, __floatContentTop: 0 };
__load();
"""#

let jsRun = #"""
window.__floatInstallSmartFill(__video);
for (var i = 0; i < 4; i++) {
    for (var t = 0; t < __timers.length; t++) if (__timers[t].ms === 800) { __timers[t].fn(); break; }
}
__result.smartFill = { transform: __props.transform || null, contentTop: window.__floatContentTop };

window.__floatInstallAdBlur(__video);
for (var i = 0; i < 4; i++) {
    for (var t = 0; t < __timers.length; t++) if (__timers[t].ms === 450) { __timers[t].fn(); break; }
}
__result.adBlur = {
    opacity: __overlay ? __overlay.style.opacity : null,
    height: __overlay ? __overlay.style.height : null,
    timerCount: __timers.length
};
"""#

print("\n── in-page scanners (real embedded JavaScript, JavaScriptCore) ──")
var smartFillTransform: String?
var adBlurOpacity: String?
if let context = JSContext() {
    context.exceptionHandler = { _, exception in
        if let exception = exception, let message = exception.toString() {
            print("  JS exception: \(message)")
        }
    }
    context.setObject(frameWidth, forKeyedSubscript: "__frameW" as NSString)
    context.setObject(frameHeight, forKeyedSubscript: "__frameH" as NSString)
    context.setObject(frameWidth, forKeyedSubscript: "__clientW" as NSString)
    context.setObject(frameHeight, forKeyedSubscript: "__clientH" as NSString)
    let base64 = Data(working.rgba).base64EncodedString()
    context.setObject(base64, forKeyedSubscript: "__frameB64" as NSString)
    context.evaluateScript(jsHarness)
    context.evaluateScript(smartFillSource)
    context.evaluateScript(bannerBlurSource)
    context.evaluateScript(jsRun)
    if let smart = context.evaluateScript("__result.smartFill")?.toDictionary() {
        smartFillTransform = smart["transform"] as? String
    }
    if let blur = context.evaluateScript("__result.adBlur")?.toDictionary() {
        adBlurOpacity = blur["opacity"] as? String
    }
} else {
    print("  (JavaScriptCore unavailable)")
}

let cropped = smartFillTransform.map { $0.contains("scale(") && !$0.contains("scale(1.0000)") } ?? false
print("  smartFill transform: \(smartFillTransform ?? "n/a")")
print("  banner blur overlay: opacity \(adBlurOpacity ?? "n/a")")

// MARK: - Verdict

let barsKnown = (band != nil && (band!.1 - band!.0) < 0.999) || cropped
print("\n── what the app will do with this frame ──")
print("  black bars  : \(barsKnown ? "CROP" : "leave alone")")
if let band = band, band.1 - band.0 < 0.999 {
    let span = band.1 - band.0
    print(String(format: "                native band %.3f..%.3f -> iframe/video scaled %.2fx",
                 band.0, band.1, 1 / span))
}
switch kind {
case .splash:
    print("  9922        : SKIP (splash) + full-frame cover")
case .banner:
    print("  9922        : BLUR top band only (no seek — the line is burned in for the episode)")
case .none:
    print("  9922        : nothing detected")
}
if splash || slot {
    print("                colour heuristic also fires (splash=\(splash) slot=\(slot)) -> seek")
}
print("  blur overlay: \(adBlurOpacity == "1" ? "in-page detector raises it" : "in-page detector does not see it (native cover would)")")
