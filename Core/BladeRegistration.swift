import simd

/// Both transforms use the same physical reference and meters.
/// The blade adapter supplies nil whenever its current frame has no usable pose.
struct BladeRegistration {
    let referenceFromMouth: simd_float4x4

    func mouthFromCamera(referenceFromCamera: simd_float4x4?) -> simd_float4x4? {
        guard let referenceFromCamera, Self.isRigid(referenceFromMouth),
              Self.isRigid(referenceFromCamera) else { return nil }
        return referenceFromMouth.inverse * referenceFromCamera
    }

    fileprivate static func isRigid(_ m: simd_float4x4) -> Bool {
        let r = simd_float3x3(columns: (m.columns.0.xyz, m.columns.1.xyz, m.columns.2.xyz))
        let identity = r.transpose * r - matrix_identity_float3x3
        return m.columns.3.xyz.allFinite && abs(m.columns.3.w - 1) < 0.0001
            && abs(m.columns.0.w) + abs(m.columns.1.w) + abs(m.columns.2.w) < 0.0001
            && abs(r.determinant - 1) < 0.001
            && (0..<3).allSatisfy { simd_length(identity[$0]) < 0.001 }
    }
}

private extension SIMD4 where Scalar == Float {
    var xyz: SIMD3<Float> { [x, y, z] }
}
private extension SIMD3 where Scalar == Float {
    var allFinite: Bool { x.isFinite && y.isFinite && z.isFinite }
}

/// Four corners of one square in known marker order, clockwise from top left.
/// Input coordinates must already be undistorted and normalized by camera intrinsics.
/// The reference origin is the marker center; +x points right and +y down the print.
enum SquarePose {
    static func referenceFromCamera(corners p: [SIMD2<Double>], sideMeters: Double,
                                    maxNormalizedError: Double) -> simd_float4x4? {
        guard p.count == 4, sideMeters.isFinite, sideMeters > 0,
              maxNormalizedError.isFinite, maxNormalizedError > 0 else { return nil }
        let a = p[1] - p[2], b = p[3] - p[2], c = p[0] - p[1] + p[2] - p[3]
        func cross(_ v: SIMD2<Double>, _ w: SIMD2<Double>) -> Double { v.x * w.y - v.y * w.x }
        guard (0..<4).allSatisfy({ i in
            cross(p[(i+1)%4] - p[i], p[(i+2)%4] - p[(i+1)%4]) > 1e-10
        }) else { return nil }
        let denominator = cross(a, b)
        let g = cross(c, b) / denominator, h = cross(a, c) / denominator
        func ray(_ q: SIMD2<Double>) -> SIMD3<Double> { [q.x, q.y, 1] }
        let columnX = (1 + g) * ray(p[1]) - ray(p[0])
        let columnY = (1 + h) * ray(p[3]) - ray(p[0])
        let scale = 2 * sideMeters / (simd_length(columnX) + simd_length(columnY))
        let x = simd_normalize(columnX)
        let z = simd_normalize(simd_cross(x, columnY))
        let y = simd_cross(z, x)
        let center = (ray(p[0]) + 0.5 * (columnX + columnY)) * scale
        let offsets = [SIMD2<Double>(-0.5,-0.5), [0.5,-0.5], [0.5,0.5], [-0.5,0.5]]
        for (offset, measured) in zip(offsets, p) {
            let v = center + sideMeters * (offset.x * x + offset.y * y)
            guard v.z > 0,
                  simd_distance(SIMD2(v.x, v.y) / v.z, measured) <= maxNormalizedError else { return nil }
        }
        func col(_ v: SIMD3<Double>, _ w: Float) -> SIMD4<Float> {
            [Float(v.x), Float(-v.y), Float(-v.z), w]
        }
        let cameraFromReference = simd_float4x4(columns: (col(x,0), col(y,0), col(z,0), col(center,1)))
        guard BladeRegistration.isRigid(cameraFromReference) else { return nil }
        return cameraFromReference.inverse
    }
}

enum TableStation {
    static func registration(worldFromImage: simd_float4x4, worldFromHeadBase: simd_float4x4) -> BladeRegistration {
        // AR image local +z runs down the print. The pose solver uses +y down.
        let imageFromMarker = simd_float4x4(simd_quatf(angle: .pi / 2, axis: [1, 0, 0]))
        let worldFromMarker = worldFromImage * imageFromMarker
        // Nominal entry point on the setup shell, and corresponding lip midpoint
        // in the research renderer. These are model-space landmarks in meters.
        let lipsOnHead = SIMD3<Float>(0, 0.135, 0.059)
        let lipsInScene = SIMD3<Float>(0, 0.077, 0.026)
        let orientation = simd_quatf(angle: .pi, axis: SIMD3<Float>(0, 1, 0))
        var headFromScene = simd_float4x4(orientation)
        headFromScene.columns.3 = SIMD4(lipsOnHead - orientation.act(lipsInScene), 1)
        return BladeRegistration(referenceFromMouth: worldFromMarker.inverse * worldFromHeadBase * headFromScene)
    }
}

struct BladePoseFilter {
    private var previous: simd_float4x4?
    private var time = -Double.infinity

    mutating func update(_ sample: simd_float4x4?, at now: Double) -> simd_float4x4? {
        defer { time = now }
        guard let sample else { previous = nil; return nil }
        let dt = now - time
        guard let previous, dt > 0, dt < 0.20 else { previous = sample; return sample }
        // 65 ms exponential smoothing, independent of detector frame rate.
        let alpha = Float(1 - exp(-dt / 0.065))
        let rotation = simd_slerp(simd_quatf(previous), simd_quatf(sample), alpha)
        var smoothed = simd_float4x4(rotation)
        smoothed.columns.3 = previous.columns.3 + alpha * (sample.columns.3 - previous.columns.3)
        self.previous = smoothed
        return smoothed
    }
}

struct BladeTablePlacement {
    let markerFromHead: simd_float4x4
    let station: BladeRegistration

    /// QR lies flat: marker +x is right on the print and +z points into the table.
    /// Intersect the blade's optical axis with the tabletop at the reticle.
    init?(markerFromLens: simd_float4x4) {
        guard BladeRegistration.isRigid(markerFromLens) else { return nil }
        let position = markerFromLens.columns.3.xyz
        let forward = -markerFromLens.columns.2.xyz
        guard position.z < 0, forward.z > 0.1 else { return nil }
        let distance = -position.z / forward.z
        guard distance > 0, distance < 1 else { return nil }
        let hit = position + distance * forward
        var base = simd_float4x4(simd_quatf(angle: -.pi / 2, axis: [1,0,0]))
        base.columns.3 = SIMD4(hit, 1)
        markerFromHead = base
        // TableStation expects the image-anchor convention used in its registration math.
        let markerFromImage = simd_float4x4(simd_quatf(angle: -.pi / 2, axis: [1,0,0]))
        station = TableStation.registration(worldFromImage: markerFromImage, worldFromHeadBase: base)
    }
}
