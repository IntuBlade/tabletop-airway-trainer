import SwiftUI
import SceneKit
import Vision
import QuartzCore
import CoreImage
#if canImport(BaseCamera)
import BaseCamera
import ExternalAccessory
import WDLogger
#endif


#if canImport(BaseCamera)
final class TrainerBlade: NSObject, CameraDelegate, @unchecked Sendable {
    static let shared = TrainerBlade()
    private let lock = NSLock()
    private let worker = DispatchQueue(label: "trainer.marker")
    private var active = false
    private var busy = false
    private var generation = 0
    private var latestImage: UIImage?
    private var lastFrame = -Double.infinity
    private var lastPose: simd_float4x4?
    private var sequence = MarkerSequence()
    private var filter = BladePoseFilter()
    private var poseTime = -Double.infinity
    private var started = false
    private let imageContext = CIContext()
    private var connection = "Waiting for blade connection"
    private var sdkMessage: NSObjectProtocol?

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
        sdkMessage = NotificationCenter.default.addObserver(forName: .WDLogMessage, object: nil, queue: nil) { [weak self] note in
            let text = String(describing: note.object).lowercased()
            if text.contains("not supported") && (text.contains("bundle") || text.contains("protocol")) {
                self?.setConnection("Camera SDK rejected this app identity")
            }
        }
        WDLog.share.logNotifiy = true
        WDLog.share.logLevel = .info
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
            lastPose = nil
            latestImage = nil
            lastFrame = -.infinity
        }
    }

    func snapshot() -> (image: UIImage?, pose: simd_float4x4?, connection: String) {
        lock.withLock {
            let now = CACurrentMediaTime()
            return (now - lastFrame < 0.6 ? latestImage : nil, now - poseTime < 0.4 ? lastPose : nil, connection)
        }
    }

    func receive(_ data: Data!, image: UIImage!) {
        guard let image else { return }
        let now = CACurrentMediaTime()
        let ticket: Int? = lock.withLock {
            guard active else { return nil }
            latestImage = image
            lastFrame = now
            guard !busy else { return nil }
            busy = true
            return generation
        }
        guard let ticket else { return }
        worker.async {
            let cg = image.cgImage ?? image.ciImage.flatMap { self.imageContext.createCGImage($0, from: $0.extent) }
            let corners = cg.flatMap { try? TrainerMarker.corners(in: $0) }
            self.lock.withLock {
                self.busy = false
                guard self.generation == ticket else { return }
                let pose = self.sequence.pose(corners, at: now)
                self.lastPose = self.filter.update(pose, at: now)
                self.poseTime = now
            }
        }
    }

    func deviceConnect(with status: CMConnectStatus, param: [AnyHashable: Any]!) {
        let report = String(describing: param).lowercased()
        if report.contains("not supported") {
            setConnection("Camera SDK rejected this app identity")
        } else {
            switch status {
            case .connected: setConnection("Blade connected; waiting for images")
            case .errorButContinue: setConnection("Blade reported a license warning")
            case .disconnected: setConnection("Blade disconnected")
            case .error: setConnection("Blade SDK connection error")
            case .connecting, .connectedAndCheckingLicence: setConnection("Checking blade connection")
            @unknown default: setConnection("Unknown blade connection state")
            }
        }
        if status != .connected && status != .errorButContinue { invalidate() }
    }

    func receiveDeviceConflicted(_ conflicted: Bool) { if conflicted { invalidate(); setConnection("Blade in use by another app") } }

    private func invalidate() {
        lock.withLock { generation += 1; sequence = MarkerSequence(); filter = BladePoseFilter(); lastPose = nil; latestImage = nil; lastFrame = -.infinity }
    }
}

struct LiveBladeMotion: View {
    var station: BladeRegistration? = nil
    @Environment(\.scenePhase) private var phase
    @State private var placement: BladeTablePlacement?
    @State private var practicing = false

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: phase != .active)) { _ in
            let sample = TrainerBlade.shared.snapshot()
            let registered = station ?? placement?.station
            let inRep = practicing || station != nil
            let camera = registered?.mouthFromCamera(referenceFromCamera: sample.pose)
            let candidate = sample.pose.flatMap { BladeTablePlacement(markerFromLens: $0) }
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ZStack {
                        if inRep {
                            SyntheticAirwayCamera(mouthFromCamera: camera ?? matrix_identity_float4x4, useResearchScene: true)
                                .opacity(camera == nil ? 0 : 1)
                        }
                        if !inRep || camera == nil {
                            if let image = sample.image {
                                Image(uiImage: image).resizable().scaledToFit()
                                    .accessibilityLabel("Live blade video")
                                    .overlay {
                                        if !inRep, let placement {
                                            BladeHeadOverlay(base: placement.markerFromHead, camera: sample.pose)
                                                .opacity(sample.pose == nil ? 0 : 1)
                                        } else if !inRep {
                                            Image(systemName: "plus").foregroundStyle(.white)
                                                .shadow(color: .black, radius: 2)
                                        }
                                    }
                            } else {
                                ContentUnavailableView(sample.connection, systemImage: "viewfinder")
                            }
                        }
                    }
                    .aspectRatio(sample.image.map { $0.size.width / max(1, $0.size.height) } ?? 4/3, contentMode: .fit)
                    Text(inRep ? "Blade view" : "Blade camera setup").font(.headline)
                    if inRep {
                        Text(camera == nil ? "Bring the whole QR back into the blade view." : "Move through the placed mouth. Recording is off.")
                    } else if placement == nil {
                        Text("Lay the trainer QR flat with its black square 40 mm wide. Keep the code in the blade view and aim the crosshair where the head should rest.")
                        Button("Place head here") {
                            placement = TrainerBlade.shared.snapshot().pose.flatMap { BladeTablePlacement(markerFromLens: $0) }
                        }.disabled(candidate == nil).buttonStyle(.borderedProminent)
                    } else {
                        Text(sample.pose == nil ? "Find the QR again to see the placed head." : "The head is fixed to the table reference. Keep the QR still.")
                        Button("Enter airway view") { practicing = true }
                            .disabled(sample.pose == nil).buttonStyle(.borderedProminent)
                    }
                    if station == nil && placement != nil {
                        Button("Place again") { practicing = false; placement = nil }
                    }
                }.padding()
            }
        }
        .navigationTitle("Blade practice").navigationBarTitleDisplayMode(.inline)
        .onAppear { TrainerBlade.shared.enable(phase == .active) }
        .onChange(of: phase) { _, p in TrainerBlade.shared.enable(p == .active) }
        .onDisappear { TrainerBlade.shared.enable(false) }
    }
}

private struct BladeHeadOverlay: UIViewRepresentable {
    let base: simd_float4x4
    let camera: simd_float4x4?

    func makeUIView(context: Context) -> SCNView {
        let view = SCNView()
        view.isOpaque = false
        view.backgroundColor = .clear
        let scene = SCNScene()
        if let url = Bundle.main.url(forResource: "TrainerHead", withExtension: "usdz"),
           let head = SCNReferenceNode(url: url) {
            head.load()
            var surface = base
            surface.columns.3 += base.columns.1 * 0.012
            head.simdTransform = surface
            scene.rootNode.addChildNode(head)
        }
        let lens = SCNNode()
        lens.camera = SCNCamera()
        lens.camera?.projectionDirection = .horizontal
        lens.camera?.fieldOfView = 68
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
