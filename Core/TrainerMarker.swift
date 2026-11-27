import Vision

enum TrainerMarker {
    static let standardWidthMM = 40.0
    static let horizontalFOV = 68.0
    static let halfWidthAtUnitDepth = tan(horizontalFOV * .pi / 360)
    static let payload = "intublade-trainer-motion-v1"

    static func pose(in image: CGImage) throws -> simd_float4x4? {
        try corners(in: image).flatMap { solve($0) }
    }

    static func solve(_ corners: [SIMD2<Double>], widthMM: Double = standardWidthMM) -> simd_float4x4? {
        guard corners.count == 4 else { return nil }
        let shortest = (0..<4).map { simd_distance(corners[$0], corners[($0+1)%4]) }.min() ?? 0
        // Limit residual relative to marker size as it shrinks during withdrawal.
        guard let measured = SquarePose.referenceFromCamera(corners: corners, sideMeters: widthMM / 1000,
                                                            maxNormalizedError: min(0.025, shortest * 0.08)) else { return nil }
        // A tiny perspective error on a square viewed head-on can create a large
        // spurious tilt. Fit a rotated square to all four corners. Prefer its
        // frontal pose only to the extent that it explains the observations.
        let center = corners.reduce(.zero, +) / 4
        let right = (corners[1] - corners[0] + corners[2] - corners[3]) / 2
        let down = (corners[3] - corners[0] + corners[2] - corners[1]) / 2
        let edge = (right + SIMD2(down.y, -down.x)) / 2
        let width = simd_length(edge)
        guard width > 0 else { return nil }
        let ortho = SIMD2(-edge.y, edge.x)
        let signs: [SIMD2<Double>] = [[-1,-1],[1,-1],[1,1],[-1,1]]
        let error = zip(signs, corners).map { sign, actual in
            simd_distance(center + (edge * sign.x + ortho * sign.y) / 2, actual)
        }.max()! / width
        // Blend over 1–3% of a side so gradual tilting has no discrete pose jump.
        let weight = Float(min(1, max(0, (error - 0.01) / 0.02)))
        if weight == 1 { return measured }
        let direction = SIMD2<Float>(edge / width)
        let depth = Float(widthMM / 1000 / width)
        let frontal = simd_float4x4(columns: (
            [direction.x, -direction.y, 0, 0], [-direction.y, -direction.x, 0, 0],
            [0, 0, -1, 0], [Float(center.x)*depth, -Float(center.y)*depth, -depth, 1]
        ))
        let tilted = measured.inverse
        var fitted = simd_float4x4(simd_slerp(simd_quatf(frontal), simd_quatf(tilted), weight))
        fitted.columns.3 = frontal.columns.3 + weight * (tilted.columns.3 - frontal.columns.3)
        return fitted.inverse
    }

    static func corners(in image: CGImage) throws -> [SIMD2<Double>]? {
        let request = VNDetectBarcodesRequest()
        request.symbologies = [.qr]
        try VNImageRequestHandler(cgImage: image).perform([request])
        let matches = (request.results ?? []).filter { $0.payloadStringValue == payload }
        guard matches.count == 1, let qr = matches.first else { return nil }
        // Nominal optics and marker size for an explicitly uncalibrated motion preview.
        let w = Double(image.width), h = Double(image.height)
        let focal = w / (2 * halfWidthAtUnitDepth)
        let corners = [qr.topLeft, qr.topRight, qr.bottomRight, qr.bottomLeft].map {
            SIMD2<Double>(($0.x - 0.5) * w / focal, (0.5 - $0.y) * h / focal)
        }
        return corners
    }
}

// Filter the four observed corners before perspective amplifies their noise.
// Three recent observations are required after loss. Never extrapolate a hidden QR.
struct MarkerSequence {
    let widthMM: Double

    private let acquisitionGap: Double

    init(widthMM: Double = TrainerMarker.standardWidthMM, acquisitionGap: Double = 0.25) {
        self.widthMM = widthMM
        self.acquisitionGap = acquisitionGap
    }

    private var samples = [[SIMD2<Double>]]()
    private var stableCorners: [SIMD2<Double>]?
    private var lastTime = -Double.infinity

    mutating func pose(_ corners: [SIMD2<Double>]?, at time: Double, hasAnchor: Bool = false) -> simd_float4x4? {
        if time <= lastTime || time - lastTime > (hasAnchor ? 0.25 : acquisitionGap) {
            samples.removeAll()
            stableCorners = nil
        }
        lastTime = time
        guard let corners, let measured = TrainerMarker.solve(corners, widthMM: widthMM) else {
            samples.removeAll()
            stableCorners = nil
            return nil
        }
        samples.append(corners)
        if samples.count > 3 { samples.removeFirst() }
        guard samples.count == 3 else {
            // Acquiring the initial reference needs multiple observations. Once
            // anchored, a fresh validated measurement can resume motion alone.
            guard hasAnchor else { return nil }
            stableCorners = corners
            return measured
        }
        func median(_ a: Double, _ b: Double, _ c: Double) -> Double {
            max(min(a,b), min(max(a,b), c))
        }
        let filtered = corners.indices.map { i in
            let a = samples[0][i], b = samples[1][i], c = samples[2][i]
            return SIMD2(median(a.x,b.x,c.x), median(a.y,b.y,c.y))
        }
        // Stabilize the measurements before perspective turns subpixel corner
        // noise into millimeters of lateral camera motion. Compare to the last
        // accepted corners so a slow, deliberate movement accumulates.
        if let stableCorners {
            let distance = zip(filtered, stableCorners).map { simd_distance($0, $1) }.max() ?? 0
            let noiseFloor = 0.0015  // Camera-normalized units, about 0.7 px at 640 px wide.
            if distance <= noiseFloor { return TrainerMarker.solve(stableCorners, widthMM: widthMM) }
            let weight = 1 - noiseFloor / distance
            self.stableCorners = zip(stableCorners, filtered).map { $0 + weight * ($1 - $0) }
        } else {
            stableCorners = filtered
        }
        return stableCorners.flatMap { TrainerMarker.solve($0, widthMM: widthMM) }
    }
}
