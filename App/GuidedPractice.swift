import SwiftUI

enum GuidedLesson {
    private static let rendered: ([PracticeFrame], [String: UIImage])? = {
        guard let root = Bundle.main.resourceURL?.appending(path: "FixtureReplay/GuidedAirway"),
              let data = try? Data(contentsOf: root.appending(path: "references.json")),
              let frames = try? JSONDecoder().decode([PracticeFrame].self, from: data),
              frames.count == 13 else { return nil }
        var images = [String: UIImage]()
        for (index, frame) in frames.enumerated() {
            guard frame.id == index, frame.renderedEpiglottis != nil, frame.renderedOpening != nil,
                  let name = frame.renderName, let image = UIImage(contentsOfFile: root.appending(path: name).path)
            else { return nil }
            images[name] = image
        }
        return (frames, images)
    }()
    static let images = rendered?.1 ?? [:]
    static let frames: [PracticeFrame] = rendered?.0 ?? (0...12).map { i in
        let band: Opening = switch i {
        case 0...1: .hidden
        case 2...4: .narrow
        case 5...7: .partial
        case 8...9: .broad
        default: .full
        }
        return PracticeFrame(id: i, time: 0, opening: band, shift: Double(i - 6) / 80)
    }
}

struct GuidedPractice: View {
    @Environment(\.scenePhase) private var phase
    @State private var rep = GuidedRep()
    @State private var level = 0
    @State private var useBlade = false
    @State private var baseline: Float?
    @State private var filteredRise: Float = 0
    @State private var lastBladeTime = -Double.infinity
    @State private var hint = ""
    private let frames = GuidedLesson.frames

    var body: some View {
        Group {
            switch rep.stage {
            case .firstQuestions, .secondQuestions:
                let first = rep.stage == .firstQuestions
                if let frame = first ? rep.first : rep.recovered {
                    FrameQuestions(frame: frame, title: first ? "First marked view" : "Recovered view",
                                   answer: $rep.answers[first ? 0 : 1], button: first ? "Next view" : "Reveal both views") {
                        rep.submit()
                    }.id(first)
                }
            case .review:
                review
            default:
                capture
            }
        }
        .navigationTitle(rep.stage == .review ? "Rep review" : "Guided airway practice")
        .navigationBarTitleDisplayMode(.inline)
        .tint(trainerTint)
        .onChange(of: phase) { _, state in
            guard state != .active, rep.capturing else { return }
            if useBlade { rep.pauseTracking() }
            else { reset() }
        }
        .task(id: phase == .active && useBlade && rep.capturing) {
            #if FIXTURE_TRACKING
            guard phase == .active && useBlade && rep.capturing else { return }
            TrainerBlade.shared.enableFixture(true)
            defer { TrainerBlade.shared.enableFixture(false) }
            while !Task.isCancelled {
                pollBlade()
                do { try await Task.sleep(for: .milliseconds(80)) } catch { return }
            }
            #endif
        }
        .task(id: phase == .active && !useBlade && rep.capturing) {
            guard phase == .active && !useBlade && rep.capturing else { return }
            while !Task.isCancelled {
                touchSample()
                do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
            }
        }
    }

    private var capture: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(prompt).font(.title2.bold()).accessibilityAddTraits(.isHeader)
                #if FIXTURE_TRACKING
                if rep.stage == .find {
                    Picker("Practice input", selection: $useBlade) {
                        Text("On screen").tag(false)
                        Text("Blade · Mac target").tag(true)
                    }.pickerStyle(.segmented).onChange(of: useBlade) { _, _ in reset() }
                }
                #endif
                if let frame = rep.current {
                    AirwayFrame(frame: frame, tag: rep.stage == .find && !rep.trackingPaused ? { point in
                        hint = rep.identify(point) ? "" : "Look for the edge of the epiglottis and tap again."
                    } : nil)
                    .accessibilityIdentifier("guided-airway")
                } else {
                    ContentUnavailableView("Waiting for the blade", systemImage: "viewfinder",
                        description: Text("Hold the blade still facing a fixed Mac target mark, then lift your whole hand."))
                }
                if !useBlade {
                    HStack {
                        Button("Release", systemImage: "arrow.down") { move(-1) }.disabled(level == 0)
                        Button("Lift", systemImage: "arrow.up") { move(1) }.disabled(level == frames.count - 1)
                    }.buttonStyle(.bordered).controlSize(.large).buttonRepeatBehavior(.enabled)
                }
                if [.mark, .recover].contains(rep.stage) {
                    Button(rep.stage == .mark ? "Mark useful view" : "Mark recovered view") {
                        hint = rep.mark() ? "" : "Only a sliver is visible. Look for a clearer opening."
                    }.buttonStyle(.borderedProminent).tint(trainerActionFill).controlSize(.large)
                        .disabled(rep.trackingPaused)
                }
                if rep.trackingPaused {
                    Label("Tracking paused", systemImage: "pause.circle").font(.headline)
                    Text(rep.first == nil ? "Aim at the same target to resume." :
                         "Your first view is saved. Aim at the same target to resume.")
                        .font(.callout).foregroundStyle(.secondary)
                } else if !hint.isEmpty {
                    Text(hint).font(.callout)
                }
                if useBlade && rep.first != nil {
                    Button("Restart rep", action: reset).frame(minHeight: 44)
                }
                Text(useBlade ? "Mac target rehearsal · Blade height drives the simulated lift." :
                        "On-screen rehearsal · Use Lift and Release to change the view.")
                    .font(.footnote).foregroundStyle(.secondary)
            }.padding(20).frame(maxWidth: 620).frame(maxWidth: .infinity)
        }
    }

    private var prompt: String {
        switch rep.stage {
        case .find: "Tap the epiglottis"
        case .mark: "Find a useful view of the opening"
        case .lose: rep.needsUsefulViewBeforeLoss ? "Find a useful view again, then ease off." :
            "Ease off until you lose the useful view. Hold there briefly."
        default: "Find the opening again"
        }
    }

    private var review: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text(rep.matchedBothViews ? "Both views matched" : "View recovered · Review your marks")
                    .font(.title2.bold())
                Text("Orange dots show your tags. Teal outlines show the reference regions. POGO ranges are authored for this simulated exercise.")
                    .font(.callout).foregroundStyle(.secondary)
                ForEach(Array([rep.first, rep.recovered].enumerated()), id: \.offset) { index, capture in
                    if let frame = capture {
                        let answer = rep.answers[index]
                        Text(index == 0 ? "First marked view" : "Recovered view").font(.headline)
                        AirwayFrame(frame: frame, selections: answer, showReference: true)
                        ForEach(Landmark.allCases, id: \.self) { landmark in
                            LabeledContent(landmark.title, value: frame.assess(answer[landmark], for: landmark).rawValue)
                        }
                        if let chosen = answer.estimate, let reference = frame.opening {
                            LabeledContent("Your POGO range", value: chosen.band)
                            LabeledContent("Reference range", value: reference.band)
                        }
                    }
                }
                if FirebaseCoach.isConfigured {
                    Text("Next rep").font(.headline)
                    CoachPanel(coachRequest: CoachRequest(guided: rep))
                }
                Button("Try another rep", action: reset).buttonStyle(.borderedProminent).tint(trainerActionFill)
            }.padding(20).frame(maxWidth: 620).frame(maxWidth: .infinity)
        }
    }

    private func move(_ steps: Int) {
        level = min(frames.count - 1, max(0, level + steps))
        hint = ""
        touchSample()
    }

    private func touchSample() { rep.observe(frames[level], at: ProcessInfo.processInfo.systemUptime) }

    private func reset() {
        rep = GuidedRep()
        hint = ""
        level = 0
        baseline = nil
        filteredRise = 0
        lastBladeTime = -.infinity
    }

    #if FIXTURE_TRACKING
    private func pollBlade() {
        guard let sample = TrainerBlade.shared.currentFixture().0, let lens = sample.lens, sample.camera != nil else {
            rep.pauseTracking()
            return
        }
        guard sample.time > lastBladeTime else { return }
        if baseline == nil { baseline = lens.z }
        guard let baseline else { return }
        // The upright Mac target's vertical axis is world Z. This is an optical
        // rehearsal of the modeled 6 mm stroke, separate from a carriage sensor.
        let rise = lens.z - baseline
        if rep.trackingPaused || sample.time - lastBladeTime > GuidedRep.maximumSampleGap {
            // Resume at the measured height on the original calibration.
            filteredRise = rise
            hint = ""
        } else {
            filteredRise += 0.45 * (rise - filteredRise)
        }
        lastBladeTime = sample.time
        level = Int(min(12, max(0, filteredRise * 2)).rounded())
        rep.observe(frames[level], at: sample.time)
    }
    #endif
}
