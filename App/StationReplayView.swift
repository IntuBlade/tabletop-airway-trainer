import SwiftUI
import simd

private actor StationReplayPlayer {
    let replay = StationReplay()
    var tracker = BladeSurfaceTracker(widthMM: TrainerMarker.standardWidthMM)
    func frame(_ step: StationReplay.Step, index: Int) -> (CGImage, BladeSurfaceTracker.Observation)? {
        autoreleasepool {
            guard let image = replay.image(lens: step.lens, blank: step.blank) else { return nil }
            return (image, tracker.update(image, at: Double(index) * StationReplay.interval))
        }
    }
}

struct StationReplayView: View {
    @State private var run = 0
    @State private var stepName = "Scan at teeth"
    @State private var image: CGImage?
    @State private var observation: BladeSurfaceTracker.Observation?
    @State private var finished = false
    @State private var failed = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if let initial = observation?.initialPose, let pose = observation?.pose {
                    let movement = initial.inverse * pose
                    SyntheticAirwayCamera(mouthFromCamera: SyntheticAirwayCamera.practiceCamera(for: movement),
                                          useResearchScene: true)
                        .aspectRatio(5.0/3, contentMode: .fit)
                        .accessibilityLabel("Airway from the tracked camera")
                } else {
                    Color.black.aspectRatio(5.0/3, contentMode: .fit)
                        .overlay { Text("Acquiring entry").foregroundStyle(.white) }
                }
                Text(stepName).font(.headline)
                if let image {
                    Image(decorative: image, scale: 1).resizable().scaledToFit()
                        .accessibilityLabel("Simulated blade frame")
                }
                if let observation {
                    Text(observation.faces.isEmpty ? observation.evidence.rawValue :
                            observation.faceNames + " · " + observation.evidence.rawValue)
                        .font(.footnote).foregroundStyle(.secondary)
                }
                if failed { Text("Couldn’t render a replay frame.") }
                if finished || failed {
                    Button("Play again") { run += 1 }
                        .buttonStyle(.borderedProminent).tint(trainerActionFill)
                }
            }.padding()
        }
        .navigationTitle("Marker replay")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: run) {
            finished = false
            failed = false
            image = nil
            observation = nil
            let guide = SyntheticAirwayCamera.bladeGuide
            let steps = StationReplay.steps(advance: guide?.advanceMeters ?? 0.06, lift: guide?.fullLift ?? 0.012)
            let player = StationReplayPlayer()
            #if DEBUG
            var tracked = 0, held = 0, outOfView = 0
            #endif
            for (i, step) in steps.enumerated() {
                if Task.isCancelled { return }
                let start = ContinuousClock.now
                guard let frame = await player.frame(step, index: i) else { failed = true; return }
                if Task.isCancelled { return }
                (image, observation) = frame
                stepName = step.name
                #if DEBUG
                if frame.1.state == .tracking { tracked += 1 }
                if frame.1.state == .held { held += 1 }
                if step.name.hasPrefix("Sweep"), frame.1.state == .tracking, !frame.1.faces.contains(.entry) { outOfView += 1 }
                #endif
                do { try await Task.sleep(until: start.advanced(by: .milliseconds(100)), clock: .continuous) }
                catch { return }
            }
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("--station-replay") {
                let status = ["frames": steps.count, "tracked": tracked, "held": held,
                              "sweepFramesWithoutEntry": outOfView, "researchRig": SyntheticAirwayCamera.supportsTissueLift ? 1 : 0]
                try? JSONEncoder().encode(status).write(to: URL.cachesDirectory.appending(path: "StationReplayResult.json"), options: .atomic)
            }
            #endif
            finished = true
        }
    }
}
