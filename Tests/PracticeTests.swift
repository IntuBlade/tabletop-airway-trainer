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

import simd

final class BladeRegistrationTests: XCTestCase {
    func testCommonReferenceCancelsRotationAndOffset() throws {
        var head = simd_float4x4(simd_quatf(angle: .pi / 3, axis: [0, 1, 0]))
        head.columns.3 = [0.25, 0.08, -0.1, 1]
        var desired = simd_float4x4(simd_quatf(angle: .pi / 7, axis: [1, 0, 0]))
        desired.columns.3.z = -0.042
        let pose = try XCTUnwrap(BladeRegistration(referenceFromMouth: head)
            .mouthFromCamera(referenceFromCamera: head * desired))
        for column in 0..<4 { XCTAssertLessThan(simd_length(pose[column] - desired[column]), 0.00001) }
    }

    func testDropoutAndInvalidCalibrationYieldNoView() {
        var mirrored = matrix_identity_float4x4
        mirrored.columns.0.x = -1
        XCTAssertNil(BladeRegistration(referenceFromMouth: mirrored).mouthFromCamera(referenceFromCamera: matrix_identity_float4x4))
        XCTAssertNil(BladeRegistration(referenceFromMouth: matrix_identity_float4x4).mouthFromCamera(referenceFromCamera: nil))
    }
}

extension BladeRegistrationTests {
    func testTiltedTargetRecoversCameraInMeters() throws {
        let rotation = simd_double3x3(simd_quatd(angle: 0.4, axis: [0,1,0]))
        let translation = SIMD3<Double>(0.01, -0.02, 0.28)
        let corners = [SIMD2<Double>(-1,-1), [1,-1], [1,1], [-1,1]].map { p in
            let v = rotation * SIMD3(p.x * 0.025, p.y * 0.025, 0) + translation
            return SIMD2(v.x, v.y) / v.z
        }
        let pose = try XCTUnwrap(SquarePose.referenceFromCamera(corners: corners, sideMeters: 0.05, maxNormalizedError: 1e-6))
        let expected = -(rotation.transpose * translation)
        for axis in 0..<3 { XCTAssertEqual(Double(pose.columns.3[axis]), expected[axis], accuracy: 1e-6) }
        XCTAssertNil(SquarePose.referenceFromCamera(corners: corners.reversed(), sideMeters: 0.05, maxNormalizedError: 1e-6))
        var distorted = corners
        distorted[2].x += 0.04
        XCTAssertNil(SquarePose.referenceFromCamera(corners: distorted, sideMeters: 0.05, maxNormalizedError: 1e-6))
    }
}

import CoreImage
import ImageIO

final class MarkerDetectorTests: XCTestCase {
    func testPublishedMarkerMovesCameraAndLossClearsPose() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Artwork/motion-marker.png")
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        let qr = CIImage(cgImage: try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil)))
        let bounds = CGRect(x: 0, y: 0, width: qr.extent.width * 2, height: qr.extent.height)
        let white = CIImage(color: .white).cropped(to: bounds)
        let context = CIContext()
        func frame(_ image: CIImage) throws -> CGImage {
            try XCTUnwrap(context.createCGImage(image, from: bounds))
        }
        func pose(_ shift: Double) throws -> simd_float4x4 {
            let shifted = qr.transformed(by: .init(translationX: shift, y: 0)).composited(over: white)
            return try XCTUnwrap(TrainerMarker.pose(in: frame(shifted)))
        }
        let start = try pose(0)
        let moved = try pose(100)
        XCTAssertGreaterThan(abs(start.columns.3.x - moved.columns.3.x), 0.001)
        XCTAssertNil(try TrainerMarker.pose(in: frame(white)))
    }
}

extension BladeRegistrationTests {
    func testTableRegistrationIndependentOfWorldOrigin() {
        var world = simd_float4x4(simd_quatf(angle: 0.7, axis: [0,1,0]))
        world.columns.3 = [0.2,0.4,0.8,1]
        var head = matrix_identity_float4x4
        head.columns.3.x = 0.18
        let a = TableStation.registration(worldFromImage: matrix_identity_float4x4, worldFromHeadBase: head)
        let b = TableStation.registration(worldFromImage: world, worldFromHeadBase: world * head)
        for i in 0..<4 { XCTAssertLessThan(simd_length(a.referenceFromMouth[i]-b.referenceFromMouth[i]), 0.00001) }
    }
    func testFilterReducesJitterAndClearsImmediatelyOnLoss() throws {
        var filter = BladePoseFilter()
        var pose = matrix_identity_float4x4
        _ = filter.update(pose, at: 0)
        pose.columns.3.x = 0.01
        let x = try XCTUnwrap(filter.update(pose, at: 0.03)).columns.3.x
        XCTAssertGreaterThan(x, 0)
        XCTAssertLessThan(x, 0.01)
        XCTAssertNil(filter.update(nil, at: 0.06))
        XCTAssertEqual(filter.update(pose, at: 0.09)?.columns.3.x, 0.01)
    }
}

extension MarkerDetectorTests {
    func testCornerSpikeDuringWithdrawalAndMarkerLoss() throws {
        var sequence = MarkerSequence()
        func corners(_ z: Double) -> [SIMD2<Double>] {
            [SIMD2(-1,-1), [1,-1], [1,1], [-1,1]].map { $0 * (0.02 / z) }
        }
        for i in 0..<3 { _ = sequence.pose(corners(0.12), at: Double(i)/30) }
        let spike = try XCTUnwrap(sequence.pose(corners(0.22), at: 0.1))
        XCTAssertEqual(abs(spike.columns.3.z), 0.12, accuracy: 0.001)
        for i in 4..<12 {
            let z = 0.12 + Double(i-3)*0.003
            let pose = try XCTUnwrap(sequence.pose(corners(z), at: Double(i)/30))
            XCTAssertEqual(Double(abs(pose.columns.3.z)), z-0.003, accuracy: 0.004)
        }
        XCTAssertNil(sequence.pose(nil, at: 0.4))
        XCTAssertNil(sequence.pose(corners(0.18), at: 0.45))
    }
}

extension BladeRegistrationTests {
    func testNearlySquareDetectionKeepsRaisedMouthOverCenteredQR() throws {
        // Asymmetry observed by Vision on a 109-pixel-wide synthetic overhead QR.
        let corners: [SIMD2<Double>] = [[-0.05854,-0.05854],[0.05835,-0.05835],
                                        [0.05696,0.05696],[-0.05835,0.05835]]
        let lens = try XCTUnwrap(TrainerMarker.solve(corners))
        let mouth = lens.inverse * SIMD4<Float>(0,0,-0.135,1)
        XCTAssertLessThan(simd_length(SIMD2(mouth.x,mouth.y) / mouth.z), 0.002)
    }

    func testFirstQRLockStartsAtTeethAndKeepsReferenceAcrossMovement() throws {
        var startingBlade = simd_float4x4(simd_quatf(angle: 2.7, axis: [1, 0, 0]))
        startingBlade.columns.3 = [0.015, -0.02, -0.18, 1]
        let teeth = AirwayEntry.camera(for: matrix_identity_float4x4, research: true)
        let registration = try XCTUnwrap(BladeRegistration.startingAt(
            referenceFromCamera: startingBlade, mouthFromCamera: teeth
        ))

        var advanceAndTurn = simd_float4x4(simd_quatf(angle: 0.24, axis: [0, 1, 0]))
        advanceAndTurn.columns.3 = [0.004, 0, -0.022, 1]
        func check(_ blade: simd_float4x4, _ expected: simd_float4x4) throws {
            let rendered = try XCTUnwrap(registration.mouthFromCamera(referenceFromCamera: blade))
            for column in 0..<4 {
                XCTAssertLessThan(simd_length(rendered[column] - expected[column]), 0.00001)
            }
        }

        try check(startingBlade, teeth)
        try check(startingBlade * advanceAndTurn, teeth * advanceAndTurn)
        XCTAssertNil(registration.mouthFromCamera(referenceFromCamera: nil))
        try check(startingBlade * advanceAndTurn, teeth * advanceAndTurn)
        try check(startingBlade, teeth)
    }

    func testRealDepthAdvancesAlongOralPathAndBackToStart() {
        let start = AirwayEntry.camera(for: matrix_identity_float4x4, research: true)
        var movement = matrix_identity_float4x4
        movement.columns.3.z = -0.070
        let throat = AirwayEntry.camera(for: movement, research: true)
        for column in 0..<4 {
            XCTAssertLessThan(simd_length(throat[column] - matrix_identity_float4x4[column]), 0.00001)
        }

        movement = simd_float4x4(simd_quatf(angle: 0.2, axis: [0, 1, 0]))
        let turned = AirwayEntry.camera(for: movement, research: true)
        for column in 0..<4 {
            XCTAssertLessThan(simd_length(turned[column] - (start * movement)[column]), 0.00001)
        }
    }
}

extension MarkerDetectorTests {
    func testPrintedScaleWithActualQRDetectionAndReacquisition() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Artwork/motion-marker.png")
        let qr = try XCTUnwrap(CIImage(contentsOf: url))
        let bounds = CGRect(x: 0, y: 0, width: 640, height: 480)
        let paper = CIImage(color: .white).cropped(to: bounds)
        let context = CIContext()
        func detect(_ image: CIImage) throws -> [SIMD2<Double>]? {
            try TrainerMarker.corners(in: XCTUnwrap(context.createCGImage(image, from: bounds)))
        }
        for width in [40.0, 160.0] {
            func observation(distanceMM: Double) throws -> [SIMD2<Double>] {
                // The shipped PNG's black code spans 522 source pixels.
                let focal = bounds.width / (2 * TrainerMarker.halfWidthAtUnitDepth)
                let scale = focal * width / distanceMM / 522
                let image = qr.transformed(by: .init(scaleX: scale, y: scale))
                let centered = image.transformed(by: .init(translationX: bounds.midX - image.extent.midX,
                                                           y: bounds.midY - image.extent.midY))
                return try XCTUnwrap(detect(centered.composited(over: paper)))
            }
            let far = try observation(distanceMM: 200)
            let near = try observation(distanceMM: 180)
            var tracker = MarkerSequence(widthMM: width)
            func lock(_ corners: [SIMD2<Double>], tick: Int) throws -> simd_float4x4 {
                XCTAssertNil(tracker.pose(corners, at: Double(tick)/30))
                XCTAssertNil(tracker.pose(corners, at: Double(tick+1)/30))
                return try XCTUnwrap(tracker.pose(corners, at: Double(tick+2)/30))
            }
            let start = try lock(far, tick: 0)
            let missing = try detect(paper)
            XCTAssertNil(missing)
            XCTAssertNil(tracker.pose(missing, at: 0.1))
            let end = try lock(near, tick: 4)
            let travel = abs((start.inverse * end).columns.3.z)
            print("Rendered QR \(width) mm, 20 mm advance measured \(travel * 1000) mm")
            XCTAssertEqual(travel, 0.020, accuracy: 0.003)
            if width == 160 {
                let oldStart = try XCTUnwrap(TrainerMarker.solve(far))
                let oldEnd = try XCTUnwrap(TrainerMarker.solve(near))
                XCTAssertEqual(abs((oldStart.inverse * oldEnd).columns.3.z), 0.005, accuracy: 0.001)
            }
        }
    }
}

final class GuidedRepTests: XCTestCase {
    let stop = PracticeFrame(id: 12, time: 0, opening: .full, shift: 0.08)
    let sliver = PracticeFrame(id: 1, time: 0, opening: .narrow, shift: -0.07)
    let partial = PracticeFrame(id: 6, time: 0, opening: .partial, shift: 0)
    var rep = GuidedRep()

    func testStopAndRepeatedMarksCannotAdvance() {
        for t in 0...20 { rep.observe(stop, at: Double(t) / 10) }
        XCTAssertFalse(rep.identify(.init(x: 0.1, y: 0.9)))
        XCTAssertFalse(rep.mark())
        XCTAssertTrue(rep.identify(stop.region(for: .epiglottis)!.center))
        XCTAssertTrue(rep.mark())
        for t in 21...40 { rep.observe(stop, at: Double(t) / 10) }
        XCTAssertFalse(rep.mark())
        rep.submit()
        XCTAssertEqual(rep.stage, .lose)
        XCTAssertFalse(rep.matchedBothViews)
    }

    func testLostSamplesCannotBecomeAnatomicalLoss() {
        start()
        rep.observe(sliver, at: 0.1)
        rep.observe(nil, at: 0.2)
        XCTAssertTrue(rep.trackingPaused)
        XCTAssertEqual(rep.current?.id, sliver.id)
        XCTAssertEqual(rep.stage, .lose)
        XCTAssertEqual(rep.first?.id, stop.id)
        for tick in 3...13 { rep.observe(sliver, at: Double(tick) / 10) }
        XCTAssertFalse(rep.trackingPaused)
        XCTAssertEqual(rep.stage, .lose)
        rep.observe(partial, at: 1.4)
        XCTAssertFalse(rep.mark())
        for tick in 15...25 { rep.observe(sliver, at: Double(tick) / 10) }
        XCTAssertEqual(rep.stage, .recover)
        rep.observe(partial, at: 2.6)
        XCTAssertTrue(rep.mark())
        XCTAssertEqual(rep.first?.id, stop.id)
        XCTAssertEqual(rep.recovered?.id, partial.id)
    }

    func testUnreportedGapDoesNotResetOrCreditLoss() {
        start()
        rep.observe(sliver, at: 0.2)
        rep.observe(sliver, at: 1.1)
        XCTAssertEqual(rep.stage, .lose)
        XCTAssertEqual(rep.first?.id, stop.id)
        rep.observe(partial, at: 1.2)
        XCTAssertFalse(rep.mark())
    }

    func testPausedFrameCannotBeMarkedAndConfirmedLossSurvivesPause() {
        start()
        for tick in 1...11 { rep.observe(sliver, at: Double(tick) / 10) }
        rep.observe(partial, at: 1.2)
        rep.pauseTracking()
        XCTAssertEqual(rep.stage, .recover)
        XCTAssertFalse(rep.mark())
        rep.observe(partial, at: 1.3)
        XCTAssertTrue(rep.mark())
        XCTAssertEqual(rep.first?.id, stop.id)
    }

    func testCapturesAndAnswersAreIndependent() {
        captures()
        rep.submit()
        XCTAssertEqual(rep.stage, .firstQuestions)
        rep.answers[0] = answer(stop)
        rep.submit()
        rep.answers[1] = answer(partial)
        rep.submit()
        XCTAssertEqual(rep.stage, .review)
        XCTAssertTrue(rep.matchedBothViews)
        rep.answers[1].opening = .unsure
        XCTAssertFalse(rep.matchedBothViews)
        rep.answers[1] = answer(partial)
        rep.answers[0].estimate = .hidden
        XCTAssertFalse(rep.matchedBothViews)
    }

    private func start(at t: Double = 0) {
        rep.observe(stop, at: t)
        XCTAssertTrue(rep.identify(stop.region(for: .epiglottis)!.center))
        XCTAssertTrue(rep.mark())
    }

    private func captures() {
        start()
        rep.observe(sliver, at: 0.1)
        rep.observe(partial, at: 0.3)
        XCTAssertFalse(rep.mark())
        for i in 4...14 { rep.observe(sliver, at: Double(i) / 10) }
        XCTAssertFalse(rep.mark())
        rep.observe(partial, at: 1.5)
        XCTAssertTrue(rep.mark())
        XCTAssertEqual(rep.first?.id, stop.id)
        XCTAssertEqual(rep.recovered?.id, partial.id)
    }

    private func answer(_ frame: PracticeFrame) -> StillAnswer {
        StillAnswer(epiglottis: .point(frame.region(for: .epiglottis)!.center),
                    opening: .point(frame.region(for: .opening)!.center), estimate: frame.opening)
    }
}
