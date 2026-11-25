import Vision

enum TrainerMarker {
    static let payload = "intublade-trainer-motion-v1"

    static func pose(in image: CGImage) throws -> simd_float4x4? {
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
        return SquarePose.referenceFromCamera(corners: corners, sideMeters: 0.04, maxNormalizedError: 0.025)
    }
}
