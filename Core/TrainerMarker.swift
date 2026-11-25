import Vision

enum TrainerMarker {
    static let payload = "intublade-trainer-motion-v1"

    static func pose(in image: CGImage) throws -> simd_float4x4? {
        try corners(in: image).flatMap { solve($0) }
    }

    static func solve(_ corners: [SIMD2<Double>]) -> simd_float4x4? {
        guard corners.count == 4 else { return nil }
        let shortest = (0..<4).map { simd_distance(corners[$0], corners[($0+1)%4]) }.min() ?? 0
        // Limit residual relative to marker size as it shrinks during withdrawal.
        return SquarePose.referenceFromCamera(corners: corners, sideMeters: 0.04,
                                              maxNormalizedError: min(0.025, shortest * 0.08))
    }

    static func corners(in image: CGImage) throws -> [SIMD2<Double>]? {
        let request = VNDetectBarcodesRequest()
        request.symbologies = [.qr]
        try VNImageRequestHandler(cgImage: image).perform([request])
        let matches = (request.results ?? []).filter { $0.payloadStringValue == payload }
        guard matches.count == 1, let qr = matches.first else { return nil }
        // Nominal optics and marker size for an explicitly uncalibrated motion preview.
        let w = Double(image.width), h = Double(image.height)
        let focal = w / (2 * tan(68 * Double.pi / 360))
        let corners = [qr.topLeft, qr.topRight, qr.bottomRight, qr.bottomLeft].map {
            SIMD2<Double>(($0.x - 0.5) * w / focal, (0.5 - $0.y) * h / focal)
        }
        return corners
    }
}

// Filter the four observed corners before perspective amplifies their noise.
// Three recent observations are required after loss. Never extrapolate a hidden QR.
struct MarkerSequence {
    private var samples = [[SIMD2<Double>]]()
    private var lastTime = -Double.infinity

    mutating func pose(_ corners: [SIMD2<Double>]?, at time: Double) -> simd_float4x4? {
        if time <= lastTime || time - lastTime > 0.25 { samples.removeAll() }
        lastTime = time
        guard let corners, TrainerMarker.solve(corners) != nil else {
            samples.removeAll()
            return nil
        }
        samples.append(corners)
        if samples.count > 3 { samples.removeFirst() }
        guard samples.count == 3 else { return nil }
        func median(_ a: Double, _ b: Double, _ c: Double) -> Double {
            max(min(a,b), min(max(a,b), c))
        }
        let filtered = corners.indices.map { i in
            let a = samples[0][i], b = samples[1][i], c = samples[2][i]
            return SIMD2(median(a.x,b.x,c.x), median(a.y,b.y,c.y))
        }
        return TrainerMarker.solve(filtered)
    }
}
