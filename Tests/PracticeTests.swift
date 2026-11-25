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

    func testFlatQRLocatesMouthInSetupAndPractice() throws {
        let placement = BladeTablePlacement()
        let lip = placement.markerFromHead * SIMD4(TableStation.lipsOnHead, 1)
        XCTAssertLessThan(simd_length(lip - SIMD4(0,0,-0.135,1)), 0.00001)
        let practiceLip = placement.station.referenceFromMouth * SIMD4<Float>(0,0.077,0.026,1)
        XCTAssertLessThan(simd_length(lip - practiceLip), 0.00001)

        var lens = simd_float4x4(simd_quatf(angle: .pi, axis: [1,0,0]))
        lens.columns.3 = [0,0,-0.35,1]
        XCTAssertTrue(placement.mouthInFrame(markerFromLens: lens, aspect: 4/3))
        lens.columns.3.x = 0.25
        XCTAssertFalse(placement.mouthInFrame(markerFromLens: lens, aspect: 4/3))
        lens.columns.3 = [0,0,-0.08,1]
        XCTAssertFalse(placement.mouthInFrame(markerFromLens: lens, aspect: 4/3))
    }
}
