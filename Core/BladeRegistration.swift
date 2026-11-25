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
