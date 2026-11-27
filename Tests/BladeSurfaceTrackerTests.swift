import simd
import CoreGraphics
import ImageIO
import XCTest
@testable import TrainerCore

final class BladeSurfaceTrackerTests: XCTestCase {
    func testOverlappingSurfaceCarriesMotionAfterQRLeavesAndBlankFrameHoldsRep() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Artwork/motion-marker.png")
        let reader = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        let qr = try XCTUnwrap(CGImageSourceCreateImageAtIndex(reader, 0, nil))
        func image(_ dx: Int, _ dy: Int, zoom: CGFloat = 1, blank: Bool = false) throws -> CGImage {
            let ctx = try XCTUnwrap(CGContext(data: nil, width: 640, height: 480, bitsPerComponent: 8,
                                              bytesPerRow: 640, space: CGColorSpaceCreateDeviceGray(),
                                              bitmapInfo: CGImageAlphaInfo.none.rawValue))
            ctx.setFillColor(gray: 0.83, alpha: 1)
            ctx.fill(CGRect(x: 0, y: 0, width: 640, height: 480))
            if !blank {
                ctx.translateBy(x: CGFloat(dx)+320, y: CGFloat(dy)+240)
                ctx.scaleBy(x: zoom, y: zoom)
                ctx.translateBy(x: -320, y: -240)
                var seed: UInt64 = 372
                func random(_ range: Int) -> Int {
                    seed = seed &* 6364136223846793005 &+ 1
                    return Int((seed >> 33) % UInt64(range))
                }
                for _ in 0..<1600 {
                    ctx.setFillColor(gray: CGFloat(random(200))/255, alpha: 1)
                    ctx.fillEllipse(in: CGRect(x: random(1000)-300, y: random(700)-100,
                                               width: 2+random(27), height: 2+random(16)))
                }
                ctx.interpolationQuality = .none
                ctx.draw(qr, in: CGRect(x: 492, y: 190, width: 116, height: 116))
            }
            return try XCTUnwrap(ctx.makeImage())
        }

        var tracker = BladeSurfaceTracker(widthMM: 40)
        var time = 0.0
        func scan(_ frame: CGImage) -> BladeSurfaceTracker.Observation {
            time += 1.0/30
            return tracker.update(frame, at: time)
        }
        let first = try image(0,0)
        let startingCorners = try XCTUnwrap(TrainerMarker.corners(in: first))
        var result = scan(first)
        for _ in 0..<4 { result = scan(first) }
        let origin = try XCTUnwrap(result.initialPose)
        // An expensive frame or a slow video cadence must not hold an already
        // anchored rep indefinitely while the same target remains visible.
        let slowShift = try image(16, 0)
        XCTAssertNotNil(try TrainerMarker.corners(in: slowShift))
        for _ in 0..<8 {
            time += 0.32
            result = scan(slowShift)
        }
        XCTAssertEqual(result.state, .tracking, "visible QR at slow cadence")
        XCTAssertGreaterThan(simd_distance(try XCTUnwrap(result.pose).columns.3,origin.columns.3), 0.002)
        for _ in 0..<8 { result = scan(first) }

        let final = try image(155,19,zoom: 1.1)
        XCTAssertNil(try TrainerMarker.corners(in: final))
        for i in 1...20 {
            result = scan(try image(155*i/20,19*i/20,zoom: 1+CGFloat(i)/200))
        }
        for _ in 0..<8 { result = scan(final) }
        XCTAssertEqual(result.state, .tracking)
        let end = try XCTUnwrap(result.pose)
        let focal = 320/TrainerMarker.halfWidthAtUnitDepth
        let expected = try XCTUnwrap(TrainerMarker.solve(startingCorners.map {
            1.1*$0 + SIMD2(155/focal,-19/focal)
        }))
        XCTAssertLessThan(simd_distance(end.columns.3,expected.columns.3),0.008)
        XCTAssertGreaterThan(simd_distance(origin.columns.3,end.columns.3),0.02)

        let white = try image(0,0,blank: true)
        for _ in 0..<12 {
            result = scan(white)
            XCTAssertEqual(result.state, .held)
            XCTAssertEqual(result.pose?.columns.3,end.columns.3)
            XCTAssertEqual(result.initialPose?.columns.3,origin.columns.3)
        }
        let fast = try image(199,31,zoom: 1.1)
        XCTAssertNil(try TrainerMarker.corners(in: fast))
        for _ in 0..<12 { result = scan(fast) }
        XCTAssertEqual(result.state, .tracking)
        let shifted = try XCTUnwrap(result.pose)
        XCTAssertGreaterThan(simd_distance(shifted.columns.3, end.columns.3),0.009)
        let recovered = try XCTUnwrap(TrainerMarker.solve(startingCorners.map {
            1.1*$0 + SIMD2(199/focal,-31/focal)
        }))
        XCTAssertLessThan(simd_distance(shifted.columns.3, recovered.columns.3),0.008)
        // Reconnecting discards the old images, but preserves the session's
        // original marker frame until a fresh absolute fix is available.
        tracker = BladeSurfaceTracker(widthMM: 40, resume: result.held)
        result = scan(white)
        XCTAssertEqual(result.state, .held)
        XCTAssertEqual(result.pose?.columns.3, shifted.columns.3)
        XCTAssertEqual(result.initialPose?.columns.3, origin.columns.3)
        for _ in 0..<12 { result = scan(first) }
        XCTAssertEqual(result.state, .tracking)
        XCTAssertEqual(result.initialPose?.columns.3,origin.columns.3)
        XCTAssertLessThan(simd_distance(try XCTUnwrap(result.pose).columns.3,origin.columns.3),0.003)
    }
}
