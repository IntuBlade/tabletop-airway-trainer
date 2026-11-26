import SwiftUI
import SceneKit
import Vision
import QuartzCore
import CoreImage
#if canImport(BaseCamera)
import BaseCamera
import ExternalAccessory
#endif


#if canImport(BaseCamera)
struct BladeFrame {
    let image: UIImage
    let corners: [SIMD2<Double>]?
    let setupPose: simd_float4x4?
    let practicePose: simd_float4x4?
    let captured: Double

    var aspect: CGFloat { image.size.width / image.size.height }
}

final class TrainerBlade: NSObject, CameraDelegate, @unchecked Sendable {
    static let shared = TrainerBlade()
    private let lock = NSLock()
    private let worker = DispatchQueue(label: "trainer.marker")
    private var active = false
    private var busy = false
    private var generation = 0
    private var frame: BladeFrame?
    private var sequence = MarkerSequence()
    private var filter = BladePoseFilter()
    private var started = false
    private let imageContext = CIContext()
    private var connection = "Waiting for blade connection"
    private var sawFrame = false
    private var rawPreview: BladeFrame?

    private func setConnection(_ value: String) {
        lock.withLock { connection = value }
        NSLog("Trainer accessory: %@", value)
    }

    @MainActor func start() {
        guard !started else { return }
        guard ["CFBundleShortVersionString", "CFBundleVersion"].allSatisfy({
            (Bundle.main.object(forInfoDictionaryKey: $0) as? String)?.isEmpty == false
        }) else { return }
        started = true
        EAAccessoryManager.shared().registerForLocalNotifications()
        CameraManager.share().addObserver(self)
        CMImageFilter.share.cropCircle = false
        CMImageFilter.share.cropSquare = false
        CMImageFilter.share.cropCircleOpaque = false
        CMConfigureHandle.share().mfiProtocol = "com.intublade.protocol"
        CameraManager.share().startInitialize()
    }

    func enable(_ enabled: Bool) {
        lock.withLock {
            active = enabled
            generation += 1
            sequence = MarkerSequence()
            filter = BladePoseFilter()
            frame = nil
            rawPreview = nil
            sawFrame = false
        }
    }

    func snapshot() -> (frame: BladeFrame?, connection: String) {
        lock.withLock {
            let fresh = frame.flatMap { CACurrentMediaTime() - $0.captured < 0.4 ? $0 : nil }
            let raw = rawPreview.flatMap { CACurrentMediaTime() - $0.captured < 0.4 ? $0 : nil }
            return (fresh ?? raw, connection)
        }
    }

    func receive(_ data: Data!, image: UIImage!) {
        guard let image else { return }
        let now = CACurrentMediaTime()
        let ticket: Int? = lock.withLock {
            guard active else { return nil }
            if !sawFrame {
                sawFrame = true
                NSLog("Trainer accessory: received first blade image in setup")
            }
            rawPreview = BladeFrame(image: image, corners: nil, setupPose: nil, practicePose: nil, captured: now)
            guard !busy else { return nil }
            busy = true
            return generation
        }
        guard let ticket else { return }
        worker.async {
            let cg = image.cgImage ?? image.ciImage.flatMap { self.imageContext.createCGImage($0, from: $0.extent) }
            let corners = cg.flatMap { try? TrainerMarker.corners(in: $0) }
            let setupPose = corners.flatMap(TrainerMarker.solve)
            self.lock.withLock {
                self.busy = false
                guard self.generation == ticket else { return }
                let pose = self.sequence.pose(corners, at: now)
                let practicePose = self.filter.update(pose, at: now)
                self.frame = cg.map {
                    BladeFrame(image: UIImage(cgImage: $0), corners: corners, setupPose: setupPose,
                               practicePose: practicePose, captured: now)
                }
            }
        }
    }

    func deviceConnect(with status: CMConnectStatus, param: [AnyHashable: Any]!) {
        let code = (param?[CMErrorCodeKey] as? NSNumber)?.intValue
        let detail = code.map { " (SDK code \($0))" } ?? ""
        switch status {
        case .connected: setConnection("Blade connected. Waiting for video.")
        case .errorButContinue: setConnection("Blade connection warning" + detail + ". Waiting for video.")
        case .disconnected: setConnection("Blade disconnected")
        case .error:
            switch code {
            case CMErrorCode.appInfoNotSupport.rawValue:
                setConnection("SDK rejected the app name, ID, or accessory protocol" + detail)
            case CMErrorCode.licenseError.rawValue:
                setConnection("Blade SDK license check failed" + detail)
            default: setConnection("Blade SDK connection failed" + detail)
            }
        case .connecting, .connectedAndCheckingLicence: setConnection("Checking blade connection")
        @unknown default: setConnection("Unknown blade connection state" + detail)
        }
        if status != .connected && status != .errorButContinue { invalidate() }
    }

    func receiveDeviceConflicted(_ conflicted: Bool) { if conflicted { invalidate(); setConnection("Blade in use by another app") } }

    private func invalidate() {
        lock.withLock { generation += 1; sequence = MarkerSequence(); filter = BladePoseFilter(); frame = nil; rawPreview = nil; sawFrame = false }
    }
}

struct LiveBladeMotion: View {
    var station: BladeRegistration? = nil
    @Environment(\.scenePhase) private var phase
    private let placement = BladeTablePlacement()
    @State private var practicing = false
    @State private var placedScale: TabletopScale?
    @State private var headFailed = false

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: phase != .active)) { _ in
            let sample = TrainerBlade.shared.snapshot()
            let frame = sample.frame
            let inRep = practicing || station != nil
            let candidate = placedScale == nil && station == nil ? frame.flatMap { frame in
                frame.setupPose.flatMap { TabletopScale.fitting($0, aspect: Float(frame.aspect), placement: placement) }
            } : nil
            let scale = station == nil ? placedScale ?? candidate : .fullSize
            let setupLens = frame?.setupPose.flatMap { pose in scale.map { $0.modelCamera(pose) } }
            let practiceLens = frame?.practicePose.flatMap { pose in scale.map { $0.modelCamera(pose) } }
            let camera = (station ?? placement.station).mouthFromCamera(referenceFromCamera: practiceLens)
            let mouthVisible = setupLens.map { placement.mouthInFrame(markerFromLens: $0, aspect: Float(frame?.aspect ?? 1)) } ?? false
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Color.black
                        .aspectRatio(frame?.aspect ?? 4/3, contentMode: .fit)
                        .overlay {
                            ZStack {
                                if let frame, !inRep || camera == nil {
                                    ZStack {
                                        Image(uiImage: frame.image).resizable()
                                            .accessibilityLabel("Live blade video")
                                        if !inRep {
                                            BladeHeadOverlay(base: placement.markerFromHead, camera: setupLens, failed: $headFailed)
                                                .opacity(setupLens == nil ? 0 : 1)
                                            if let corners = frame.corners {
                                                MarkerOutline(corners: corners)
                                            }
                                        }
                                    }
                                } else if frame == nil {
                                    Text(sample.connection).foregroundStyle(.white)
                                }
                                if inRep {
                                    SyntheticAirwayCamera(mouthFromCamera: camera ?? matrix_identity_float4x4, useResearchScene: true)
                                        .opacity(camera == nil ? 0 : 1)
                                }
                            }
                        }
                        .clipped()
                    Text(inRep ? "Blade view" : "Place head with blade").font(.headline)
                    if inRep {
                        Text(camera == nil ? "Bring the whole QR back into the blade view." : "Move through the placed mouth. Recording is off.")
                        if station == nil {
                            Button("Return to setup") { practicing = false }
                        }
                    } else {
                        if headFailed {
                            Text("The trainer could not load its head model.")
                        } else if let frame {
                            Text(setupHint(frame, scale: scale, mouthVisible: mouthVisible))
                        }
                        Button("Enter airway view") { practicing = true }
                            .disabled(headFailed || !mouthVisible || camera == nil).buttonStyle(.borderedProminent)
                        if let placedScale {
                            Button("Fit head to current view") { self.placedScale = nil }
                            if placedScale != .fullSize {
                                Button("Use life-size head") { self.placedScale = .fullSize }
                            }
                        }
                    }
                }.padding()
            }
            .onChange(of: candidate, initial: true) { _, value in
                if placedScale == nil, let value {
                    placedScale = value
                    NSLog("Trainer setup: head placed at %d percent", Int((value.fraction * 100).rounded()))
                }
            }
        }
        .navigationTitle("Blade practice").navigationBarTitleDisplayMode(.inline)
        .onAppear { TrainerBlade.shared.enable(phase == .active) }
        .onChange(of: phase) { _, p in TrainerBlade.shared.enable(p == .active) }
        .onDisappear { TrainerBlade.shared.enable(false) }
    }

    private func setupHint(_ frame: BladeFrame, scale: TabletopScale?, mouthVisible: Bool) -> String {
        guard frame.corners != nil else { return "Lay the trainer QR flat. Aim the blade at the whole code, including its white border, until an outline appears. The black square should measure 40 mm." }
        guard frame.setupPose != nil else { return "QR found. Face it more squarely so the blade can place the head." }
        guard let scale else { return "QR found. Center its outline in the blade view to place the head." }
        guard mouthVisible else { return "QR found. Pull the blade back and look down at the code until the mouth comes into view." }
        let size = scale == .fullSize ? "Life-size head" : "Head at \(Int((scale.fraction * 100).rounded()))% of life size"
        return "\(size) placed. The mouth is above the QR. Move the blade toward it."
    }
}

private struct MarkerOutline: View {
    let corners: [SIMD2<Double>]

    var body: some View {
        Canvas { context, size in
            let focal = size.width / (2 * TrainerMarker.halfWidthAtUnitDepth)
            let points = corners.map { CGPoint(x: size.width / 2 + $0.x * focal,
                                                y: size.height / 2 + $0.y * focal) }
            var path = Path()
            path.addLines(points)
            path.closeSubpath()
            context.stroke(path, with: .color(.black), lineWidth: 4)
            context.stroke(path, with: .color(.mint), lineWidth: 2)
        }
        .accessibilityHidden(true)
    }
}

private struct BladeHeadOverlay: UIViewRepresentable {
    let base: simd_float4x4
    let camera: simd_float4x4?

    @Binding var failed: Bool

    // Reuse the decoded mesh when a disconnect removes and recreates the preview.
    private static let asset = Bundle.main.url(forResource: "TrainerHead", withExtension: "usdz")
        .flatMap { try? SCNScene(url: $0, options: nil) }

    func makeUIView(context: Context) -> SCNView {
        let view = SCNView()
        view.isOpaque = false
        view.backgroundColor = .clear
        let scene = SCNScene()
        if let asset = Self.asset {
            let head = asset.rootNode.clone()
            var surface = base
            surface.columns.3 += base.columns.1 * 0.012
            head.simdTransform = surface
            scene.rootNode.addChildNode(head)
        } else {
            DispatchQueue.main.async { failed = true }
        }
        let lens = SCNNode()
        lens.camera = SCNCamera()
        lens.camera?.projectionDirection = .horizontal
        lens.camera?.fieldOfView = TrainerMarker.horizontalFOV
        lens.camera?.zNear = 0.001
        scene.rootNode.addChildNode(lens)
        view.scene = scene
        view.autoenablesDefaultLighting = true
        view.pointOfView = lens
        view.isUserInteractionEnabled = false
        return view
    }

    func updateUIView(_ view: SCNView, context: Context) {
        if let camera { view.pointOfView?.simdTransform = camera }
    }
}
#endif
