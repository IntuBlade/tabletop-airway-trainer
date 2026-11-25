import SwiftUI
import Vision
import QuartzCore
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
    private var lastFrame = -Double.infinity
    private var lastPose: simd_float4x4?
    private var poseTime = -Double.infinity
    private var started = false

    @MainActor func start() {
        guard !started else { return }
        guard ["CFBundleShortVersionString", "CFBundleVersion"].allSatisfy({
            (Bundle.main.object(forInfoDictionaryKey: $0) as? String)?.isEmpty == false
        }) else { return }
        started = true
        EAAccessoryManager.shared().registerForLocalNotifications()
        CameraManager.share().addObserver(self)
        WDLog.share.logLevel = .off
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
            lastPose = nil
            lastFrame = -.infinity
        }
    }

    func snapshot() -> (hasFrames: Bool, pose: simd_float4x4?) {
        lock.withLock {
            let now = CACurrentMediaTime()
            return (now - lastFrame < 0.6, now - poseTime < 0.4 ? lastPose : nil)
        }
    }

    func receive(_ data: Data!, image: UIImage!) {
        guard let cg = image?.cgImage else { return }
        let now = CACurrentMediaTime()
        let ticket: Int? = lock.withLock {
            guard active else { return nil }
            lastFrame = now
            guard !busy else { return nil }
            busy = true
            return generation
        }
        guard let ticket else { return }
        worker.async {
            let pose = try? TrainerMarker.pose(in: cg)
            self.lock.withLock {
                self.busy = false
                guard self.generation == ticket else { return }
                self.lastPose = pose
                self.poseTime = now
            }
        }
    }

    func deviceConnect(with status: CMConnectStatus, param: [AnyHashable: Any]!) {
        if status != .connected && status != .errorButContinue { invalidate() }
    }

    func receiveDeviceConflicted(_ conflicted: Bool) { if conflicted { invalidate() } }

    private func invalidate() {
        lock.withLock { generation += 1; lastPose = nil; lastFrame = -.infinity }
    }
}

struct LiveBladeMotion: View {
    @Environment(\.scenePhase) private var phase
    @State private var reference: BladeRegistration?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.08)) { _ in
            let sample = TrainerBlade.shared.snapshot()
            VStack(alignment: .leading, spacing: 16) {
                if let reference, let pose = reference.mouthFromCamera(referenceFromCamera: sample.pose) {
                    SyntheticAirwayCamera(mouthFromCamera: pose, useResearchScene: true).aspectRatio(3/4, contentMode: .fit)
                } else {
                    ContentUnavailableView(sample.hasFrames ? (sample.pose == nil ? "Looking for trainer marker" : "Marker found") : "Waiting for blade frames",
                                           systemImage: "viewfinder",
                                           description: Text("Connect the blade and aim at the trainer QR on a second screen."))
                }
                Text("Relative motion preview · Recording off").font(.headline)
                Text("Set the starting view, then move or turn the blade while keeping the code visible. Distance and table placement are uncalibrated.")
                Button(reference == nil ? "Set starting view" : "Reset starting view") {
                    if let origin = TrainerBlade.shared.snapshot().pose { reference = BladeRegistration(referenceFromMouth: origin) }
                }.disabled(sample.pose == nil).buttonStyle(.borderedProminent)
            }.padding()
        }
        .navigationTitle("Live blade motion")
        .onAppear { TrainerBlade.shared.enable(phase == .active) }
        .onChange(of: phase) { _, p in reference = nil; TrainerBlade.shared.enable(p == .active) }
        .onDisappear { TrainerBlade.shared.enable(false) }
    }
}
#endif
