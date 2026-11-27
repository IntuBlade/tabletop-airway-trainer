import XCTest
import SceneKit
import simd
@testable import TrainerCore

final class BladeStabilityTests: XCTestCase {
    // Project a fixed 40 mm QR and add deterministic subpixel corner noise.
    // A feature 40 mm in front of the virtual lens turns angular and lateral
    // jitter into one visible measure, in pixels on a 640 px wide viewport.
    func testStillViewAndIntentionalMovement() throws {
        for fps in [15, 30, 60] {
            for tilt in [0.0, 0.35, 0.6] {
                var sequence = MarkerSequence()
                var smoothing = BladePoseFilter()
                var seed: UInt64 = 923
                func noise() -> Double {
                    seed = seed &* 6364136223846793005 &+ 1
                    return (Double(seed >> 32) / Double(UInt32.max) - 0.5) * 0.0015
                }
                func observation(_ i: Int, distance: Double, roll: Double = 0) throws -> simd_float4x4? {
                    let q = simd_quatd(angle: roll, axis: [0,0,1]) * simd_quatd(angle: tilt, axis: [0,1,0])
                    let corners = [SIMD2<Double>(-1,-1),[1,-1],[1,1],[-1,1]].map { corner in
                        let p = q.act(SIMD3(corner.x * 0.02, corner.y * 0.02, 0)) + SIMD3(0,0,distance)
                        return SIMD2(p.x / p.z + noise(), p.y / p.z + noise())
                    }
                    let t = Double(i) / Double(fps)
                    return smoothing.update(sequence.pose(corners, at: t), at: t)
                }
                var reference: simd_float4x4?
                var previous: SIMD2<Float>?
                var steps = [Float]()
                let entry = AirwayEntry.camera(for: matrix_identity_float4x4, research: true)
                let landmark = entry * SIMD4<Float>(0, 0, -0.040, 1)
                for i in 0..<(fps * 3) {
                    guard let pose = try observation(i, distance: 0.18) else { continue }
                    if reference == nil { reference = pose }
                    let rendered = AirwayEntry.camera(for: reference!.inverse * pose, research: true)
                    let feature = rendered.inverse * landmark
                    let pixel = SIMD2(feature.x, feature.y) / -feature.z * Float(320 / TrainerMarker.halfWidthAtUnitDepth)
                    if i >= fps, let previous { steps.append(simd_distance(previous, pixel)) }
                    previous = pixel
                }
                let p95 = steps.sorted()[steps.count * 95 / 100]
                let origin = try XCTUnwrap(reference)
                // Abrupt 20 mm withdrawal and 12 degree roll. Detect time to
                // reach 80% of both changes, including all acquisition filters.
                var delay: Double?
                for i in 0..<fps {
                    let pose = try XCTUnwrap(observation(fps * 3 + i, distance: 0.20, roll: .pi / 15))
                    let delta = origin.inverse * pose
                    if delay == nil && delta.columns.3.z >= 0.016 && simd_quatf(delta).angle >= Float.pi / 15 * 0.8 {
                        delay = Double(i + 1) / Double(fps)
                    }
                }
                print("trace fps=\(fps) tilt=\(tilt) p95px=\(p95) responseMs=\((delay ?? 1)*1000)")
                // Slowly return over two seconds. Accumulated subpixel steps
                // must move the camera even when no individual step is large.
                for i in 1...(fps * 2) {
                    let t = Double(i) / Double(fps * 2)
                    let pose = try XCTUnwrap(observation(fps * 4 + i, distance: 0.20 - 0.02*t, roll: .pi/15*(1-t)))
                    if i == fps || i == fps * 2 {
                        let depth = (origin.inverse * pose).columns.3.z
                        XCTAssertEqual(depth, Float(0.020 * (1-t)), accuracy: 0.003)
                    }
                }
                XCTAssertLessThan(p95, 2.0)
                XCTAssertLessThanOrEqual(try XCTUnwrap(delay), 0.28)
            }
        }
    }
}

final class TissueLiftTests: XCTestCase {
    // A synthetic pocket at the training contact offset in the end-of-path frame.
    let contact = TissueLiftContact(pocket: [0, 0.010, -0.019], axis: [0, 1, 0])

    func testContactIsGradedReversibleAndLocalToThePocket() {
        func weight(_ x: Float, _ y: Float, _ z: Float) -> Float {
            var camera = matrix_identity_float4x4
            camera.columns.3 = [x, y, z, 1]
            return contact.weight(for: camera)
        }
        XCTAssertEqual(weight(0, 0, 0), 0)
        XCTAssertEqual(weight(0, 0.005, 0), 0.5, accuracy: 0.001)
        XCTAssertEqual(weight(0, 0.010, 0), 1)
        XCTAssertEqual(weight(0.02, 0.010, 0), 0)
        XCTAssertEqual(weight(0, 0.010, 0.025), 0)
        XCTAssertEqual(weight(0, 0.03, 0), 0)
        XCTAssertEqual(weight(0, 0, 0), 0)
        XCTAssertEqual(contact.weight(for: nil), 0)
    }

    func testCenteredAdvanceAloneDoesNotLiftTissue() {
        for mm in 0...70 {
            var movement = matrix_identity_float4x4
            movement.columns.3.z = -Float(mm) / 1000
            XCTAssertEqual(contact.weight(for: AirwayEntry.camera(for: movement, research: true)), 0)
        }
    }
}

final class PairedBladePathTests: XCTestCase {
    func testRotatingLensCarriesItsTipThroughSeatingLiftAndRelease() throws {
        let root = SCNNode()
        let group = SCNNode()
        group.name = "BladeGuide"
        root.addChildNode(group)
        func marker(_ name: String, _ point: SIMD3<Float>, pitch: Float = 0) {
            let node = SCNNode()
            node.name = name
            node.simdOrientation = simd_quatf(angle: pitch, axis: [1,0,0])
            node.simdPosition = point
            group.addChildNode(node)
        }
        let tip = SIMD3<Float>(0.003, 0.008, -0.044)
        let seat = SIMD3<Float>(0, 0, -0.022)
        marker("TipInLens", tip)
        marker("EntryLens", [0, 0.05, 0.03], pitch: -1)
        marker("MiddleTip", [0.002, 0.010, -0.005])
        marker("SeatedTip", seat)
        XCTAssertNil(PairedBladePath(root: root))
        marker("RaisedTip", seat + [0, 0.012, 0])
        let guide = try XCTUnwrap(PairedBladePath(root: root))
        let contact = TissueLiftContact(pocket: seat, axis: [0,1,0], tipInLens: tip, fullLift: guide.fullLift)
        let entry = guide.camera(for: matrix_identity_float4x4)
        XCTAssertLessThan(simd_distance(entry.columns.3.xyz, guide.entryLens.columns.3.xyz), 1e-6)
        var movement = matrix_identity_float4x4
        movement.columns.3.z = -guide.advanceMeters
        let seated = guide.camera(for: movement)
        XCTAssertLessThan(simd_distance((seated * SIMD4(tip, 1)).xyz, seat), 1e-6)
        XCTAssertEqual(contact.weight(for: seated), 0)
        movement.columns.3.y = guide.fullLift
        let raised = guide.camera(for: movement)
        XCTAssertEqual(contact.weight(for: raised), 1, accuracy: 1e-5)
        let rotation = simd_float4x4(simd_quatf(angle: 0.6, axis: [0,1,0]))
        let turned = guide.camera(for: movement * rotation)
        XCTAssertLessThan(simd_distance(turned.columns.3, raised.columns.3), 1e-6)
        XCTAssertEqual(contact.weight(for: turned), 0)
        XCTAssertEqual(contact.weight(for: nil), 0)
        XCTAssertEqual(contact.weight(for: guide.camera(for: movement)), 1, accuracy: 1e-5)
        movement.columns.3.z -= 0.018
        XCTAssertEqual(contact.weight(for: guide.camera(for: movement)), 0)
        XCTAssertEqual(guide.camera(for: matrix_identity_float4x4).columns.3, entry.columns.3)
    }
}

final class PrintedMarkerTests: XCTestCase {
    func testMeasuredWidthPreservesTravelAcrossMarkerLoss() throws {
        for widthMM in [40.0, 160.0] {
            for tilt in [0.0, 0.55] {
                let rotation = simd_quatd(angle: tilt, axis: [0, 1, 0])
                func corners(at distance: Double) -> [SIMD2<Double>] {
                    [SIMD2<Double>(-1,-1),[1,-1],[1,1],[-1,1]].map { p in
                        let v = rotation.act(SIMD3(p.x, p.y, 0) * widthMM / 2000) + SIMD3(0, 0, distance)
                        return SIMD2(v.x, v.y) / v.z
                    }
                }
                var tracker = MarkerSequence(widthMM: widthMM)
                func acquire(_ distance: Double, tick: Int) throws -> simd_float4x4 {
                    for i in tick..<(tick + 2) {
                        XCTAssertNil(tracker.pose(corners(at: distance), at: Double(i)/30))
                    }
                    return try XCTUnwrap(tracker.pose(corners(at: distance), at: Double(tick + 2)/30))
                }
                let start = try acquire(0.20, tick: 0)
                XCTAssertNil(tracker.pose(nil, at: 0.10))
                let moved = try acquire(0.18, tick: 4)
                let displacement = simd_length((start.inverse * moved).columns.3 - SIMD4<Float>(0,0,0,1))
                XCTAssertEqual(displacement, 0.020, accuracy: 0.001)
            }
        }
    }
}
