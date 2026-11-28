#if FIXTURE_TRACKING
import SwiftUI
import ImageIO
import simd

struct FixtureSample {
    let image: CGImage
    let time: Double
    let walls, sliders: Int
    let lens: SIMD3<Float>?
    let lift: Double?
    let camera: simd_float4x4?
    let heading: Double?

    static func reader() -> FixtureReader? {
        Bundle.main.url(forResource: "FixtureMarks", withExtension: "json").flatMap { FixtureReader(map: $0) }
    }

    init(image: CGImage, reader: FixtureReader, time: Double, field: Double) {
        self.image = image
        self.time = time
        let data = reader.read(image, horizontalField: field)
        walls = data["walls"] as? Int ?? 0
        sliders = data["sliders"] as? Int ?? 0
        lift = data["lift"] as? Double
        func vector(_ key: String) -> SIMD3<Float>? {
            guard let v = data[key] as? [NSNumber], v.count == 3 else { return nil }
            return [v[0].floatValue, v[1].floatValue, v[2].floatValue]
        }
        lens = vector("lens")
        guard let lens, let right = vector("right"), let up = vector("up"), let forward = vector("forward") else {
            camera = nil; heading = nil; return
        }
        heading = Double(atan2(-forward.x, forward.y))*180 / .pi
        let screen = data["screen"] as? Bool == true
        let base = simd_float3x3(columns: ([1,0,0],[0,0,1],[0,-1,0]))
        let reference = simd_float3x3(simd_quatf(angle: screen ? 0 : 0.60, axis: [1,0,0])) * base
        let orientation = reference.transpose * simd_float3x3(columns: (right,up,-forward))
        var move = simd_float4x4(simd_quatf(orientation))
        let centered: SIMD3<Float> = screen ? [0,64,84] : [-2,61,54.4]
        let d = (lens-centered)/1000
        move.columns.3 = [d.x,d.z,-(SyntheticAirwayCamera.bladeGuide?.advanceMeters ?? 0.0604)-d.y,1]
        camera = SyntheticAirwayCamera.practiceCamera(for: move)
    }

    static func weight(_ degrees: Double) -> Float {
        let a = degrees > 1 ? degrees * .pi/180 : 0
        return Float(min(1,max(0,(11*sin(a)+3.4*(1-cos(a)))/5)))
    }
}

private struct FixtureEvent: Codable {
    let time: Double
    let walls, sliders: Int
    let positionMM: [Float]?
    let heading, lift: Double?
}
struct FixturePractice: View {
    @Environment(\.scenePhase) private var phase
    @State private var events = [FixtureEvent]()
    @State private var lastFrame = -Double.infinity
    @State private var priorIdle = false
    var body: some View {
        TimelineView(.periodic(from:.now,by:0.08)) { _ in
            let (sample,connection) = TrainerBlade.shared.currentFixture()
            ScrollView {
                VStack(alignment:.leading,spacing:12) {
                    if let sample {
                        Image(decorative:sample.image, scale:1).resizable().scaledToFit()
                        Text("\(sample.walls) wall · \(sample.sliders) slider")
                        if let pose=sample.camera,let degrees=sample.lift {
                            SyntheticAirwayCamera(mouthFromCamera:pose,useResearchScene:true,measuredWeight:FixtureSample.weight(degrees))
                                .aspectRatio(1.6,contentMode:.fit)
                            Text(String(format:"Measured lift %.1f°",degrees <= 1 ? 0 : degrees)).font(.title3.bold())
                        } else { Text("Lift unknown").font(.title3.bold()) }
                        if let heading=sample.heading,let p=sample.lens {
                            Text(String(format:"Position live · heading %.1f°\nLens %.1f, %.1f, %.1f mm",heading,p.x,p.y,p.z)).monospacedDigit()
                        } else { Text("Position unknown · aim at a wall mark") }
                    } else {
                        Text("Waiting for blade frames").font(.headline)
                        Text(connection)
                    }
                }.padding()
            }.onChange(of:sample?.time,initial:true) { _, _ in
                guard let s=sample,s.time>lastFrame else { return }
                lastFrame=s.time
                events.append(FixtureEvent(time:Date().timeIntervalSince1970,walls:s.walls,sliders:s.sliders,positionMM:s.lens.map{[$0.x,$0.y,$0.z]},heading:s.heading,lift:s.lift))
                if events.count>450 { events.removeFirst(50) }
                if events.count == 1 || events.count % 5 == 0 {
                    try? JSONEncoder().encode(events).write(to:.cachesDirectory.appending(path:"FixtureLive.json"),options:.atomic)
                }
            }
        }.navigationTitle("Wall and slider")
        .onAppear {
            priorIdle=UIApplication.shared.isIdleTimerDisabled
            UIApplication.shared.isIdleTimerDisabled=true
            try? FileManager.default.removeItem(at:URL.cachesDirectory.appending(path:"FixtureLive.json"))
            TrainerBlade.shared.enableFixture(phase == .active)
        }.onChange(of:phase) { _, state in TrainerBlade.shared.enableFixture(state == .active) }
        .onDisappear { TrainerBlade.shared.enableFixture(false);UIApplication.shared.isIdleTimerDisabled=priorIdle }
    }
}

struct FixtureSweepReplay: View {
    @State private var status="Replaying both size-4 sweeps…"
    struct Step: Decodable { let name:String;let field:Double;let pose,load,reset:Bool;let angle:Double;let lens:[Float] }
    struct Reading: Codable {let name:String;let walls,sliders:Int;let pose,expectedPose,expectedLoad:Bool;let lift,angleError:Double?;let positionErrorMM:Float?}
    nonisolated static func run() throws -> [Reading] {
        let folder=Bundle.main.resourceURL!.appendingPathComponent("FixtureReplay")
        let steps=try JSONDecoder().decode([Step].self,from:Data(contentsOf:folder.appendingPathComponent("manifest.json")))
        var reader=FixtureSample.reader()
        return try steps.map { step in try autoreleasepool {
            if step.reset {reader=FixtureSample.reader()}
            let path=folder.appendingPathComponent(step.name+".png")
            guard let reader,let source=CGImageSourceCreateWithURL(path as CFURL,nil),
                  let image=CGImageSourceCreateImageAtIndex(source,0,nil) else {throw CocoaError(.fileReadCorruptFile)}
            let s=FixtureSample(image:image,reader:reader,time:0,field:step.field)
            return Reading(name:step.name,walls:s.walls,sliders:s.sliders,pose:s.camera != nil,expectedPose:step.pose,expectedLoad:step.load,lift:s.lift,angleError:s.lift.map{abs($0-step.angle)},positionErrorMM:s.lens.map{simd_distance($0,SIMD3(step.lens[0],step.lens[1],step.lens[2]))})
        }}
    }
    var body: some View {
        Text(status).task {
            do {
                let rows=try await Task.detached {try Self.run()}.value
                try JSONEncoder().encode(rows).write(to:.cachesDirectory.appending(path:"FixtureReplay.json"),options:.atomic)
                let misses=rows.filter{$0.pose != $0.expectedPose || ($0.lift != nil) != $0.expectedLoad}.count
                status="\(rows.count) frames · \(misses) tracking-state differences"
            } catch {status=error.localizedDescription}
        }
    }
}
#endif
