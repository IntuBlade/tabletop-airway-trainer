import Vision

/// A reduced image of the flat practice surface. Keep only the current reference
/// in memory. The projected square can leave the video while the surface overlaps.
private struct SurfaceImage {
    let image: CGImage
    let pixels: [UInt8]
    let width: Int
    let height: Int

    init?(_ source: CGImage) {
        width = min(480, source.width)
        height = max(1, width * source.height / source.width)
        guard let context = CGContext(data: nil, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: width,
                                      space: CGColorSpaceCreateDeviceGray(),
                                      bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
        context.interpolationQuality = .medium
        context.draw(source, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let reduced = context.makeImage(), let data = context.data else { return nil }
        image = reduced
        pixels = Array(UnsafeBufferPointer(start: data.assumingMemoryBound(to: UInt8.self),
                                           count: width * height))
    }

    private var focal: Float { Float(width) / Float(2 * TrainerMarker.halfWidthAtUnitDepth) }
    private var center: SIMD2<Float> { [Float(width)/2, Float(height)/2] }

    func transfer(_ corners: [SIMD2<Double>], to next: Self) -> [SIMD2<Double>]? {
        guard width == next.width, height == next.height else { return nil }
        func warp(from source: CGImage, to destination: CGImage) -> simd_float3x3? {
            let request = VNHomographicImageRegistrationRequest(targetedCGImage: source)
            guard (try? VNImageRequestHandler(cgImage: destination).perform([request])) != nil else { return nil }
            return request.results?.first?.warpTransform
        }
        if let direct = warp(from: image, to: next.image),
           let result = verifiedCorners(corners, in: next, warp: direct) { return result }

        // A quicker blade turn can exceed the projective solver's search range.
        // Estimate a coarse shift, then fit the projective motion on the overlap.
        let shift = VNTranslationalImageRegistrationRequest(targetedCGImage: image)
        guard (try? VNImageRequestHandler(cgImage: next.image).perform([shift])) != nil,
              let offset = shift.results?.first?.alignmentTransform,
              offset.tx.isFinite, offset.ty.isFinite,
              abs(offset.tx) < CGFloat(width)/2, abs(offset.ty) < CGFloat(height)/2 else { return nil }
        let dx = Int(offset.tx.rounded()), dy = Int(offset.ty.rounded())
        guard abs(dx) + abs(dy) >= 4 else { return nil }
        let oldX = max(0,-dx), oldY = max(0,-dy)
        let newX = oldX + dx, newY = oldY + dy
        let w = width - abs(dx), h = height - abs(dy)
        func crop(_ image: CGImage, _ x: Int, _ y: Int) -> CGImage? {
            image.cropping(to: CGRect(x: x, y: height-y-h, width: w, height: h))
        }
        func translation(_ x: Int, _ y: Int) -> simd_float3x3 {
            simd_float3x3(columns: ([1,0,0],[0,1,0],[Float(x),Float(y),1]))
        }
        guard let old = crop(image,oldX,oldY), let new = crop(next.image,newX,newY),
              let local = warp(from: old, to: new) else { return nil }
        let total = translation(newX,newY) * local * translation(-oldX,-oldY)
        return verifiedCorners(corners, in: next, warp: total)
    }

    private func verifiedCorners(_ corners: [SIMD2<Double>], in next: Self,
                                 warp: simd_float3x3) -> [SIMD2<Double>]? {
        // Vision uses bottom-left image space. Pixels and QR corners use top-left.
        func project(_ pixel: SIMD2<Float>) -> SIMD2<Float>? {
            let point = warp * SIMD3(pixel.x, Float(height-1)-pixel.y, 1)
            guard point.z.isFinite, point.z > 0.05 else { return nil }
            let xy = SIMD2(point.x / point.z, Float(height-1) - point.y / point.z)
            return xy.x.isFinite && xy.y.isFinite ? xy : nil
        }
        // Registration can return an identity or a plausible warp on a blank
        // or unrelated image. Confirm textured patches in multiple locations.
        var matches = [SIMD2<Float>]()
        var textured = 0
        for y in stride(from: 8, to: height - 8, by: max(8,height / 15)) {
            for x in stride(from: 8, to: width - 8, by: max(8,width / 19)) {
                var a: Float = 0, b: Float = 0, aa: Float = 0, bb: Float = 0, ab: Float = 0
                var count: Float = 0
                for dy in stride(from: -4, through: 4, by: 2) {
                    for dx in stride(from: -4, through: 4, by: 2) {
                        guard let q = project([Float(x+dx),Float(y+dy)]),
                              q.x >= 0, q.x < Float(width-1), q.y >= 0, q.y < Float(height-1) else { continue }
                        let original = Float(pixels[(y+dy)*width+x+dx])
                        let current = Float(next.pixels[Int(q.y.rounded())*width+Int(q.x.rounded())])
                        a += original; b += current
                        aa += original*original; bb += current*current; ab += original*current
                        count += 1
                    }
                }
                guard count == 25 else { continue }
                let av = aa-a*a/count, bv = bb-b*b/count
                guard av > count*64 else { continue }
                textured += 1
                if bv > count*36, ab-a*b/count > 0.78*sqrt(av*bv) {
                    matches.append([Float(x), Float(y)])
                }
            }
        }
        guard matches.count >= 4, matches.count * 2 >= textured,
              let first = matches.first else { return nil }
        // Require two-dimensional support: one straight printed edge is ambiguous.
        let spread = matches.reduce(SIMD3<Float>.zero) { sum, p in
            let d = (p-first) / Float(width)
            return sum + [d.x*d.x, d.x*d.y, d.y*d.y]
        } / Float(matches.count)
        guard spread.x*spread.z - spread.y*spread.y > 0.000002 else { return nil }
        let projected = corners.compactMap { corner -> SIMD2<Double>? in
            guard let p = project(center + SIMD2<Float>(corner)*focal) else { return nil }
            return SIMD2<Double>((p-center)/focal)
        }
        return projected.count == 4 ? projected : nil
    }
}

struct BladeSurfaceTracker {
    enum State { case acquiring, tracking, held }
    struct Observation {
        let state: State
        let pose: simd_float4x4?
        let initialPose: simd_float4x4?
        let detectedCorners: [SIMD2<Double>]?
    }
    private struct Reference {
        let surface: SurfaceImage
        let corners: [SIMD2<Double>]
    }
    private let widthMM: Double
    private var reference: Reference?
    private var sequence: MarkerSequence
    private var filter = BladePoseFilter()
    private var initialPose: simd_float4x4?
    private var lastPose: simd_float4x4?
    private var nextDecode = -Double.infinity
    private var qrReference: Reference?
    private var usingLocalReference = false
    private var nextAnchorCheck = -Double.infinity

    init(widthMM: Double) {
        self.widthMM = widthMM
        sequence = MarkerSequence(widthMM: widthMM)
    }

    mutating func update(_ image: CGImage, at time: Double) -> Observation {
        let surface = SurfaceImage(image)
        var detected: [SIMD2<Double>]?
        var corners: [SIMD2<Double>]?
        func transfer(_ reference: Reference?) -> [SIMD2<Double>]? {
            guard let reference, let surface,
                  let estimate = reference.surface.transfer(reference.corners, to: surface),
                  estimate.allSatisfy({ simd_length($0) < 2.5 }),
                  TrainerMarker.solve(estimate, widthMM: widthMM) != nil else { return nil }
            return estimate
        }
        corners = transfer(reference)
        // Revisit the original textured image to remove incremental drift. This
        // does not require the printed symbol to decode or even be in the frame.
        if usingLocalReference, time >= nextAnchorCheck {
            nextAnchorCheck = time + (corners == nil ? 0.25 : 2)
            if let anchored = transfer(qrReference) {
                corners = anchored
                reference = qrReference
                usingLocalReference = false
            }
        }
        if corners == nil, time >= nextDecode {
            detected = try? TrainerMarker.corners(in: image)
            corners = detected
            // Decode promptly when acquiring a lock. Rate-limit failed searches
            // after loss while continuing to try the existing surface reference.
            nextDecode = detected == nil && lastPose != nil ? time + 0.20 : time
        }
        let measurement = sequence.pose(corners, at: time)
        if let pose = filter.update(measurement, at: time), let corners {
            lastPose = pose
            if initialPose == nil { initialPose = pose }
            if let surface {
                if detected != nil {
                    reference = Reference(surface: surface, corners: corners)
                    qrReference = reference
                    usingLocalReference = false
                } else if let prior = reference,
                          zip(corners, prior.corners).contains(where: { simd_distance($0,$1) > 0.025 }) {
                    reference = Reference(surface: surface, corners: corners)
                    usingLocalReference = true
                }
            }
            return Observation(state: .tracking, pose: pose, initialPose: initialPose, detectedCorners: detected)
        }
        return Observation(state: lastPose == nil ? .acquiring : .held, pose: lastPose,
                           initialPose: initialPose, detectedCorners: detected)
    }
}
