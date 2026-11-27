import CoreImage
import simd

/// Digital blade frames. This renderer knows the scripted lens pose. Vision
/// and the live tracker receive only its raster output.
struct StationReplay {
    static let interval = 0.10
    let context = CIContext()
    let bounds = CGRect(x: 0, y: 0, width: 800, height: 480)
    private let codes: [StationFace: CIImage]

    init() {
        codes = Dictionary(uniqueKeysWithValues: StationFace.allCases.map { face in
            let code = CIFilter(name: "CIQRCodeGenerator", parameters: [
                "inputMessage": Data(face.rawValue.utf8), "inputCorrectionLevel": "L"
            ])!.outputImage!
            // Core Image includes one quiet module on each edge. Reserve
            // four outside the black square and project its true side length.
            let expanded = code.composited(over: CIImage(color: .white))
                .cropped(to: code.extent.insetBy(dx: -3, dy: -3))
            return (face, expanded.transformed(by: CGAffineTransform(scaleX: 12, y: 12)))
        })
    }

    func image(lens: simd_float4x4, blank: Bool = false) -> CGImage? {
        var bg = CIImage(color: CIColor(red: 0.78, green: 0.78, blue: 0.78)).cropped(to: bounds)
        let camera = (StationFace.stationFromEntryLens * lens).inverse
        let focal = bounds.width / (2 * TrainerMarker.halfWidthAtUnitDepth)
        if !blank {
            let faces = StationFace.allCases.sorted {
                (camera * $0.stationFromFace).columns.3.z < (camera * $1.stationFromFace).columns.3.z
            }
            for face in faces {
                guard let qr = codes[face] else { continue }
                let mat = camera * face.stationFromFace
                guard simd_dot(mat.columns.2.xyz, mat.columns.3.xyz) > 0 else { continue }
                let border = Float(StationFace.side / 2 * qr.extent.width / (qr.extent.width - 8 * 12))
                let points = [SIMD4<Float>(-border,-border,0,1), [border,-border,0,1],
                              [border,border,0,1], [-border,border,0,1]].map { mat * $0 }
                guard points.allSatisfy({ $0.z < -0.002 }) else { continue }
                let p = points.map { CIVector(x: bounds.midX - CGFloat($0.x/$0.z)*focal,
                                               y: bounds.midY - CGFloat($0.y/$0.z)*focal) }
                let warped = qr.applyingFilter("CIPerspectiveTransform", parameters: [
                    "inputTopLeft": p[0], "inputTopRight": p[1],
                    "inputBottomRight": p[2], "inputBottomLeft": p[3]
                ])
                bg = warped.composited(over: bg)
            }
        }
        return context.createCGImage(bg, from: bounds)
    }

    struct Step {
        let name: String
        let lens: simd_float4x4
        var blank = false
    }

    static func steps(advance: Float, lift: Float) -> [Step] {
        typealias Key = (name: String, depth: Float, rise: Float, pitch: Float, yaw: Float)
        let keys: [Key] = [("Scan at teeth",0,0,0,0), ("Advance",advance,0,0,0),
            ("Lift into contact",advance,lift,0,0), ("Angle up",advance,lift,0.66,0),
            ("Sweep left",advance,lift,0.66,0.72), ("Sweep right",advance,lift,0.66,-0.72),
            ("Recover contact",advance,lift,0,0), ("Release",advance,0,0,0),
            ("Withdraw",0,0,0,0)]
        var steps = Array(repeating: Step(name: keys[0].name, lens: matrix_identity_float4x4), count: 4)
        for (a, b) in zip(keys, keys.dropFirst()) {
            for i in 1...12 {
                let t = min(1, Float(i) / 9)
                func mix(_ x: Float, _ y: Float) -> Float { x + (y-x)*t }
                let rotation = simd_quatf(angle: mix(a.yaw,b.yaw), axis: [0,1,0])
                    * simd_quatf(angle: mix(a.pitch,b.pitch), axis: [1,0,0])
                var m = simd_float4x4(rotation)
                m.columns.3 = [0, mix(a.rise,b.rise), -mix(a.depth,b.depth), 1]
                steps.append(Step(name: b.name, lens: m))
            }
            if b.name == "Sweep left", let last = steps.last {
                steps.append(Step(name: "View occluded", lens: last.lens, blank: true))
            }
        }
        return steps
    }
}
