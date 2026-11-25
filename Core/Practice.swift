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

    func region(for landmark: Landmark) -> LandmarkRegion? {
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
