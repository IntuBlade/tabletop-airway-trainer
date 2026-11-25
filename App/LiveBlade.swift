import SwiftUI
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
    private var lastFrame = -Double.infinity
    private var lastPose: simd_float4x4?
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
            lastPose = nil
            lastFrame = -.infinity
        }
    }

    func snapshot() -> (hasFrames: Bool, pose: simd_float4x4?, connection: String) {
        lock.withLock {
            let now = CACurrentMediaTime()
            return (now - lastFrame < 0.6, now - poseTime < 0.4 ? lastPose : nil, connection)
        }
    }

    func receive(_ data: Data!, image: UIImage!) {
        guard let image else { return }
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
            let cg = image.cgImage ?? image.ciImage.flatMap { self.imageContext.createCGImage($0, from: $0.extent) }
            let pose = cg.flatMap { try? TrainerMarker.pose(in: $0) }
            self.lock.withLock {
                self.busy = false
                guard self.generation == ticket else { return }
                self.lastPose = pose
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
                    ContentUnavailableView(sample.hasFrames ? (sample.pose == nil ? "Looking for trainer marker" : "Marker found") : sample.connection,
                                           systemImage: "viewfinder",
                                           description: Text(sample.hasFrames ? "Aim at the trainer QR on a second screen." : "The marker detector starts when the SDK delivers a blade image."))
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
