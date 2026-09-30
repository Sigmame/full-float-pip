import Foundation
import CoreGraphics

/// Presets use logical AppKit points; Retina scaling does not change their footprint.
enum FloatingPlayerSizePreset: String, CaseIterable {
    case mini, standard, wide, pocket

    var chipTitle: String {
        switch self {
        case .mini: return "Nhỏ"
        case .standard: return "Vừa"
        case .wide: return "Rộng"
        case .pocket: return "Lớn"
        }
    }

    var targetWidth: CGFloat? {
        switch self {
        case .mini: return 480
        case .standard: return 640
        case .wide: return 960
        case .pocket: return nil
        }
    }

    var menuTitle: String {
        switch self {
        case .mini: return "Cỡ Nhỏ (480 pt)"
        case .standard: return "Cỡ Vừa (640 pt)"
        case .wide: return "Cỡ Rộng (tối đa 960 pt)"
        case .pocket: return "Cỡ Lớn (ô trống lớn nhất)"
        }
    }

    func fittedSize(aspectRatio: CGFloat, screen: CGSize, minimumWidth: CGFloat,
                    maximumWidth: CGFloat, stripHeight: CGFloat, stripGap: CGFloat) -> CGSize {
        let ratio = max(0.2, aspectRatio)
        let availableWidth = max(minimumWidth, screen.width - 32)
        let availableHeight = max(minimumWidth / ratio, screen.height - stripHeight - stripGap - 32)
        var width = targetWidth ?? availableWidth
        if self != .pocket {
            // Bound every preset by the wide budget so a constrained screen
            // cannot make Wide smaller than Medium or Small.
            let heightBudget = max(minimumWidth / ratio, screen.height * 0.85 - stripHeight - stripGap)
            let wideBudget = max(minimumWidth, min(960, screen.width * 0.75, heightBudget * ratio))
            width = min(width, wideBudget)
        }
        width = min(max(width, minimumWidth), maximumWidth, availableWidth, availableHeight * ratio)
        return CGSize(width: width, height: width / ratio)
    }
}
