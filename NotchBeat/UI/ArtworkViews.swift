import SwiftUI

@MainActor struct AlbumArtwork: View {
    var image: NSImage?
    var trackID: String
    var size: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.17).fill(LinearGradient(colors: [Color(red: 0.15, green: 0.49, blue: 0.40), .black], startPoint: .topLeading, endPoint: .bottomTrailing))
            if let image {
                Image(nsImage: image).resizable().scaledToFill().id(trackID).transition(.opacity)
            } else {
                Image(systemName: "music.note").font(.system(size: size * 0.43, weight: .semibold)).foregroundStyle(.white.opacity(0.85))
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.17))
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: trackID)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: image.map { ObjectIdentifier($0) })
        .accessibilityHidden(true)
    }
}

struct Equalizer: View {
    var playing: Bool
    var color: Color
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !playing || reduceMotion)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            HStack(alignment: .center, spacing: 1.6) {
                ForEach(0..<5) { index in
                    let phase = Double(index) * 0.85
                    let wave = 0.5 + 0.28 * sin(t * 3.8 + phase) + 0.22 * sin(t * 6.1 - phase * 1.4)
                    let envelope = 0.65 + 0.35 * sin(Double(index + 1) / 6 * .pi)
                    let height: CGFloat = playing ? (reduceMotion ? CGFloat(8 + index % 3 * 4) : CGFloat(4 + 17 * wave * envelope)) : 3
                    Capsule().fill(LinearGradient(colors: [color, color.opacity(0.65)], startPoint: .top, endPoint: .bottom))
                        .frame(width: 2.6, height: height)
                        .animation(reduceMotion ? nil : .easeOut(duration: 0.07), value: height)
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }.accessibilityLabel(playing ? "Воспроизведение" : "Пауза")
    }
}
