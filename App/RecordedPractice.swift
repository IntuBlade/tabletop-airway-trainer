import SwiftUI

private let path = PracticePath.recorded

struct RecordedPractice: View {
    let save: (CompletedRep) -> Void
    @State private var stage = Stage.capture
    @State private var position = 0.0
    @State private var playing = false
    @State private var first: Int?
    @State private var second: Int?
    @State private var answers = [StillAnswer(), StillAnswer()]
    @State private var completed: CompletedRep?
    @State private var showingExplore = false

    private enum Stage { case capture, first, recovered, review }
    private var index: Int { min(Int(position), path.frames.count - 1) }

    var body: some View {
        Group {
            switch stage {
            case .capture:
                capture
            case .first:
                if let first { answerScreen(index: first, slot: 0) }
            case .recovered:
                if let second { answerScreen(index: second, slot: 1) }
            case .review:
                if let completed { PracticeReview(rep: completed, retry: reset) }
            }
        }
        .navigationTitle(stage == .review ? "Rep review" : "Recorded practice")
        .navigationBarTitleDisplayMode(.inline)
        .tint(trainerTint)
        .toolbar {
            if stage == .capture && first == nil {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Explore") { playing = false; showingExplore = true }
                }
            }
        }
        .task(id: playing) {
            guard playing else { return }
            while position < Double(path.frames.count - 1) {
                do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
                position += 1
            }
            playing = false
        }
        .onDisappear { playing = false }
        .sheet(isPresented: $showingExplore) { ExplorePractice() }
    }

    private var capture: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text(first == nil ? "Find the opening" : "Lose the view, then recover it").font(.title2.bold())
                Text("Play the example and mark the opening twice: when you first see it and when it returns.")
                    .font(.subheadline).foregroundStyle(.secondary)

                AirwayFrame(frame: path.frames[index])
                HStack {
                    Button(playing ? "Pause example" : "Play example") {
                        if position >= Double(path.frames.count - 1) { reset() }
                        playing.toggle()
                    }.buttonStyle(.bordered)
                    Spacer()
                    Text(path.frames[index].time.formatted(.number.precision(.fractionLength(1))) + " / 8 s")
                        .font(.caption.monospacedDigit())
                }

                Button("Mark view") {
                    if first == nil {
                        first = index
                    } else {
                        playing = false
                        second = index
                        stage = .first
                    }
                }
                .buttonStyle(.borderedProminent).tint(trainerActionFill)
                .controlSize(.large)
                .disabled(first.map { index <= $0 } ?? false)

                if first != nil {
                    Button("Restart recording exercise", action: reset).frame(minHeight: 44)
                }
            }.padding(20).frame(maxWidth: 620).frame(maxWidth: .infinity)
        }
    }

    private func answerScreen(index: Int, slot: Int) -> some View {
        FrameQuestions(frame: path.frames[index], title: slot == 0 ? "First marked view" : "Recovered view",
                       answer: $answers[slot], button: slot == 0 ? "Next view" : "Reveal both views") {
            if slot == 0 {
                stage = .recovered
            } else if let first, let second {
                let rep = CompletedRep(first: first, recovered: second, answers: answers)
                completed = rep
                save(rep)
                stage = .review
            }
        }.id(slot)
    }

    private func reset() {
        playing = false
        stage = .capture
        position = 0
        first = nil
        second = nil
        answers = [StillAnswer(), StillAnswer()]
        completed = nil
    }
}

private struct ExplorePractice: View {
    @Environment(\.dismiss) private var dismiss
    @State private var index = 0.0

    var body: some View {
        NavigationStack {
            ScrollView {
                let frame = path.frames[Int(index)]
                VStack(alignment: .leading, spacing: 16) {
                    Text("Scrub through the synthetic view to see when each landmark appears.")
                        .foregroundStyle(.secondary)
                    AirwayFrame(frame: frame, showReference: true)
                    Slider(value: $index, in: 0...Double(path.frames.count - 1), step: 1) {
                        Text("Explore blade position")
                    }
                    ForEach(Landmark.allCases, id: \.self) { landmark in
                        LabeledContent(landmark.title, value: frame.region(for: landmark) == nil ? "Hidden" : "Visible")
                    }
                    if let opening = frame.opening { LabeledContent("POGO range", value: opening.band) }
                }.padding(20)
            }
            .navigationTitle("Explore synthetic views")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .tint(trainerTint)
    }
}

private struct FrameQuestions: View {
    let frame: PracticeFrame
    let title: String
    @Binding var answer: StillAnswer
    let button: String
    let next: () -> Void
    @State private var activeLandmark = Landmark.epiglottis

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(title).font(.title2.bold())
                Text("Choose a landmark, then tap its location on the frame.")
                    .foregroundStyle(.secondary)
                Picker("Landmark to tag", selection: $activeLandmark) {
                    ForEach(Landmark.allCases, id: \.self) { landmark in
                        Text(landmark.title).tag(landmark)
                    }
                }.pickerStyle(.segmented)
                AirwayFrame(frame: frame, selections: answer) { point in answer[activeLandmark] = .point(point) }
                HStack {
                    Button("Not visible") { answer[activeLandmark] = .notVisible }
                    Button("Unsure") { answer[activeLandmark] = .unsure }
                }.buttonStyle(.bordered).controlSize(.large)
                ForEach(Landmark.allCases, id: \.self) { landmark in
                    LabeledContent(landmark.title, value: tagLabel(answer[landmark]))
                        .font(.subheadline)
                }
                Picker("POGO range", selection: $answer.estimate) {
                    Text("Select range").tag(Opening?.none)
                    ForEach(Opening.allCases, id: \.self) { Text($0.band).tag(Optional($0)) }
                }.frame(minHeight: 44)
                Button(button, action: next)
                    .buttonStyle(.borderedProminent).tint(trainerActionFill).controlSize(.large)
                    .disabled(!answer.complete)
            }.padding(20).frame(maxWidth: 620).frame(maxWidth: .infinity)
        }
    }

    private func tagLabel(_ tag: Tag?) -> String {
        switch tag {
        case .point: "Tagged"
        case .notVisible: "Not visible"
        case .unsure: "Unsure"
        case nil: "Choose response"
        }
    }
}

struct PracticeReview: View {
    let rep: CompletedRep
    var retry: (() -> Void)? = nil
    @State private var replay = 0.0
    @State private var askingCloud = false
    @State private var request: CoachRequestID?
    @State private var coaching: CoachResult?
    @State private var coachAttempted = false

    private var result: Recovery { path.recovery(first: rep.first, last: rep.recovered) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text(result.rawValue).font(.title2.bold())
                Text("Recorded movement · Synthetic reference")
                    .font(.subheadline).foregroundStyle(.secondary)

                ForEach(Array([rep.first, rep.recovered].enumerated()), id: \.offset) { slot, index in
                    let frame = path.frames[index]
                    let answer = rep.answers[slot]
                    Text(slot == 0 ? "First marked view" : "Recovered view").font(.headline)
                    AirwayFrame(frame: frame, selections: answer, showReference: true)
                    ForEach(Landmark.allCases, id: \.self) { landmark in
                        LabeledContent(landmark.title, value: frame.assess(answer[landmark], for: landmark).rawValue)
                            .font(.subheadline)
                    }
                    if let opening = frame.opening, let estimate = answer.estimate {
                        LabeledContent("POGO range", value: "\(estimate.band) marked · \(opening.band) reference")
                            .font(.subheadline)
                    }
                }
                Text("Replay").font(.headline)
                AirwayFrame(frame: path.frames[min(Int(replay), path.frames.count - 1)], showReference: true)
                Slider(value: $replay, in: 0...Double(path.frames.count - 1), step: 1) { Text("Replay position") }

                Text("Next rep").font(.headline)
                Text(result == .recovered ? "Try recovering the view at a different blade angle." :
                        "On your next rep, make the loss of view clear before you mark the return.")
                if FirebaseCoach.isConfigured { coachControls }
                if let retry {
                    Button("Try another rep", action: retry).buttonStyle(.borderedProminent).tint(trainerActionFill).controlSize(.large)
                }
            }.padding(20).frame(maxWidth: 620).frame(maxWidth: .infinity)
        }
        .task(id: request) {
            guard let request else { return }
            let result = await FirebaseCoach.coach(CoachRequest(rep: rep, path: path), allowCloud: request.allowCloud)
            guard !Task.isCancelled else { return }
            coaching = result
            coachAttempted = true
            self.request = nil
        }
        .confirmationDialog("Allow cloud coaching for this rep?", isPresented: $askingCloud, titleVisibility: .visible) {
            Button("Allow for this rep") { request = CoachRequestID(allowCloud: true) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("If the iPhone model is unavailable, Firebase receives the synthetic practice outcome and the marked and reference ranges.")
        }
        .navigationTitle("Rep review")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var coachControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let coaching {
                Text(coaching.route.rawValue).font(.subheadline.bold())
                Text(coaching.text)
            } else if coachAttempted {
                Text("Coaching unavailable. Use the next-rep objective above.").foregroundStyle(.secondary)
            }
            if request != nil { ProgressView("Checking coaching") }
            Button("Coach on this iPhone") { request = CoachRequestID(allowCloud: false) }
                .disabled(request != nil)
                .frame(minHeight: 44)
            Button("Allow cloud fallback") { askingCloud = true }
                .disabled(request != nil)
                .frame(minHeight: 44)
        }
    }
}
