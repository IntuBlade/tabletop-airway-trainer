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
