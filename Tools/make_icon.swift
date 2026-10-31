// アプリアイコンを生成する: swift Tools/make_icon.swift → Resources/AppIcon.icns
import SwiftUI
import AppKit

struct Icon: View {
    var body: some View {
        ZStack {
            // macOS 標準グリッド: 1024 キャンバスに 824 の角丸四角
            RoundedRectangle(cornerRadius: 185, style: .continuous)
                .fill(LinearGradient(colors: [Color(red: 0.25, green: 0.62, blue: 0.98),
                                              Color(red: 0.17, green: 0.32, blue: 0.86)],
                                     startPoint: .top, endPoint: .bottom))
                .frame(width: 824, height: 824)
                .shadow(color: .black.opacity(0.3), radius: 14, y: 10)

            // 写真
            photo
                .rotationEffect(.degrees(-8))
                .offset(x: -70, y: -60)

            // カレンダー
            calendar
                .rotationEffect(.degrees(6))
                .offset(x: 170, y: 175)
        }
        .frame(width: 1024, height: 1024)
    }

    var photo: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 22).fill(.white)
            ZStack {
                LinearGradient(colors: [Color(red: 1.0, green: 0.82, blue: 0.55),
                                        Color(red: 1.0, green: 0.62, blue: 0.45)],
                               startPoint: .top, endPoint: .bottom)
                Circle().fill(Color(red: 1.0, green: 0.95, blue: 0.75))
                    .frame(width: 90).offset(x: 95, y: -75)
                Mountain(peak: 0.35, height: 0.62)
                    .fill(Color(red: 0.36, green: 0.30, blue: 0.62))
                Mountain(peak: 0.72, height: 0.45)
                    .fill(Color(red: 0.24, green: 0.20, blue: 0.48))
            }
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .padding(26)
        }
        .frame(width: 500, height: 420)
        .shadow(color: .black.opacity(0.35), radius: 18, y: 10)
    }

    var calendar: some View {
        VStack(spacing: 0) {
            ZStack {
                Color(red: 0.93, green: 0.26, blue: 0.24)
                Text("12:00")
                    .font(.system(size: 50, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
            }
            .frame(height: 92)
            ZStack {
                Color.white
                Text("03")
                    .font(.system(size: 170, weight: .heavy, design: .rounded))
                    .foregroundStyle(Color(red: 0.15, green: 0.15, blue: 0.2))
            }
        }
        .frame(width: 290, height: 300)
        .clipShape(RoundedRectangle(cornerRadius: 36, style: .continuous))
        .shadow(color: .black.opacity(0.35), radius: 18, y: 10)
    }
}

struct Mountain: Shape {
    let peak: CGFloat, height: CGFloat
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.minX - r.width * 0.2, y: r.maxY))
        p.addLine(to: CGPoint(x: r.minX + r.width * peak, y: r.maxY - r.height * height))
        p.addLine(to: CGPoint(x: r.maxX + r.width * 0.2, y: r.maxY))
        p.closeSubpath()
        return p
    }
}

@MainActor func render(size: Int, to url: URL) {
    let renderer = ImageRenderer(content: Icon())
    renderer.scale = CGFloat(size) / 1024
    guard let cg = renderer.cgImage else { fatalError("render failed") }
    let rep = NSBitmapImageRep(cgImage: cg)
    try! rep.representation(using: .png, properties: [:])!.write(to: url)
}

let root = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ".")
let iconset = root.appendingPathComponent("build/AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try! FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
MainActor.assumeIsolated {
    for base in [16, 32, 128, 256, 512] {
        render(size: base, to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
        render(size: base * 2, to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
    }
    render(size: 1024, to: root.appendingPathComponent("Resources/AppIcon.png"))
}
