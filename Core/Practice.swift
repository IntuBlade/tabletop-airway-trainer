import Foundation

enum Opening: String, Codable, CaseIterable {
    case hidden, narrow, partial, broad, full

    var band: String {
        switch self {
        case .hidden: "0%"
        case .narrow: "5–25%"
        case .partial: "30–50%"
        case .broad: "55–75%"
        case .full: "80–100%"
        }
    }

    var visible: Bool { self != .hidden }
}

enum Landmark: String, Codable, CaseIterable {
    case epiglottis, opening

    var title: String { self == .epiglottis ? "Epiglottis" : "Glottic opening" }
}

struct ImagePoint: Codable, Equatable {
    let x: Double
    let y: Double
}

struct LandmarkRegion: Codable, Equatable {
    let center: ImagePoint
    let radiusX: Double
    let radiusY: Double

    func contains(_ point: ImagePoint) -> Bool {
        let dx = (point.x - center.x) / radiusX
        let dy = (point.y - center.y) / radiusY
        return dx * dx + dy * dy <= 1
    }
}

enum Tag: Codable, Equatable {
    case point(ImagePoint), notVisible, unsure
}

enum Finding: String, Codable {
    case correct = "Matches the reference"
    case different = "Review the reference"
    case unsure = "Marked unsure"
    case withheld = "Withheld"
}

struct StillAnswer: Codable {
    var epiglottis: Tag?
    var opening: Tag?
    var estimate: Opening?

    subscript(landmark: Landmark) -> Tag? {
        get { landmark == .epiglottis ? epiglottis : opening }
        set {
            switch landmark {
            case .epiglottis: epiglottis = newValue
            case .opening: opening = newValue
            }
        }
    }

    var complete: Bool { epiglottis != nil && opening != nil && estimate != nil }
}

struct PracticeFrame: Codable, Identifiable {
    let id: Int
    let time: Double
    let opening: Opening?
    let shift: Double
    var tracked = true
    var plausible = true
    var ambiguous: Landmark?

    // Set together for a rendered still. Schematic frames use the drawing below.
    var renderName: String?
    var renderedEpiglottis: LandmarkRegion?
    var renderedOpening: LandmarkRegion?

    func region(for landmark: Landmark) -> LandmarkRegion? {
        if renderName != nil { return landmark == .epiglottis ? renderedEpiglottis : renderedOpening }
        switch landmark {
        case .epiglottis: return LandmarkRegion(center: .init(x: 0.5 + shift, y: 0.33), radiusX: 0.16, radiusY: 0.081)
        case .opening:
            guard let opening, opening.visible else { return nil }
            return LandmarkRegion(center: .init(x: 0.5 + shift, y: 0.61), radiusX: 0.08, radiusY: openingHeight)
        }
    }

    var openingHeight: Double {
        switch opening {
        case .full: 0.20
        case .broad: 0.15
        case .partial: 0.11
        case .narrow: 0.045
        case .hidden, nil: 0
        }
    }

    func assess(_ answer: Tag?, for landmark: Landmark) -> Finding {
        if ambiguous == landmark || (landmark == .opening && opening == nil) { return .withheld }
        switch answer {
        case .unsure: return .unsure
        case .notVisible: return region(for: landmark) == nil ? .correct : .different
        case let .point(point): return region(for: landmark)?.contains(point) == true ? .correct : .different
        case nil: return .withheld
        }
    }
}

enum Recovery: String, Codable, CaseIterable {
    case recovered = "View recovered"
    case noLoss = "Loss of view not demonstrated"
    case endpoints = "Opening not visible on both marks"
    case interrupted = "Tracking interrupted"
    case invalidPath = "Blade path outside the practice space"
}

struct PracticePath {
    static let fixtureVersion = "synthetic-1"
    let frames: [PracticeFrame]
    let minimumLoss: Double

    func recovery(first: Int, last: Int) -> Recovery {
        guard first >= 0, last < frames.count, first < last else { return .endpoints }
        let interval = frames[first...last]
        if interval.contains(where: { !$0.tracked }) { return .interrupted }
        if interval.contains(where: { !$0.plausible }) { return .invalidPath }
        guard frames[first].opening?.visible == true, frames[last].opening?.visible == true else {
            return .endpoints
        }

        var hiddenSince: Double?
        for frame in interval {
            if frame.opening == .hidden {
                if hiddenSince == nil { hiddenSince = frame.time }
            } else {
                if frame.opening?.visible == true, let hiddenSince, frame.time - hiddenSince >= minimumLoss {
                    return .recovered
                }
                hiddenSince = nil
            }
        }
        return .noLoss
    }

    static let recorded = PracticePath(frames: (0..<81).map { index in
        let opening: Opening = switch index {
        case ..<20: .full
        case ..<30: .partial
        case ..<51: .hidden
        case ..<61: .narrow
        default: .partial
        }
        let shift = -0.05 + 0.14 * Double(index) / 80
        return PracticeFrame(id: index, time: Double(index) / 10, opening: opening, shift: shift)
    }, minimumLoss: 0.8)
}

struct CompletedRep: Codable, Identifiable {
    var id = UUID()
    var date = Date()
    let first: Int
    let recovered: Int
    let answers: [StillAnswer]
    let fixtureVersion = PracticePath.fixtureVersion

    enum CodingKeys: String, CodingKey { case id, date, first, recovered, answers, fixtureVersion }

    init(first: Int, recovered: Int, answers: [StillAnswer]) {
        self.first = first
        self.recovered = recovered
        self.answers = answers
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let version = try values.decode(String.self, forKey: .fixtureVersion)
        guard version == fixtureVersion else {
            throw DecodingError.dataCorruptedError(forKey: .fixtureVersion, in: values, debugDescription: "Unknown fixture")
        }
        id = try values.decode(UUID.self, forKey: .id)
        date = try values.decode(Date.self, forKey: .date)
        first = try values.decode(Int.self, forKey: .first)
        recovered = try values.decode(Int.self, forKey: .recovered)
        answers = try values.decode([StillAnswer].self, forKey: .answers)
        guard first >= 0, first < recovered, recovered < PracticePath.recorded.frames.count,
              answers.count == 2, answers.allSatisfy({ $0.complete }) else {
            throw DecodingError.dataCorruptedError(forKey: .answers, in: values, debugDescription: "Incomplete rep")
        }
    }
}

// The moving view, captures and feedback all use the same immutable lesson frames.
struct GuidedRep {
    enum Stage { case find, mark, lose, recover, firstQuestions, secondQuestions, review }
    static let maximumSampleGap = 0.4
    private(set) var stage = Stage.find
    private(set) var first: PracticeFrame?
    private(set) var recovered: PracticeFrame?
    private(set) var current: PracticeFrame?
    private(set) var trackingPaused = false
    private var lastSample: Double?
    private var lossStart: Double?
    private var readyToObserveLoss = false
    var answers = [StillAnswer(), StillAnswer()]

    var capturing: Bool { [.find, .mark, .lose, .recover].contains(stage) }
    var needsUsefulViewBeforeLoss: Bool { stage == .lose && !readyToObserveLoss }

    mutating func observe(_ frame: PracticeFrame?, at time: Double) {
        guard capturing else { return }
        guard let frame, frame.tracked, frame.plausible, frame.opening != nil else {
            pauseTracking()
            return
        }
        if let lastSample {
            guard time > lastSample else { return }
            if time - lastSample > Self.maximumSampleGap { pauseTracking() }
        }
        trackingPaused = false
        lastSample = time
        current = frame
        guard stage == .lose else { return }
        if useful(frame) {
            readyToObserveLoss = true
            lossStart = nil
            return
        }
        guard readyToObserveLoss else { return }
        if let lossStart, time - lossStart >= PracticePath.recorded.minimumLoss {
            stage = .recover
        } else if lossStart == nil {
            lossStart = time
        }
    }

    mutating func pauseTracking() {
        guard capturing, current != nil else { return }
        trackingPaused = true
        lossStart = nil
        readyToObserveLoss = false
    }

    mutating func identify(_ point: ImagePoint) -> Bool {
        guard !trackingPaused, stage == .find, let current,
              current.assess(.point(point), for: .epiglottis) == .correct else {
            return false
        }
        stage = .mark
        return true
    }

    // For this exercise a sliver of the opening is a loss of the useful view.
    private func useful(_ frame: PracticeFrame) -> Bool {
        [.partial, .broad, .full].contains(frame.opening)
    }

    mutating func mark() -> Bool {
        guard !trackingPaused, let current, useful(current) else { return false }
        switch stage {
        case .mark:
            first = current
            readyToObserveLoss = true
            stage = .lose
        case .recover: recovered = current; stage = .firstQuestions
        default: return false
        }
        return true
    }

    mutating func submit() {
        if stage == .firstQuestions && answers[0].complete { stage = .secondQuestions }
        else if stage == .secondQuestions && answers.allSatisfy({ $0.complete }) { stage = .review }
    }

    var matchedBothViews: Bool {
        guard stage == .review, let first, let recovered else { return false }
        return zip([first, recovered], answers).allSatisfy { frame, answer in
            answer.estimate == frame.opening && Landmark.allCases.allSatisfy {
                frame.assess(answer[$0], for: $0) == .correct
            }
        }
    }
}
