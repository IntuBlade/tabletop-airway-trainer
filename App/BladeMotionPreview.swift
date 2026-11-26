import SceneKit
import SwiftUI
import simd

// The renderer consumes a camera transform in mouth coordinates, in meters.
// A tracked source will supply inverse(referenceFromMouth) * referenceFromCamera.
struct BladeMotionPreview: View {
    @State private var started = Date.now
    @State private var finished = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            TimelineView(.animation(minimumInterval: 1 / 30, paused: finished)) { tick in
                let seconds = min(8, max(0, tick.date.timeIntervalSince(started)))
                let registration = BladeRegistration(referenceFromMouth: matrix_identity_float4x4)
                if let pose = registration.mouthFromCamera(referenceFromCamera: Self.path(seconds)) {
                    SyntheticAirwayCamera(mouthFromCamera: pose)
                        .clipShape(.rect(cornerRadius: 14))
                } else {
                    ContentUnavailableView("Waiting for blade position", systemImage: "viewfinder")
                }
            }
            .aspectRatio(3 / 4, contentMode: .fit)
            Text("Simulated blade movement").font(.title2.bold())
            Text("Watch the camera enter, turn away from the opening, then recover the view. This example follows a programmed path.")
            Button("Replay movement") { finished = false; started = .now }
                .buttonStyle(.borderedProminent).tint(trainerActionFill)
        }
        .task(id: started) {
            do { try await Task.sleep(for: .seconds(8.1)) } catch { return }
            finished = true
        }
        .padding().navigationTitle("Blade view").navigationBarTitleDisplayMode(.inline)
    }

    static func path(_ seconds: Double) -> simd_float4x4 {
        let t = Float(seconds)
        let advance = min(1, t / 2.5)
        let turn = sin(.pi * min(1, max(0, (t - 3) / 4)))
        var pose = simd_float4x4(simd_quatf(angle: 0.85 * turn, axis: [0, 1, 0]))
        pose.columns.3 = [0.008 * turn, 0, 0.025 - 0.08 * advance, 1]
        return pose
    }
}

struct SyntheticAirwayCamera: UIViewRepresentable {
    let mouthFromCamera: simd_float4x4
    var useResearchScene = false

    private static let researchScene = Bundle.main.url(forResource: "PrivateAirway", withExtension: "usdz")
        .flatMap { try? SCNScene(url: $0, options: nil) }
    static var hasResearchScene: Bool { researchScene != nil }

    func makeUIView(context: Context) -> SCNView {
        let view = SCNView()
        let scene = SCNScene()
        view.scene = scene
        view.backgroundColor = UIColor(red: 0.12, green: 0.04, blue: 0.04, alpha: 1)
        view.antialiasingMode = .multisampling4X

        // Posterior wall and lateral folds form a deliberately schematic lumen.
        func surface(_ position: SIMD3<Float>, _ scale: SIMD3<Float>, _ color: UIColor) {
            let shape = SCNSphere(radius: 1)
            shape.segmentCount = 48
            shape.firstMaterial?.diffuse.contents = color
            let node = SCNNode(geometry: shape)
            node.simdPosition = position
            node.simdScale = scale
            scene.rootNode.addChildNode(node)
        }
        if useResearchScene, let model = Self.researchScene {
            scene.rootNode.addChildNode(model.rootNode.clone())
            scene.rootNode.enumerateChildNodes { node, _ in
                for material in node.geometry?.materials ?? [] {
                    material.isDoubleSided = true
                    material.roughness.contents = 0.42
                }
            }
        } else {
            let tissue = UIColor(red: 0.63, green: 0.30, blue: 0.29, alpha: 1)
            let rim = UIColor(red: 0.84, green: 0.60, blue: 0.52, alpha: 1)
            surface([0, 0, -0.16], [0.09, 0.07, 0.045], tissue)
            for side: Float in [-1, 1] {
                surface([side * 0.046, 0, -0.068], [0.020, 0.055, 0.062], tissue)
                surface([side * 0.010, -0.004, -0.109], [0.005, 0.014, 0.009], rim)
            }
            surface([0, -0.004, -0.112], [0.008, 0.014, 0.005], .black)
            surface([0, 0.017, -0.091], [0.020, 0.006, 0.008], tissue)
        }
        let camera = SCNNode()
        camera.camera = SCNCamera()
        camera.camera?.zNear = 0.001
        camera.camera?.zFar = 1
        if useResearchScene { camera.camera?.projectionDirection = .horizontal }
        camera.camera?.fieldOfView = TrainerMarker.horizontalFOV
        camera.light = SCNLight()
        camera.light?.type = .omni
        camera.light?.intensity = 700
        camera.simdTransform = mouthFromCamera
        scene.rootNode.addChildNode(camera)
        view.pointOfView = camera
        return view
    }

    func updateUIView(_ view: SCNView, context: Context) {
        view.pointOfView?.simdTransform = mouthFromCamera
    }
}
