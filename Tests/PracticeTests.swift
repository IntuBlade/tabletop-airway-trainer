import XCTest
@testable import TrainerCore

final class PracticeTests: XCTestCase {
    let path = PracticePath.recorded

    func testSustainedLossAndPartialReturn() {
        XCTAssertEqual(path.recovery(first: 0, last: 70), .recovered)
        XCTAssertEqual(path.recovery(first: 0, last: 29), .noLoss)
        XCTAssertEqual(path.recovery(first: 0, last: 35), .endpoints)
    }

    func testDropoutAndImpossiblePathCannotEarnCredit() {
        var frames = path.frames
        frames[34].tracked = false
        XCTAssertEqual(PracticePath(frames: frames, minimumLoss: 0.8).recovery(first: 0, last: 70), .interrupted)
        frames[34].tracked = true
        frames[34].plausible = false
        XCTAssertEqual(PracticePath(frames: frames, minimumLoss: 0.8).recovery(first: 0, last: 70), .invalidPath)
        let flicker = Array(path.frames[29...30]) + [PracticeFrame(id: 31, time: 3.1, opening: .partial, shift: 0)]
        XCTAssertEqual(PracticePath(frames: flicker, minimumLoss: 0.8).recovery(first: 0, last: 2), .noLoss)
    }

    func testLandmarkStatusesAreIndependent() {
        var hidden = path.frames[38]
        hidden.ambiguous = .epiglottis
        XCTAssertEqual(hidden.assess(.notVisible, for: .opening), .correct)
        XCTAssertEqual(hidden.assess(.unsure, for: .epiglottis), .withheld)
        let first = path.frames[0]
        XCTAssertEqual(first.assess(.point(first.region(for: .opening)!.center), for: .opening), .correct)
        XCTAssertEqual(first.assess(.unsure, for: .opening), .unsure)
    }
}
