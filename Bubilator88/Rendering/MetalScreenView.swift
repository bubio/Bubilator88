import SwiftUI
import MetalKit

/// NSViewRepresentable wrapper for EmulatorMetalView, embedding Metal rendering
/// into the SwiftUI view hierarchy.
struct MetalScreenViewWrapper: NSViewRepresentable {
    let viewModel: EmulatorViewModel

    func makeNSView(context: Context) -> EmulatorMetalView {
        guard let device = MTLCreateSystemDefaultDevice() else {
            fatalError("Metal is not supported on this device")
        }
        let metalView = EmulatorMetalView(
            frame: .zero,
            device: device,
            viewModel: viewModel
        )
        viewModel.metalView = metalView
        return metalView
    }

    func updateNSView(_ nsView: EmulatorMetalView, context: Context) {
        // No dynamic updates needed
    }
}
