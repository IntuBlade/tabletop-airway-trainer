import SwiftUI

struct AirwayFrame: View {
    let frame: PracticeFrame
    var selections: StillAnswer? = nil
    var showReference = false
    var tag: ((ImagePoint) -> Void)? = nil

    var body: some View {
        Canvas { context, size in
            let bounds = CGRect(origin: .zero, size: size)
            context.fill(Path(bounds), with: .color(Color(red: 0.20, green: 0.088, blue: 0.082)))

            let centerX = 0.5 + frame.shift
            let surround = LandmarkRegion(center: .init(x: centerX, y: 0.56), radiusX: 0.33, radiusY: 0.40)
            context.fill(Path(ellipseIn: rect(surround, size)), with: .color(Color(red: 0.49, green: 0.26, blue: 0.23)))
            let throat = LandmarkRegion(center: .init(x: centerX, y: 0.56), radiusX: 0.22, radiusY: 0.31)
            context.fill(Path(ellipseIn: rect(throat, size)), with: .color(Color(red: 0.30, green: 0.13, blue: 0.12)))

            for landmark in Landmark.allCases {
                if let region = frame.region(for: landmark) {
                    let color: Color = landmark == .epiglottis
                        ? Color(red: 0.73, green: 0.43, blue: 0.36)
                        : Color(red: 0.08, green: 0.035, blue: 0.036)
                    let contour = Path(ellipseIn: rect(region, size))
                    context.fill(contour, with: .color(color))
                    if showReference { context.stroke(contour, with: .color(.mint), lineWidth: 2) }
                }
                if case let .point(point)? = selections?[landmark] {
                    let pin = CGRect(x: point.x * size.width - 5, y: point.y * size.height - 5, width: 10, height: 10)
                    context.fill(Path(ellipseIn: pin), with: .color(.orange))
                }
            }
        }
        .aspectRatio(4 / 3.0, contentMode: .fit)
        .clipShape(.rect(cornerRadius: 14))
        .accessibilityLabel("Synthetic airway frame")
        .overlay {
            if let tag {
                GeometryReader { geometry in
                    Color.clear.contentShape(Rectangle()).onTapGesture { point in
                        tag(.init(x: point.x / geometry.size.width, y: point.y / geometry.size.height))
                    }
                }
            }
        }
    }

    private func rect(_ region: LandmarkRegion, _ size: CGSize) -> CGRect {
        CGRect(x: (region.center.x - region.radiusX) * size.width,
               y: (region.center.y - region.radiusY) * size.height,
               width: region.radiusX * 2 * size.width,
               height: region.radiusY * 2 * size.height)
    }
}
