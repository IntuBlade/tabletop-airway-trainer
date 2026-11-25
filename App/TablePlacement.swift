import ARKit
import RealityKit
import SwiftUI

struct TablePlacement: View {
    @State private var placed = false
    @State private var reset = 0

    @State private var station: BladeRegistration?
    @State private var markerVisible = false
    @State private var assetFailed = false

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
                PlacementCamera(placed: $placed, assetFailed: $assetFailed, station: $station, markerVisible: $markerVisible, reset: reset)
                    .accessibilityLabel("Table placement camera")
                Text(assetFailed ? "Head could not load. Reopen table placement to retry." : placed ? "Head placed" : "Move the phone slowly over the table, then tap to place the head.")
                    .font(.headline)
                Text(station != nil ? "Mouth registered. Keep the QR in this position." :
                        markerVisible ? "QR found. Tap the tabletop to place or reposition the head." :
                        "For blade setup, place the trainer QR beside the head with its black square 40 mm wide. Keep it visible while tapping the table.")
                    .foregroundStyle(.secondary)
                #if canImport(BaseCamera)
                if let station {
                    NavigationLink("Use blade at placed mouth") { LiveBladeMotion(station: station) }
                        .buttonStyle(.borderedProminent)
                }
                #endif
                if placed {
                    Button("Place again") {
                        station = nil
                        placed = false
                        reset += 1
                    }.frame(minHeight: 44)
                }
            } else {
                ContentUnavailableView("Table placement unavailable", systemImage: "arkit")
            }
            #endif
            if placed || !ARWorldTrackingConfiguration.isSupported {
                NavigationLink("Preview blade movement") { BladeMotionPreview() }
                    .buttonStyle(.borderedProminent).tint(trainerActionFill)
            }
        }
        .padding(16)
        .navigationTitle("Place head on table")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct PlacementCamera: UIViewRepresentable {
    @Binding var placed: Bool
    @Binding var assetFailed: Bool
    @Binding var station: BladeRegistration?
    @Binding var markerVisible: Bool
    let reset: Int

    func makeCoordinator() -> Coordinator { Coordinator(placed: $placed, failed: $assetFailed, station: $station, visible: $markerVisible) }

    func makeUIView(context: Context) -> ARView {
        let view = ARView(frame: .zero, cameraMode: .ar, automaticallyConfigureSession: false)
        let config = ARWorldTrackingConfiguration()
        config.planeDetection = [.horizontal]
        if let cg = UIImage(named: "StationQR")?.cgImage {
            // PNG includes a 522 px black square within the 738 px reference image.
            let marker = ARReferenceImage(cg, orientation: .up, physicalWidth: 0.04 * 738 / 522)
            marker.name = "trainer-qr"
            config.detectionImages = [marker]
            config.maximumNumberOfTrackedImages = 1
        }
        view.session.delegate = context.coordinator
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

    @MainActor final class Coordinator: NSObject, ARSessionDelegate {
        weak var view: ARView?
        @Binding var placed: Bool
        var reset = 0

        @Binding var failed: Bool
        @Binding var station: BladeRegistration?
        @Binding var markerVisible: Bool

        init(placed: Binding<Bool>, failed: Binding<Bool>, station: Binding<BladeRegistration?>, visible: Binding<Bool>) {
            _station = station
            _markerVisible = visible
            _failed = failed
            _placed = placed
        }

        nonisolated func session(_ session: ARSession, didUpdate anchors: [ARAnchor]) {
            guard let marker = anchors.compactMap({ $0 as? ARImageAnchor }).first else { return }
            let tracked = marker.isTracked
            Task { @MainActor in if markerVisible != tracked { markerVisible = tracked } }
        }

        @objc func place(_ tap: UITapGestureRecognizer) {
            guard (!placed || station == nil), let view,
                  let hit = view.raycast(from: tap.location(in: view), allowing: .existingPlaneGeometry, alignment: .horizontal).first else {
                return
            }
            let anchor = AnchorEntity(world: hit.worldTransform)
            guard let url = Bundle.main.url(forResource: "TrainerHead", withExtension: "usdz"),
                  let head = try? Entity.load(contentsOf: url) else { failed = true; return }
            let base = ModelEntity(mesh: .generateBox(size: [0.196, 0.017, 0.274], cornerRadius: 0.008),
                                   materials: [SimpleMaterial(color: .darkGray, roughness: 0.92, isMetallic: false)])
            base.position.y = 0.0085
            anchor.addChild(base)
            head.position.y = 0.012
            anchor.addChild(head)
            view.scene.anchors.removeAll()
            view.scene.addAnchor(anchor)
            if let frame = view.session.currentFrame, case .normal = frame.camera.trackingState,
               let marker = frame.anchors.compactMap({ $0 as? ARImageAnchor }).first(where: { $0.isTracked }) {
                station = TableStation.registration(worldFromImage: marker.transform, worldFromHeadBase: hit.worldTransform)
            }
            placed = true
        }

    }
}
