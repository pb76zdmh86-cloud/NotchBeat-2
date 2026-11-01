import SwiftUI

@MainActor struct CompactSlot: View {
    @ObservedObject var module: BuiltInModule
    var region: CompactRegion
    var body: some View { module.compactView(in: region) }
}
@MainActor struct MinimalSlot: View {
    @ObservedObject var module: BuiltInModule
    var body: some View { module.minimalView }
}
