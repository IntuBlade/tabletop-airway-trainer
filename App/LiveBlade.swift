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
    let observation: BladeSurfaceTracker.Observation
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
    private var rep = 0
    private var locked: BladeSurfaceTracker.Observation?
    private var frameCount = 0
    private var analyzedCount = 0
    private var lastReport = -Double.infinity
    private var frame: BladeFrame?
    #if FIXTURE_TRACKING
    private var fixtureMode = false
    private var fixtureSample: FixtureSample?
    private var fixtureReader: FixtureReader?
    private var fixtureGeneration = -1
    func enableFixture(_ enabled: Bool) {
        enable(enabled, fixture: enabled)
    }
    func currentFixture() -> (FixtureSample?, String) {
        lock.withLock {
            (fixtureSample.flatMap { CACurrentMediaTime() - $0.time < 0.4 ? $0 : nil }, connection)
        }
    }
    #endif
    private var widthMM = TrainerMarker.standardWidthMM
    // Only the serial image worker reads or writes these two fields.
    private var tracker = BladeSurfaceTracker(widthMM: TrainerMarker.standardWidthMM)
    private var trackerGeneration = -1
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

    func enable(_ enabled: Bool, widthMM: Double = TrainerMarker.standardWidthMM, resetRep: Bool = true, fixture: Bool = false) {
        lock.withLock {
            if resetRep {
                rep += 1
                locked = nil
                frameCount = 0
                analyzedCount = 0
            }
            #if FIXTURE_TRACKING
            fixtureMode = fixture
            fixtureSample = nil
            #endif
            active = enabled
            generation += 1
            self.widthMM = widthMM
            frame = nil
            rawPreview = nil
            sawFrame = false
        }
    }

    func snapshot() -> (frame: BladeFrame?, observation: BladeSurfaceTracker.Observation?, rep: Int, connection: String) {
        lock.withLock {
            let now = CACurrentMediaTime()
            let fresh = frame.flatMap { now - $0.captured < 0.4 ? $0 : nil }
            let raw = rawPreview.flatMap { now - $0.captured < 0.4 ? $0 : nil }
            let latest = fresh ?? raw
            return (latest, latest?.observation.pose != nil ? latest?.observation : locked?.held ?? latest?.observation,
                    rep, connection)
        }
    }

    func receive(_ data: Data!, image: UIImage!) {
        guard let image else { return }
        let now = CACurrentMediaTime()
        let ticket: (generation: Int, widthMM: Double, resume: BladeSurfaceTracker.Observation?)? = lock.withLock {
            guard active else { return nil }
            frameCount += 1
            if !sawFrame {
                sawFrame = true
                NSLog("Trainer accessory: received first blade image in setup")
            }
            let prior = locked
            let pending = BladeSurfaceTracker.Observation(state: prior?.pose == nil ? .acquiring : .held,
                                                          pose: prior?.pose, initialPose: prior?.initialPose,
                                                          detectedCorners: nil)
            rawPreview = BladeFrame(image: image, observation: pending, captured: now)
            guard !busy else { return nil }
            busy = true
            return (generation, widthMM, locked)
        }
        guard let ticket else { return }
        worker.async {
            let cg = image.cgImage ?? image.ciImage.flatMap { self.imageContext.createCGImage($0, from: $0.extent) }
            #if FIXTURE_TRACKING
            if self.lock.withLock({ self.fixtureMode && self.generation == ticket.generation }) {
                if self.fixtureGeneration != ticket.generation {
                    self.fixtureReader = FixtureSample.reader()
                    self.fixtureGeneration = ticket.generation
                }
                let sample = cg.flatMap { buffer in self.fixtureReader.map { FixtureSample(image: buffer, reader: $0, time: now, field: 60) } }
                self.lock.withLock {
                    self.busy = false
                    if self.generation == ticket.generation { self.fixtureSample = sample }
                }
                return
            }
            #endif
            if self.trackerGeneration != ticket.generation {
                self.tracker = BladeSurfaceTracker(widthMM: ticket.widthMM, resume: ticket.resume)
                self.trackerGeneration = ticket.generation
            }
            let observation = cg.map { self.tracker.update($0, at: now) }
            let report: TrackingStatus? = self.lock.withLock {
                self.busy = false
                guard self.generation == ticket.generation, let observation, let cg else { return nil }
                // Display the exact frame passed to Vision in its pixel orientation.
                self.frame = BladeFrame(image: UIImage(cgImage: cg), observation: observation, captured: now)
                if observation.pose != nil { self.locked = observation }
                self.analyzedCount += 1
                guard now - self.lastReport >= 1 else { return nil }
                self.lastReport = now
                return TrackingStatus(time: Date(), state: String(describing: observation.state),
                                      received: self.frameCount, analyzed: self.analyzedCount,
                                      lastAnalysisMS: Int((CACurrentMediaTime() - now) * 1000),
                                      decodedQR: observation.detectedCorners != nil, evidence: observation.evidence)
            }
            report?.save()

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
        lock.withLock {
            generation += 1; frame = nil; rawPreview = nil; sawFrame = false
            #if FIXTURE_TRACKING
            fixtureSample = nil
            #endif
        }
    }
}

// One local, overwritten status sample allows a connected researcher to
// distinguish a stopped feed from slow analysis. It contains no image or pose.
private struct TrackingStatus: Encodable {
    let time: Date
    let state: String
    let received: Int
    let analyzed: Int
    let lastAnalysisMS: Int
    let decodedQR: Bool
    let evidence: BladeSurfaceTracker.Evidence

    func save() {
        let url = URL.cachesDirectory.appending(path: "BladeTrackingStatus.json")
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try? encoder.encode(self).write(to: url, options: .atomic)
    }
}

struct LiveBladeMotion: View {
    var station: BladeRegistration? = nil
    @Environment(\.scenePhase) private var phase
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var resetOrigin: (generation: Int, registration: BladeRegistration)?
    @AppStorage("blade-practice-qr-width-mm") private var printedWidth = TrainerMarker.standardWidthMM
    @State private var previousIdlePolicy: Bool?
    @State private var editingWidth = false
    @State private var widthText = ""

    private var effectiveWidth: Double {
        // An AR station was registered against the standard physical image size.
        station == nil ? printedWidth : TrainerMarker.standardWidthMM
    }

    private var enteredWidth: Double? {
        let text = widthText.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: Locale.current.decimalSeparator ?? ".", with: ".")
        guard let value = Double(text), value.isFinite, value > 0 else { return nil }
        return value
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: phase != .active)) { _ in
            let sample = TrainerBlade.shared.snapshot()
            let frame = sample.frame
            let observation = sample.observation
            let initial = observation?.initialPose.flatMap {
                BladeRegistration.startingAt(referenceFromCamera: $0, mouthFromCamera: matrix_identity_float4x4)
            }
            let manual = resetOrigin.flatMap { $0.generation == sample.rep ? $0.registration : nil }
            let registration = station ?? manual ?? initial
            let trackedPose = registration?.mouthFromCamera(referenceFromCamera: observation?.pose)
            let camera = station != nil ? trackedPose : trackedPose.map(SyntheticAirwayCamera.practiceCamera(for:))
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    let panelLayout = typeSize.isAccessibilitySize
                        ? AnyLayout(VStackLayout(alignment: .leading, spacing: 12))
                        : AnyLayout(HStackLayout(alignment: .top, spacing: 8))
                    panelLayout {
                        diagnosticPanel("Airway", aspect: frame?.aspect ?? 4/3) {
                            if registration != nil {
                                SyntheticAirwayCamera(
                                    mouthFromCamera: camera ?? matrix_identity_float4x4,
                                    useResearchScene: true, trackingAvailable: camera != nil
                                )
                                .opacity(camera == nil ? 0 : 1)
                                .accessibilityHidden(camera == nil)
                            }
                            if camera == nil {
                                Text("Waiting for lock")
                            }
                        }
                        diagnosticPanel("Blade camera", aspect: frame?.aspect ?? 4/3) {
                            if let frame {
                                Image(uiImage: frame.image)
                                    .resizable()
                                    .accessibilityLabel("Live blade video")
                                if let corners = frame.observation.detectedCorners {
                                    MarkerOutline(corners: corners)
                                }
                            } else {
                                Text(sample.connection)
                            }
                        }
                    }
                    if let frame {
                        Text((frame.observation.faces.isEmpty ? "" : frame.observation.faceNames + " · ") + frame.observation.evidence.rawValue)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    if camera != nil {
                        if frame == nil {
                            Text("Blade video paused").font(.headline)
                            Text("Your rep is saved in place. Check the blade connection.")
                        } else if observation?.state == .held {
                            Text("Holding your view").font(.headline)
                            Text(observation?.stationMode == true ? "Bring any station marker into view to resume." : "Aim back toward the same tabletop detail or the QR to resume blade motion.")
                        } else {
                            Text("Inside the mouth").font(.headline)
                            if SyntheticAirwayCamera.supportsTissueLift {
                                Text("Advance to the epiglottis. Lift gently to reveal the opening, then lower the blade to release. Recording is off.")
                            } else {
                                Text("Advance or withdraw along the mouth. Turn the blade to look around. Recording is off.")
                            }
                        }
                        if station == nil {
                            Button("Reset to teeth") {
                                let latest = TrainerBlade.shared.snapshot()
                                if latest.observation?.state == .tracking, let pose = latest.observation?.pose,
                                   let registration = BladeRegistration.startingAt(referenceFromCamera: pose,
                                                                                   mouthFromCamera: matrix_identity_float4x4) {
                                    resetOrigin = (latest.rep, registration)
                                }
                            }
                            .buttonStyle(.bordered)
                            .disabled(observation?.state != .tracking)
                        }
                    } else if frame == nil {
                        Text("Waiting for blade video").font(.headline)
                    } else if frame?.observation.detectedCorners != nil {
                        Text("QR found").font(.headline)
                        Text(frame?.observation.evidence == .entryNeeded ? "Find the entry marker to start at the teeth." : "Hold the blade steady while tracking locks.")
                    } else if registration != nil {
                        Text("Tracking paused").font(.headline)
                        Text("Aim at the trainer QR to start blade tracking.")
                    } else {
                        Text("Aim the blade at the QR").font(.headline)
                        Text("Place the QR flat on a textured table. Scan it to start just inside the teeth.")
                    }
                }
                .padding()
            }

        }
        .navigationTitle("Blade practice").navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if station == nil {
                Button("QR size") {
                    widthText = printedWidth.formatted(.number.grouping(.never))
                    editingWidth = true
                }
            }
        }
        .sheet(isPresented: $editingWidth) {
            NavigationStack {
                Form {
                    Section {
                        HStack {
                            TextField("Black square width", text: $widthText)
                                .keyboardType(.decimalPad)
                            Text("mm").foregroundStyle(.secondary)
                        }
                    } footer: {
                        Text("Measure across the printed black square, excluding the white border. The standard sheet measures 40 mm. Changing the width restarts the rep at the teeth.")
                    }
                }
                .navigationTitle("Printed QR size")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { editingWidth = false }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Save") {
                            if let width = enteredWidth, width != printedWidth {
                                printedWidth = width
                                resetOrigin = nil
                                TrainerBlade.shared.enable(phase == .active, widthMM: width)
                            }
                            editingWidth = false
                        }
                        .disabled(enteredWidth == nil)
                    }
                }
            }
        }
        .onAppear {
            TrainerBlade.shared.enable(phase == .active, widthMM: effectiveWidth)
            keepScreenAwake(phase == .active)
        }
        .onChange(of: phase) { _, value in
            TrainerBlade.shared.enable(value == .active, widthMM: effectiveWidth, resetRep: false)
            keepScreenAwake(value == .active)
        }
        .onDisappear {
            TrainerBlade.shared.enable(false)
            keepScreenAwake(false)
        }
    }

    private func diagnosticPanel<Content: View>(
        _ title: String, aspect: CGFloat, @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.caption.weight(.semibold))
            Color.black
                .aspectRatio(aspect, contentMode: .fit)
                .overlay {
                    ZStack(content: content)
                        .font(.caption)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.white)
                }
                .clipShape(.rect(cornerRadius: 12))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func keepScreenAwake(_ active: Bool) {
        if active, previousIdlePolicy == nil {
            previousIdlePolicy = UIApplication.shared.isIdleTimerDisabled
            UIApplication.shared.isIdleTimerDisabled = true
        } else if !active, let previousIdlePolicy {
            UIApplication.shared.isIdleTimerDisabled = previousIdlePolicy
            self.previousIdlePolicy = nil
        }
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
            for point in points {
                let dot = Path(ellipseIn: CGRect(x: point.x - 3, y: point.y - 3, width: 6, height: 6))
                context.stroke(dot, with: .color(.black), lineWidth: 2)
                context.fill(dot, with: .color(.mint))
            }
        }
        .accessibilityHidden(true)
    }
}

#endif
