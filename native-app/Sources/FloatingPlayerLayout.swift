import Foundation
import CoreGraphics

/// Shared geometry keeps essential playback controls available at pocket sizes.
struct FloatingPlayerLayout {
    static let height: CGFloat = 100
    let title: CGRect
    let status: CGRect
    let timeline: CGRect
    let clock: CGRect
    let rule: CGRect
    let controls: [String: CGRect]

    init(width: CGFloat, episodes: Bool) {
        let inset: CGFloat = 12
        status = CGRect(x: width - inset - 84, y: 76, width: 84, height: 20)
        title = CGRect(x: inset, y: 76, width: max(0, status.minX - inset - 8), height: 20)
        clock = CGRect(x: width - inset - 144, y: 50, width: 144, height: 20)
        timeline = CGRect(x: inset, y: 48, width: max(0, clock.minX - inset - 8), height: 24)
        rule = CGRect(x: inset, y: 44, width: max(0, width - inset * 2), height: 1)
        var frames: [String: CGRect] = [:]
        var right = width - inset
        func trailing(_ name: String, gap: CGFloat = 4) {
            right -= 32
            frames[name] = CGRect(x: right, y: 8, width: 32, height: 32)
            right -= gap
        }
        trailing("close")
        trailing("more", gap: 12)
        if width >= 480 { trailing("maximize") }
        if width >= 640 { trailing("pin") }
        if width >= 760 { trailing("ghost") }
        var left = inset
        func leading(_ name: String, size: CGFloat = 32, gap: CGFloat = 4) {
            guard left + size <= right else { return }
            frames[name] = CGRect(x: left, y: 8, width: size, height: 32)
            left += size + gap
        }
        leading("play", gap: 8)
        leading("rewind")
        leading("forward", gap: 12)
        leading("volume", gap: 8)
        if episodes && left + 72 <= right {
            leading("previous")
            leading("next", gap: 8)
        }
        if right - left >= 96 { leading("speed", size: 44, gap: 8) }
        if right - left >= 48 {
            frames["slider"] = CGRect(x: left, y: 14, width: min(80, right - left), height: 20)
        }
        controls = frames
    }
}
