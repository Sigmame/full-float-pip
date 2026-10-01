import Foundation
import CoreGraphics

@main
struct LayoutChecks {
    static func main() {
        for width in stride(from: CGFloat(280), through: 1600, by: 4) {
            for episodes in [false, true] {
                let layout = FloatingPlayerLayout(width: width, episodes: episodes)
                for essential in ["play", "rewind", "forward", "volume", "close", "more"] {
                    precondition(layout.controls[essential] != nil, "Missing \(essential) at \(width)")
                }
                let frames = Array(layout.controls.values)
                for (i, frame) in frames.enumerated() {
                    precondition(frame.minX >= 12 && frame.maxX <= width - 12)
                    precondition(frame.minY >= 0 && frame.maxY <= FloatingPlayerLayout.height)
                    for other in frames.dropFirst(i + 1) {
                        precondition(!frame.intersects(other), "Controls overlap at \(width)")
                    }
                }
                precondition(layout.title.width > 0 && layout.timeline.width >= 100)
                precondition(!layout.title.intersects(layout.status))
                precondition(!layout.timeline.intersects(layout.clock))
                precondition(layout.clock.width >= 144, "Clock must fit hour-long films")
                if !episodes {
                    precondition(layout.controls["previous"] == nil && layout.controls["next"] == nil)
                }
            }
        }
        print("Floating player geometry passed: 280–1600 pt, playlists and single films")
    }
}
