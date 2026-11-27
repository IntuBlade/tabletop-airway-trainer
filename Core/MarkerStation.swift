import Vision
import Accelerate

/// Versioned digital fixture, in meters. All faces share the entry marker's
/// right/down/into-paper basis. The legacy variable-width print is separate.
enum StationFace: String, CaseIterable {
    case entry = "AP2:E", rear = "AP2:B", lift = "AP2:U", left = "AP2:L", right = "AP2:R"

    case rearWing = "AP2:b", liftWing = "AP2:u", leftWing = "AP2:l", rightWing = "AP2:r"

    static let side = 0.018
    var name: String {
        switch self {
        case .entry: return "Entry"
        case .rear, .rearWing: return "Rear"
        case .lift, .liftWing: return "Lift"
        case .left, .leftWing: return "Left"
        case .right, .rightWing: return "Right"
        }
    }

    private var entryLensFromFace: simd_float4x4 {
        let pitch: Float, yaw: Float
        switch self {
        case .entry: (pitch, yaw) = (0, 0)
        case .rear, .rearWing: (pitch, yaw) = (0.18, 0)
        case .lift, .liftWing: (pitch, yaw) = (0.68, 0)
        case .left, .leftWing: (pitch, yaw) = (0.65, 0.71)
        case .right, .rightWing: (pitch, yaw) = (0.65, -0.71)
        }
        let aim = simd_quatf(angle: yaw, axis: [0,1,0]) * simd_quatf(angle: pitch, axis: [1,0,0])
        let wing = [.rearWing, .liftWing, .leftWing, .rightWing].contains(self)
        let offset: SIMD3<Float> = wing ? [0.026, 0, -0.096] : [0, 0, -0.085]
        let faceAngle = simd_quatf(angle: wing ? -0.46 : 0, axis: [0,1,0])
        var transform = simd_float4x4(aim * faceAngle * simd_quatf(angle: .pi, axis: [1,0,0]))
        let center: SIMD3<Float> = self == .entry ? [0,-0.021,-0.14]
            : SIMD3(0,0,-0.06) + aim.act(offset)
        transform.columns.3 = SIMD4(center, 1)
        return transform
    }

    static var stationFromEntryLens: simd_float4x4 { entry.entryLensFromFace.inverse }
    var stationFromFace: simd_float4x4 { Self.stationFromEntryLens * entryLensFromFace }
    var stationCorners: [SIMD4<Float>] {
        let r = Float(Self.side / 2)
        return [SIMD4<Float>(-r,-r,0,1), [r,-r,0,1], [r,r,0,1], [-r,r,0,1]].map { stationFromFace * $0 }
    }
}

struct StationDetection {
    let face: StationFace
    let corners: [SIMD2<Double>]
}

/// Fit one rigid camera to all decoded faces, in image space. A conflicting
/// layout must never move the airway to a different apparent mouth.
enum StationPose {
    static func solve(_ hits: [StationDetection]) -> simd_float4x4? {
        guard !hits.isEmpty, Set(hits.map(\.face)).count == hits.count,
              hits.allSatisfy({ $0.corners.count == 4 }) else { return nil }
        let seeds = hits.compactMap { hit -> simd_float4x4? in
            guard let local = TrainerMarker.solve(hit.corners, widthMM: StationFace.side * 1000) else { return nil }
            return hit.face.stationFromFace * local
        }
        guard !seeds.isEmpty else { return nil }
        let points = hits.flatMap { $0.face.stationCorners }
        let observed = hits.flatMap(\.corners)
        func residual(_ fromStation: simd_float4x4) -> [Double]? {
            var result: [Double] = []
            for (point, corner) in zip(points, observed) {
                let p = fromStation * point
                guard p.z < -0.001 else { return nil }
                result.append(Double(-p.x / p.z) - corner.x)
                result.append(Double(p.y / p.z) - corner.y)
            }
            return result
        }
        func score(_ v: [Double]) -> Double { v.reduce(0) { $0 + $1 * $1 } }
        let candidates = seeds.compactMap { pose -> (simd_float4x4, Double)? in
            let view = pose.inverse
            return residual(view).map { (view, score($0)) }
        }
        guard var (view, error) = candidates.min(by: { $0.1 < $1.1 }) else { return nil }
        func increment(_ delta: [Double]) -> simd_float4x4 {
            let axis = SIMD3<Float>(Float(delta[3]), Float(delta[4]), Float(delta[5]))
            let angle = simd_length(axis)
            var m = angle > 0 ? simd_float4x4(simd_quatf(angle: angle, axis: axis / angle)) : matrix_identity_float4x4
            m.columns.3 = [Float(delta[0]), Float(delta[1]), Float(delta[2]), 1]
            return m
        }
        // Refine the single-plane seeds against every visible 3-D corner.
        for _ in 0..<7 {
            guard error > 1e-12, let r = residual(view) else { break }
            var columns = [[Double]]()
            for k in 0..<6 {
                var step = [Double](repeating: 0, count: 6)
                step[k] = 0.0001
                guard let shifted = residual(increment(step) * view) else { return nil }
                columns.append(zip(shifted, r).map { ($0 - $1) / step[k] })
            }
            func dot(_ a: [Double], _ b: [Double]) -> Double { zip(a,b).reduce(0) { $0 + $1.0 * $1.1 } }
            var matrix = columns.flatMap { a in columns.map { dot(a, $0) } }
            for k in 0..<6 { matrix[7*k] += 0.00001 }
            var step = columns.map { -dot($0, r) }
            var n: Int32 = 6, rhs: Int32 = 1, lda: Int32 = 6, ldb: Int32 = 6, info: Int32 = 0
            var upper: Int8 = 85
            dposv_(&upper, &n, &rhs, &matrix, &lda, &step, &ldb, &info)
            guard info == 0 else { break }
            let next = increment(step) * view
            guard let nextResidual = residual(next), score(nextResidual) < error else { break }
            view = next
            error = score(nextResidual)
        }
        guard BladeRegistration.isRigid(view), let r = residual(view) else { return nil }
        for (i, hit) in hits.enumerated() {
            let side = hit.corners.indices.map { simd_distance(hit.corners[$0], hit.corners[($0+1)%4]) }.min()!
            let limit = min(0.018, side * 0.065)
            for j in 0..<4 where hypot(r[8*i+2*j], r[8*i+2*j+1]) > limit { return nil }
        }
        return view.inverse
    }
}
