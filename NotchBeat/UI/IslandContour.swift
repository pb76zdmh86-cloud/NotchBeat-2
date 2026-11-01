import SwiftUI

enum IslandContour {
    static func cgPath(in rect: CGRect, physical: Bool) -> CGPath {
        let limit = min(rect.width, rect.height) / 2
        let top = min(physical ? 4 : 32, limit)
        let bottom = min(32, limit)
        return UnevenRoundedRectangle(topLeadingRadius: top, bottomLeadingRadius: bottom,
            bottomTrailingRadius: bottom, topTrailingRadius: top, style: .continuous).path(in: rect).cgPath
    }
}
struct IslandShape: Shape {
    var physical: Bool
    func path(in rect: CGRect) -> Path { Path(IslandContour.cgPath(in: rect, physical: physical)) }
}
