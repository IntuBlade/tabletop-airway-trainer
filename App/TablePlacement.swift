import ARKit
import RealityKit
import SwiftUI

struct TablePlacement: View {
    @State private var placed = false
    @State private var reset = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            #if targetEnvironment(simulator)
            ContentUnavailableView(
                "Use an iPhone for table placement",
                systemImage: "arkit",
                description: Text("Recorded practice is available from the main screen.")
            )
            #else
            if ARWorldTrackingConfiguration.isSupported {
                PlacementCamera(placed: $placed, reset: reset)
                    .accessibilityLabel("Table placement camera")
                Text(placed ? "Setup model placed" : "Aim at the table, then tap where the head should rest.")
                    .font(.headline)
                Text("Placement preview. Blade-controlled movement and scoring require calibrated tracking.")
                    .foregroundStyle(.secondary)
                if placed {
                    Button("Place again") {
                        placed = false
                        reset += 1
                    }.frame(minHeight: 44)
                }
            } else {
                ContentUnavailableView("Table placement unavailable", systemImage: "arkit")
            }
            #endif
        }
        .padding(16)
        .navigationTitle("Place head on table")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct PlacementCamera: UIViewRepresentable {
    @Binding var placed: Bool
    let reset: Int

    func makeCoordinator() -> Coordinator { Coordinator(placed: $placed) }

    func makeUIView(context: Context) -> ARView {
        let view = ARView(frame: .zero, cameraMode: .ar, automaticallyConfigureSession: false)
        let config = ARWorldTrackingConfiguration()
        config.planeDetection = [.horizontal]
        view.session.run(config)
        context.coordinator.view = view
        view.addGestureRecognizer(UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.place(_:))))
        return view
    }

    func updateUIView(_ view: ARView, context: Context) {
        if context.coordinator.reset != reset {
            context.coordinator.reset = reset
            view.scene.anchors.removeAll()
        }
    }

    static func dismantleUIView(_ view: ARView, coordinator: Coordinator) {
        view.session.pause()
    }

    @MainActor final class Coordinator: NSObject {
        weak var view: ARView?
        @Binding var placed: Bool
        var reset = 0

        init(placed: Binding<Bool>) {
            _placed = placed
        }

        @objc func place(_ tap: UITapGestureRecognizer) {
            guard !placed, let view,
                  let hit = view.raycast(from: tap.location(in: view), allowing: .existingPlaneGeometry, alignment: .horizontal).first else {
                return
            }
            let anchor = AnchorEntity(world: hit.worldTransform)
            anchor.addChild(Self.trainingHead())
            view.scene.addAnchor(anchor)
            placed = true
        }

        private static func trainingHead() -> Entity {
            let model = Entity()
            let shell = SimpleMaterial(color: UIColor(red: 0.77, green: 0.63, blue: 0.52, alpha: 1), roughness: 0.8, isMetallic: false)
            let mouth = SimpleMaterial(color: UIColor(red: 0.23, green: 0.08, blue: 0.09, alpha: 1), roughness: 1, isMetallic: false)

            let skull = ModelEntity(mesh: .generateSphere(radius: 1), materials: [shell])
            skull.scale = [0.083, 0.073, 0.104]
            skull.position = [0, 0.077, -0.031]

            let jaw = ModelEntity(mesh: .generateSphere(radius: 1), materials: [shell])
            jaw.scale = [0.062, 0.050, 0.055]
            jaw.position = [0, 0.067, 0.066]

            let mouthLocation = ModelEntity(mesh: .generateSphere(radius: 1), materials: [mouth])
            mouthLocation.scale = [0.030, 0.006, 0.021]
            mouthLocation.position = [0, 0.115, 0.068]

            let nose = ModelEntity(mesh: .generateSphere(radius: 1), materials: [shell])
            nose.scale = [0.016, 0.017, 0.022]
            nose.position = [0, 0.146, 0.017]

            for part in [skull, jaw, mouthLocation, nose] { model.addChild(part) }
            return model
        }
    }
}
