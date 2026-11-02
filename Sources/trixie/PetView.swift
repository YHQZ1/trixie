import SwiftUI

enum Palette {
    static let body = Color(red: 199 / 255, green: 120 / 255, blue: 93 / 255)
    static let dark = Color(red: 8 / 255, green: 8 / 255, blue: 8 / 255)
    static let white = Color.white
    static let blush = Color(red: 232 / 255, green: 150 / 255, blue: 130 / 255)
    static let soft = Color(white: 0.66)
    static let spark = Color(red: 240 / 255, green: 200 / 255, blue: 120 / 255)
}

/// The live pet: redraws about 30 times a second.
struct PetView: View {
    static let unit: CGFloat = 7                       // size of one "pixel" in points
    static let size = CGSize(width: 244, height: 262)  // the transparent window

    let model: PetModel

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
            let snap = model.snapshot()
            let t = timeline.date.timeIntervalSinceReferenceDate
            Canvas { gc, size in
                var context = gc
                PetPainter(s: snap, t: t, size: size).draw(into: &context)
            }
        }
        .frame(width: Self.size.width, height: Self.size.height)
    }
}

/// A still picture of the pet at one moment, used by `--preview`.
struct PetStill: View {
    let snapshot: PetSnapshot
    let time: TimeInterval
    var body: some View {
        Canvas { gc, size in
            var context = gc
            PetPainter(s: snapshot, t: time, size: size).draw(into: &context)
        }
        .frame(width: PetView.size.width, height: PetView.size.height)
    }
}

/// Draws the pet as a grid of squares ("half units"). Everything is snapped to the
/// grid so movement looks like pixel art. Body: 16 wide, 14 tall; legs below it.
struct PetPainter {
    let s: PetSnapshot
    let t: TimeInterval
    let size: CGSize
    private let u = PetView.unit

    init(s: PetSnapshot, t: TimeInterval, size: CGSize) {
        self.s = s; self.t = t; self.size = size
    }

    func draw(into gc: inout GraphicsContext) {
        let ox = size.width / 2 - 8 * u                        // body centred
        let oy = (size.height - 30 * u) / 2 + 10 * u            // room above for bubbles and hops
        let m = s.mood

        // How high the pet is lifted this frame (hop on arrival, bobbing while breathing/talking).
        var lift = 0.0
        let hopAge = t - s.hopStart
        if hopAge >= 0 && hopAge < 0.55 {
            let p = hopAge / 0.55
            lift += (4 * 6 * p * (1 - p)).rounded()
        }
        switch m {
        case .idle, .listening, .thinking, .working: lift += sin(t * 2.2) > 0.35 ? 1 : 0
        case .talking: lift += sin(t * 11) > 0 ? 1 : 0
        case .happy: lift += sin(t * 14) > 0 ? 1 : 0
        case .sleeping: lift -= 1
        }

        func rect(_ x: Double, _ y: Double, _ w: Double, _ h: Double, _ color: Color,
                  lifted: Bool = true, opacity: Double = 1) {
            let top = y - (lifted ? lift : 0)
            gc.fill(
                Path(CGRect(x: ox + x * u, y: oy + top * u, width: w * u, height: h * u)),
                with: .color(color.opacity(opacity))
            )
        }

        // Ground shadow stays put while the pet hops.
        rect(1, 18.4, 14, 1, .black, lifted: false, opacity: 0.22)

        // Legs (they tap while talking or working).
        for (i, lx) in [0.0, 4.0, 10.0, 14.0].enumerated() {
            var h = 4.0
            if (m == .talking || m == .working) && (Int(t * 8) + i) % 2 == 0 { h = 3 }
            rect(lx, 14, 2, h, Palette.body)
        }

        // Body
        rect(0, 0, 16, 14, Palette.body)

        // Arms
        var leftArm = 6.0, rightArm = 6.0
        switch m {
        case .idle:
            leftArm -= sin(t * 1.5) > 0.55 ? 1 : 0
            rightArm -= sin(t * 1.5 + 1.7) > 0.55 ? 1 : 0
        case .listening: rightArm = 2                                   // hand up to the ear
        case .thinking: break
        case .working:                                                   // "typing"
            leftArm -= Int(t * 7) % 2 == 0 ? 1 : 0
            rightArm -= Int(t * 7) % 2 == 1 ? 1 : 0
        case .talking:
            rightArm -= sin(t * 5) > 0.6 ? 2 : 0
            leftArm -= sin(t * 5 + 2) > 0.7 ? 1 : 0
        case .happy: leftArm = 3; rightArm = 3
        case .sleeping: leftArm = 8; rightArm = 8
        }
        rect(-4, leftArm, 4, 4, Palette.body)
        rect(16, rightArm, 4, 4, Palette.body)

        // Eyes: follow the cursor when idle, listening or talking.
        let follows = m == .idle || m == .listening || m == .talking
        var lx = follows ? Double(s.lookX) : 0
        var ly = follows ? Double(s.lookY) : 0
        if m == .thinking { lx = 1; ly = -1 }
        if m == .working { lx = 0; ly = 1 }
        let blinking = t.truncatingRemainder(dividingBy: 4.6) < 0.13 && m != .listening

        func eye(_ x: Double, _ y: Double, _ w: Double, _ h: Double) {
            rect(x + lx, y + ly, w, h, Palette.dark)
            rect(x + lx, y + ly, 1, 1, Palette.white)   // little highlight
        }
        switch m {
        case .sleeping:
            rect(3, 5, 2, 1, Palette.dark); rect(11, 5, 2, 1, Palette.dark)
        case .happy:
            for ex in [3.0, 11.0] {
                rect(ex + 1, 3, 2, 1, Palette.dark)
                rect(ex, 4, 1, 1, Palette.dark); rect(ex + 3, 4, 1, 1, Palette.dark)
            }
        default:
            if blinking {
                rect(3 + lx, 4 + ly, 2, 1, Palette.dark); rect(11 + lx, 4 + ly, 2, 1, Palette.dark)
            } else if m == .listening {
                eye(3, 1, 2, 5); eye(11, 1, 2, 5)
            } else {
                eye(3, 2, 2, 4); eye(11, 2, 2, 4)
            }
        }

        // Mouth
        switch m {
        case .talking:
            if sin(t * 10) > 0 { rect(7, 8, 2, 2, Palette.dark) } else { rect(7, 8, 2, 1, Palette.dark) }
        case .listening: rect(7, 8, 2, 2, Palette.dark)
        case .happy:
            rect(6, 8, 1, 1, Palette.dark); rect(7, 9, 2, 1, Palette.dark); rect(9, 8, 1, 1, Palette.dark)
        case .thinking: rect(7, 9, 2, 1, Palette.dark)
        case .sleeping: break
        default: rect(7, 8, 2, 1, Palette.dark)
        }

        // Cheeks
        if m != .sleeping {
            rect(1, 7, 2, 1, Palette.blush); rect(13, 7, 2, 1, Palette.blush)
        }

        // Extras that go with each mood
        switch m {
        case .listening:   // sound waves next to the raised hand
            for (i, x) in [22.0, 24.0].enumerated() {
                let h = 2.0 + Double((Int(t * 6) + i * 2) % 3) * 1.5
                rect(x, 4 - (h / 2).rounded(), 1, h.rounded(), Palette.soft, opacity: 0.8)
            }
        case .thinking, .working:   // bubbles drifting up
            let colour = m == .working ? Palette.spark : Palette.soft
            let speed = m == .working ? 2.2 : 1.2
            for i in 0..<3 {
                let phase = (t * speed + Double(i) / 3).truncatingRemainder(dividingBy: 1)
                rect(5 + Double(i) * 3, (-2 - phase * 8).rounded(), 2, 2, colour, opacity: 1 - phase)
            }
        case .happy:
            for (i, p) in [(-5.0, -1.0), (19.0, -3.0), (21.0, 5.0)].enumerated() where (Int(t * 6) + i) % 3 != 0 {
                rect(p.0, p.1 - 1, 1, 3, Palette.spark); rect(p.0 - 1, p.1, 3, 1, Palette.spark)
            }
        case .sleeping:   // floating Zs
            for i in 0..<3 {
                let phase = (t * 0.35 + Double(i) / 3).truncatingRemainder(dividingBy: 1)
                let zx = (15 + Double(i) * 2 + phase * 3).rounded()
                let zy = (-1 - phase * 10).rounded()
                let a = sin(phase * .pi)
                // A 4x4 "Z": top bar, two diagonal squares, bottom bar.
                rect(zx, zy, 4, 1, Palette.soft, opacity: a)
                rect(zx + 2, zy + 1, 1, 1, Palette.soft, opacity: a)
                rect(zx + 1, zy + 2, 1, 1, Palette.soft, opacity: a)
                rect(zx, zy + 3, 4, 1, Palette.soft, opacity: a)
            }
        default: break
        }
    }
}

/// Renders every mood to one PNG, so the look can be checked without opening the app.
enum PetPreview {
    @MainActor
    static func render(to path: String) {
        let moods: [(String, PetMood)] = [
            ("idle", .idle), ("listening", .listening), ("thinking", .thinking), ("working", .working),
            ("talking", .talking), ("happy", .happy), ("sleeping", .sleeping),
        ]
        let sheet = HStack(spacing: 0) {
            ForEach(Array(moods.enumerated()), id: \.offset) { _, item in
                VStack(spacing: 0) {
                    PetStill(
                        snapshot: PetSnapshot(mood: item.1, since: 0, hopStart: -1000, lookX: 0, lookY: 0),
                        time: item.1 == .talking ? 0.2 : (item.1 == .working ? 0.16 : 1.0)
                    )
                    Text(item.0).font(.system(size: 16, design: .monospaced)).foregroundColor(.gray)
                }
            }
        }
        .padding(16)
        .background(Color(white: 0.09))

        let renderer = ImageRenderer(content: sheet)
        renderer.scale = 1
        guard let image = renderer.nsImage, let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else {
            print("preview failed"); return
        }
        try? png.write(to: URL(fileURLWithPath: path))
        print("wrote \(path)")
    }
}
