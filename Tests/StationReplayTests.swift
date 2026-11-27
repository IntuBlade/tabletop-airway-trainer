import XCTest
import simd
@testable import TrainerCore

final class StationReplayTests: XCTestCase {
    func testStationWillNotStartAtASideOrAcceptAConflictingOverlap() throws {
        let replay = StationReplay()
        let side = try XCTUnwrap(StationReplay.steps(advance: 0.06, lift: 0.012).last { $0.name == "Sweep right" })
        let frame = try XCTUnwrap(replay.image(lens: side.lens))
        let visible = try TrainerMarker.detections(in: frame).station
        XCTAssertGreaterThanOrEqual(visible.count, 2)
        var tracker = BladeSurfaceTracker(widthMM: 40)
        for i in 0..<4 {
            let observation = tracker.update(frame, at: Double(i)/10)
            XCTAssertEqual(observation.evidence, .entryNeeded)
            XCTAssertNil(observation.initialPose)
        }
        let shifted = StationDetection(face: visible[1].face, corners: visible[1].corners.map { $0 + SIMD2(0.2, 0.1) })
        XCTAssertNil(StationPose.solve([visible[0], shifted]))
        XCTAssertNil(StationPose.solve([visible[0], visible[0]]))
    }

    func testScanLiftSweepOccludeRecoverAndWithdrawThroughVision() throws {
        let replay = StationReplay()
        var tracker = BladeSurfaceTracker(widthMM: 160) // Legacy print preference cannot rescale the board.
        var origin: simd_float4x4?
        var last: simd_float4x4?
        var sides = Set<StationFace>()
        var failures: [String] = []
        var worstPosition: Float = 0, worstAngle: Float = 0
        let steps = StationReplay.steps(advance: 0.060, lift: 0.012)
        for (i, step) in steps.enumerated() {
            try autoreleasepool {
                let image = try XCTUnwrap(replay.image(lens: step.lens, blank: step.blank))
                let result = tracker.update(image, at: Double(i) * StationReplay.interval)
                if i < 2 { XCTAssertNil(result.initialPose); return }
                guard let pose = result.pose, let initial = result.initialPose else {
                    failures.append("\(i) \(step.name): \(result.evidence) \(result.faces)"); return
                }
                if origin == nil { origin = initial }
                XCTAssertEqual(initial, origin)
                if step.blank {
                    XCTAssertEqual(result.state, .held)
                    XCTAssertEqual(pose, last)
                    tracker = BladeSurfaceTracker(widthMM: 160, resume: result.held)
                    return
                }
                if result.state != .tracking {
                    failures.append("\(i) \(step.name): \(result.evidence) \(result.faces)")
                }
                let delta = (initial.inverse * pose).inverse * step.lens
                worstPosition = max(worstPosition, simd_length(delta.columns.3.xyz))
                let angle = 2 * acos(min(1, abs(simd_quatf(delta).real)))
                worstAngle = max(worstAngle, angle)
                if ["Sweep left","Sweep right"].contains(step.name) {
                    // Entire entry square falls below the lens, even its highest corner.
                    let view = (StationFace.stationFromEntryLens * step.lens).inverse
                    let verticalLimit = Float(TrainerMarker.halfWidthAtUnitDepth * replay.bounds.height / replay.bounds.width)
                    XCTAssertTrue(StationFace.entry.stationCorners.allSatisfy {
                        let p = view * $0
                        return p.y < verticalLimit * p.z
                    })
                    XCTAssertFalse(result.faces.contains(.entry))
                    sides.formUnion(result.faces)
                }
                last = pose
            }
        }
        XCTAssertTrue(failures.isEmpty, failures.prefix(12).joined(separator: "\n"))
        XCTAssertTrue(sides.isSuperset(of: [.left,.right]))
        XCTAssertLessThan(worstPosition, 0.008)
        XCTAssertLessThan(worstAngle, 0.10)
        print("Raster replay max error: \(worstPosition*1000) mm, \(worstAngle*180 / .pi) degrees")
    }
}
