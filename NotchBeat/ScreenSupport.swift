import AppKit
import CoreGraphics

struct DisplayChoice: Identifiable {
    let id: String
    let name: String
    let hasNotch: Bool
    let builtIn: Bool
}

extension NSScreen {
    var displayNumber: CGDirectDisplayID {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
    }
    var stableDisplayID: String {
        if let uuid = CGDisplayCreateUUIDFromDisplayID(displayNumber)?.takeRetainedValue() {
            return CFUUIDCreateString(nil, uuid) as String
        }
        return String(displayNumber)
    }
    var physicalNotch: CGRect? {
        guard safeAreaInsets.top > 0, let left = auxiliaryTopLeftArea, let right = auxiliaryTopRightArea,
              right.minX > left.maxX else { return nil }
        return CGRect(x: left.maxX, y: frame.maxY - safeAreaInsets.top,
                      width: right.minX - left.maxX, height: safeAreaInsets.top)
    }
}
