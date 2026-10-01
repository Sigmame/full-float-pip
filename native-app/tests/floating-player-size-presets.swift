import Foundation
import CoreGraphics

@main
struct SizeChecks {
    static func size(_ preset: FloatingPlayerSizePreset, screen: CGSize, ratio: CGFloat = 16 / 9) -> CGSize {
        preset.fittedSize(aspectRatio: ratio, screen: screen, minimumWidth: ratio < 1 ? 280 : 380,
                          maximumWidth: ratio < 1 ? 540 : 1920, stripHeight: 100, stripGap: 6)
    }
    static func main() {
        let desktop = CGSize(width: 1440, height: 900)
        precondition(size(.mini, screen: desktop).width == 480)
        precondition(size(.standard, screen: desktop).width == 640)
        precondition(size(.wide, screen: desktop).width == 960)
        for screen in [CGSize(width: 640, height: 480), CGSize(width: 1024, height: 700),
                       CGSize(width: 1280, height: 720), desktop, CGSize(width: 2560, height: 1440)] {
            var previous: CGFloat = 0
            for preset in [FloatingPlayerSizePreset.mini, .standard, .wide] {
                let result = size(preset, screen: screen)
                precondition(result.width >= previous, "Presets must stay ordered on constrained screens")
                precondition(result.width <= screen.width - 32)
                precondition(result.height + 106 <= screen.height - 32)
                precondition(abs(result.width / result.height - 16 / 9) < 0.001)
                precondition(!preset.menuTitle.contains("px"))
                previous = result.width
            }
            let wide = size(.wide, screen: screen)
            precondition(wide.width <= min(960, screen.width * 0.75))
            precondition(wide.height + 106 <= screen.height * 0.85 + 0.001)
        }
        for preset in FloatingPlayerSizePreset.allCases {
            let portrait = size(preset, screen: desktop, ratio: 9 / 16)
            precondition(portrait.width >= 280 && portrait.width <= 540)
            precondition(portrait.height + 106 <= desktop.height - 32)
            precondition(FloatingPlayerSizePreset(rawValue: preset.rawValue) == preset)
        }
        print("Preset sizes passed: 480/640/960 pt, adaptive screens, ordering, aspect ratio, and portrait limits")
    }
}
