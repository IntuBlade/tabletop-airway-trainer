import SwiftUI
import QuartzCore
import CoreImage
import simd
#if canImport(BaseCamera)
import BaseCamera
import ExternalAccessory
#endif


#if canImport(BaseCamera)
struct BladeFrame {
    let image: UIImage
    let corners: [SIMD2<Double>]?
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
            rawPreview = BladeFrame(image: image, corners: nil, practicePose: nil, captured: now)
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
                let practicePose = self.filter.update(pose, at: now)
                self.frame = cg.map {
                    BladeFrame(image: UIImage(cgImage: $0), corners: corners,
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
    @State private var origin: BladeRegistration?

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: phase != .active)) { _ in
            let sample = TrainerBlade.shared.snapshot()
            let frame = sample.frame
            let registration = station ?? origin
            let trackedPose = registration?.mouthFromCamera(referenceFromCamera: frame?.practicePose)
            let camera = station != nil ? trackedPose : trackedPose.map {
                AirwayEntry.camera(for: $0, research: SyntheticAirwayCamera.hasResearchScene)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Color.black
                        .aspectRatio(frame?.aspect ?? 4/3, contentMode: .fit)
                        .overlay {
                            ZStack {
                                if camera == nil {
                                    if let frame {
                                        Image(uiImage: frame.image).resizable()
                                            .accessibilityLabel("Live blade video")
                                        if let corners = frame.corners {
                                            MarkerOutline(corners: corners)
                                        }
                                    } else {
                                        Text(sample.connection).foregroundStyle(.white)
                                    }
                                }
                                if registration != nil {
                                    SyntheticAirwayCamera(
                                        mouthFromCamera: camera ?? matrix_identity_float4x4,
                                        useResearchScene: true
                                    )
                                    .opacity(camera == nil ? 0 : 1)
                                    .accessibilityHidden(camera == nil)
                                }
                            }
                        }
                        .clipShape(.rect(cornerRadius: 14))
                    if camera != nil {
                        Text("Inside the mouth").font(.headline)
                        Text("Advance or withdraw along the mouth. Turn the blade to look around. Recording is off.")
                        if station == nil {
                            Button("Reset to teeth") {
                                if let pose = TrainerBlade.shared.snapshot().frame?.practicePose {
                                    setOrigin(pose)
                                }
                            }
                            .buttonStyle(.bordered)
                        }
                    } else if registration != nil {
                        Text("Tracking paused").font(.headline)
                        Text("Bring the whole QR back into view to resume.")
                    } else {
                        Text("Aim the blade at the QR").font(.headline)
                        Text("Hold the whole 40 mm code in view. Practice starts just inside the teeth when tracking is ready.")
                    }
                }
                .padding()
            }
            .onChange(of: frame?.practicePose == nil ? nil : frame?.captured, initial: true) { _, _ in
                if station == nil, origin == nil, let pose = frame?.practicePose {
                    setOrigin(pose)
                }
            }
        }
        .navigationTitle("Blade practice").navigationBarTitleDisplayMode(.inline)
        .onAppear { TrainerBlade.shared.enable(phase == .active) }
        .onChange(of: phase) { _, value in TrainerBlade.shared.enable(value == .active) }
        .onDisappear { TrainerBlade.shared.enable(false) }
    }

    private func setOrigin(_ pose: simd_float4x4) {
        guard let registration = BladeRegistration.startingAt(referenceFromCamera: pose, mouthFromCamera: matrix_identity_float4x4) else { return }
        origin = registration
        NSLog("Trainer practice: anchored the starting view to the blade pose")
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

#endif
