import AppKit

// Writes the base 🎯 icon as an .iconset; build.sh turns it into AppIcon.icns with iconutil.
let out = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        guard let png = IconRenderer.png(label: nil, pixels: base * scale) else {
            FileHandle.standardError.write(Data("cannot render \(name)\n".utf8))
            exit(1)
        }
        try png.write(to: out.appendingPathComponent(name))
    }
}
