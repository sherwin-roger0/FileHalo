import Cocoa
import SwiftUI
import PDFKit
import UniformTypeIdentifiers
import ImageIO
import CoreImage
import Vision
import ServiceManagement
import AVFoundation
import CoreText

let accent = NSColor.systemGray
let appName = "FileHalo"

struct Failure: LocalizedError { let message: String; var errorDescription: String? { message } }
func failure(_ s: String) -> Failure { Failure(message: s) }
func uniqueURL(_ source: URL, _ suffix: String, _ ext: String) -> URL {
    let base = source.deletingPathExtension().lastPathComponent + suffix
    let dir = source.deletingLastPathComponent()
    var u = dir.appendingPathComponent(base).appendingPathExtension(ext)
    var n = 2
    while FileManager.default.fileExists(atPath: u.path) { u = dir.appendingPathComponent("\(base) \(n)").appendingPathExtension(ext); n += 1 }
    return u
}
func loadImage(_ url: URL) throws -> NSImage {
    if url.pathExtension.lowercased() == "pdf", let page = PDFDocument(url: url)?.page(at: 0) {
        let b = page.bounds(for: .mediaBox)
        return page.thumbnail(of: NSSize(width: b.width * 2, height: b.height * 2), for: .mediaBox)
    }
    guard let im = NSImage(contentsOf: url), im.isValid else { throw failure("This file cannot be opened as an image.") }
    return im
}
func bitmap(_ im: NSImage) throws -> CGImage {
    var r = CGRect(origin: .zero, size: im.size)
    guard let cg = im.cgImage(forProposedRect: &r, context: nil, hints: nil) else { throw failure("Could not decode the image.") }
    return cg
}
func saveImage(_ image: NSImage, to url: URL, quality: Double = 0.88) throws {
    let cg = try bitmap(image)
    let ext = url.pathExtension.lowercased()
    if ext == "pdf" {
        let doc = PDFDocument(); guard let p = PDFPage(image: image) else { throw failure("Could not create PDF.") }; doc.insert(p, at: 0)
        guard doc.write(to: url) else { throw failure("Could not write PDF.") }; return
    }
    let types = ["jpg": "public.jpeg", "jpeg": "public.jpeg", "png": "public.png", "heic": "public.heic", "tiff": "public.tiff", "bmp": "com.microsoft.bmp", "gif": "com.compuserve.gif", "webp": "org.webmproject.webp"]
    guard let type = types[ext] else { throw failure("Unsupported image format: \(ext)") }
    guard let dest = CGImageDestinationCreateWithURL(url as CFURL, type as CFString, 1, nil) else { throw failure("This Mac cannot encode \(ext.uppercased()). Try PNG, JPG, TIFF, or HEIC.") }
    CGImageDestinationAddImage(dest, cg, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
    guard CGImageDestinationFinalize(dest) else { throw failure("Could not save image.") }
}
func textFrom(_ u: URL) throws -> String {
    if u.pathExtension.lowercased() == "pdf" {
        guard let doc = PDFDocument(url:u) else { throw failure("Invalid PDF") }
        if let text = doc.string, !text.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty { return text }
        var pages: [String] = []
        for i in 0..<doc.pageCount {
            guard let page = doc.page(at:i) else { continue }
            let image = page.thumbnail(of:NSSize(width:1800,height:2400),for:.mediaBox)
            let request = VNRecognizeTextRequest(); request.recognitionLevel = .accurate; request.usesLanguageCorrection = true
            try VNImageRequestHandler(cgImage:bitmap(image)).perform([request])
            pages.append((request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator:"\n"))
        }
        return pages.joined(separator:"\n\n")
    }
    if ["docx", "doc", "rtf", "html", "odt"].contains(u.pathExtension.lowercased()) { return try NSAttributedString(url: u, options: [:], documentAttributes: nil).string }
    return try String(contentsOf: u, encoding: .utf8)
}
func writeTextPDF(_ text: String, to url: URL) throws {
    var mediaBox = CGRect(x: 0, y: 0, width: 540, height: 720)
    guard let consumer = CGDataConsumer(url: url as CFURL), let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else { throw failure("Could not create PDF.") }
    let font = CTFontCreateWithName("Helvetica" as CFString, 12, nil)
    let attributed = NSAttributedString(string: text, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font])
    let framesetter = CTFramesetterCreateWithAttributedString(attributed)
    var location = 0
    while location < attributed.length {
        context.beginPDFPage(nil)
        let path = CGPath(rect: CGRect(x: 24, y: 24, width: 492, height: 672), transform: nil)
        let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: location, length: 0), path, nil)
        CTFrameDraw(frame, context)
        let visible = CTFrameGetVisibleStringRange(frame)
        guard visible.length > 0 else { context.endPDFPage(); throw failure("Could not lay out the text as PDF.") }
        location = visible.location + visible.length
        context.endPDFPage()
    }
    if attributed.length == 0 { context.beginPDFPage(nil); context.endPDFPage() }
    context.closePDF()
}
func bundledTool(_ name: String) -> String? {
    if let bundled = Bundle.main.resourceURL?.appendingPathComponent("Tools/\(name)"), FileManager.default.isExecutableFile(atPath:bundled.path) { return bundled.path }
    let paths = ["/opt/homebrew/bin/\(name)", "/usr/local/bin/\(name)"]
    return paths.first(where: { FileManager.default.isExecutableFile(atPath:$0) })
}
final class LockedDouble: @unchecked Sendable {
    private let lock = NSLock(); private var storage: Double?
    func set(_ value: Double?) { lock.withLock { storage = value } }
    func get() -> Double? { lock.withLock { storage } }
}
func mediaDuration(_ url: URL) -> Double? {
    let asset = AVURLAsset(url: url), semaphore = DispatchSemaphore(value: 0), seconds = LockedDouble()
    Task.detached(priority: .utility) {
        let value = try? await asset.load(.duration).seconds
        seconds.set(value); semaphore.signal()
    }
    semaphore.wait(); let value = seconds.get()
    guard let value, value.isFinite, value > 0 else { return nil }
    return value
}
func runFFmpeg(_ args: [String], duration: Double? = nil, progress: ((Double) -> Void)? = nil) throws {
    guard let path = bundledTool("ffmpeg") else { throw failure("FFmpeg is missing from this download. Re-download FileHalo from its website.") }
    let process = Process(); process.executableURL = URL(fileURLWithPath: path)
    process.arguments = ["-nostdin", "-v", "error", "-progress", "pipe:1", "-nostats", "-n"] + args
    let output = Pipe(), errors = Pipe(); process.standardOutput = output; process.standardError = errors
    let outputHandle = output.fileHandleForReading, parseLock = NSLock(); var pending = Data()
    outputHandle.readabilityHandler = { handle in
        let data = handle.availableData
        if data.isEmpty { handle.readabilityHandler = nil; return }
        parseLock.lock(); pending.append(data)
        while let newline = pending.firstIndex(of: 10) {
            let lineData = pending.prefix(upTo: newline); pending.removeSubrange(...newline)
            guard let line = String(data: lineData, encoding: .utf8), let split = line.firstIndex(of: "=") else { continue }
            let key = String(line[..<split]), value = String(line[line.index(after: split)...])
            if key == "out_time_us", let micros = Double(value), let duration, duration > 0 {
                progress?(min(0.99, max(0, micros / (duration * 1_000_000))))
            } else if key == "progress", value == "end" { progress?(1) }
        }
        parseLock.unlock()
    }
    try process.run()
    let errorLock = NSLock(); var errorData = Data(); let errorGroup = DispatchGroup(); errorGroup.enter()
    DispatchQueue.global(qos: .utility).async {
        let data = errors.fileHandleForReading.readDataToEndOfFile()
        errorLock.lock(); errorData = data; errorLock.unlock(); errorGroup.leave()
    }
    process.waitUntilExit()
    outputHandle.readabilityHandler = nil
    _ = outputHandle.readDataToEndOfFile()
    errorGroup.wait(); errorLock.lock(); let data = errorData; errorLock.unlock()
    guard process.terminationStatus == 0 else {
        let message = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        throw failure(message?.isEmpty == false ? message! : "Conversion failed")
    }
}
func convert(_ u: URL, to ext: String, progress: ((Double) -> Void)? = nil) throws -> [URL] {
    let out = uniqueURL(u, "", ext)
    let input = u.pathExtension.lowercased()
    if ["mp4", "mov", "mkv", "webm", "avi", "mp3", "wav", "m4a", "aac", "flac", "ogg"].contains(input) {
        var args = ["-i", u.path]
        if ["mp3", "wav", "m4a", "flac", "ogg"].contains(ext) { args += ["-vn"] }
        if ext == "webm" { args += ["-c:v", "libsvtav1", "-c:a", "libopus"] }
        if ext == "mp4" { args += ["-c:v", "libx264", "-pix_fmt", "yuv420p", "-c:a", "aac", "-movflags", "+faststart"] }
        args += [out.path]
        try runFFmpeg(args, duration: mediaDuration(u), progress: progress)
        return [out]
    }
    if ext == "txt" || ext == "docx" {
        let t = try textFrom(u)
        guard !t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw failure("No selectable text was found. Scanned PDFs need OCR before text conversion.") }
        if ext == "txt" { try t.write(to: out, atomically: true, encoding: .utf8) }
        else {
            let attr = NSAttributedString(string: t, attributes: [.font: NSFont.systemFont(ofSize: 12)])
            let data = try attr.data(from: NSRange(location: 0, length: attr.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.officeOpenXML])
            try data.write(to: out, options: .atomic)
        }; return [out]
    }
    if input == "pdf", let doc = PDFDocument(url: u), ext != "pdf" {
        var result: [URL] = []
        for i in 0..<doc.pageCount {
            guard let page = doc.page(at: i) else { continue }; let b = page.bounds(for: .mediaBox)
            let image = page.thumbnail(of: NSSize(width: b.width * 2, height: b.height * 2), for: .mediaBox)
            let target = doc.pageCount == 1 ? out : uniqueURL(u, " Page \(i + 1)", ext)
            try saveImage(image, to: target); result.append(target)
        }; return result
    }
    if ext == "pdf", ["txt", "docx", "rtf", "html"].contains(input) {
        let text = try textFrom(u)
        try writeTextPDF(text, to: out); return [out]
    }
    if ext == "webp" {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("png")
        defer { try? FileManager.default.removeItem(at: temp) }
        try saveImage(loadImage(u),to:temp)
        guard let encoder = bundledTool("cwebp") else { throw failure("WebP encoder is missing from this download.") }; let process = Process(); process.executableURL = URL(fileURLWithPath:encoder); process.arguments = ["-quiet","-q","88",temp.path,"-o",out.path]; process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        try process.run(); process.waitUntilExit(); guard process.terminationStatus == 0 else { throw failure("WebP encoding failed") }; return [out]
    }
    if ext == "avif" { try runFFmpeg(["-i",u.path,"-frames:v","1","-c:v","libsvtav1","-pix_fmt","yuv420p",out.path]); return [out] }
    try saveImage(loadImage(u), to: out); return [out]
}

func glassHost(_ content: NSView, cornerRadius: CGFloat = 24) -> NSView {
    if #available(macOS 26.0, *) {
        let glass = NSGlassEffectView(frame:content.frame)
        glass.style = .regular
        glass.cornerRadius = cornerRadius
        glass.contentView = content
        content.autoresizingMask = [.width,.height]
        return glass
    }
    let effect = NSVisualEffectView(frame:content.frame)
    effect.material = .hudWindow; effect.blendingMode = .behindWindow; effect.state = .active
    effect.wantsLayer = true; effect.layer?.cornerRadius = cornerRadius; effect.layer?.masksToBounds = true
    content.autoresizingMask = [.width,.height]; effect.addSubview(content)
    return effect
}

struct ConversionJob: Identifiable {
    let id: UUID
    let filename: String
    let target: String
    var progress: Double?
    var status: String
    var isComplete = false
    var error: String?
    var outputs: [URL] = []
}

final class ConversionCenter: ObservableObject {
    @Published private(set) var jobs: [ConversionJob] = []
    var activeCount: Int { jobs.filter { !$0.isComplete }.count }

    func add(_ job: ConversionJob) {
        let action = {
            let finished = self.jobs.filter(\.isComplete)
            if finished.count > 8 {
                let removeIDs = Set(finished.prefix(finished.count - 8).map(\.id))
                self.jobs.removeAll { removeIDs.contains($0.id) }
            }
            self.jobs.append(job)
        }
        if Thread.isMainThread { action() } else { DispatchQueue.main.async(execute: action) }
    }

    func update(_ id: UUID, progress: Double?, status: String) {
        let action = {
            guard let index = self.jobs.firstIndex(where: { $0.id == id }), !self.jobs[index].isComplete else { return }
            self.jobs[index].progress = progress
            self.jobs[index].status = status
        }
        if Thread.isMainThread { action() } else { DispatchQueue.main.async(execute: action) }
    }

    func finish(_ id: UUID, result: Result<[URL], Error>) {
        let action = {
            guard let index = self.jobs.firstIndex(where: { $0.id == id }) else { return }
            self.jobs[index].isComplete = true
            switch result {
            case .success(let files): self.jobs[index].outputs = files; self.jobs[index].progress = 1; self.jobs[index].status = "Complete"
            case .failure(let error): self.jobs[index].error = error.localizedDescription; self.jobs[index].status = "Couldn’t convert"
            }
        }
        if Thread.isMainThread { action() } else { DispatchQueue.main.async(execute: action) }
    }
}

struct ConversionProgressView: View {
    @ObservedObject var center: ConversionCenter

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("Conversions", systemImage: "arrow.triangle.2.circlepath")
                    .font(.system(size: 17, weight: .semibold))
                Spacer()
                if center.activeCount > 0 {
                    Text("\(center.activeCount) jobs")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }
            if center.jobs.isEmpty {
                Text("Your conversions will appear here while FileHalo works.")
                    .font(.system(size: 13)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 12)
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(center.jobs.reversed()) { job in conversionRow(job) }
                    }
                }
                .frame(maxHeight: 390)
            }
        }
        .padding(18)
        .frame(width: 410, alignment: .topLeading)
        .background(Color.clear)
    }

    @ViewBuilder private func conversionRow(_ job: ConversionJob) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 9) {
                Image(systemName: job.error == nil ? (job.isComplete ? "checkmark.circle.fill" : "doc") : "exclamationmark.circle.fill")
                    .foregroundStyle(job.error == nil ? (job.isComplete ? Color.green : Color.secondary) : Color.red)
                VStack(alignment: .leading, spacing: 2) {
                    Text(job.filename).font(.system(size: 12, weight: .medium)).lineLimit(1)
                    Text(job.error ?? "To \(job.target.uppercased()) · \(job.status)")
                        .font(.system(size: 11)).foregroundStyle(job.error == nil ? Color.secondary : Color.red).lineLimit(2)
                }
                Spacer(minLength: 4)
                if !job.outputs.isEmpty {
                    Button("Show") { NSWorkspace.shared.activateFileViewerSelecting(job.outputs) }
                        .font(.system(size: 11, weight: .medium)).buttonStyle(.borderless)
                }
            }
            if !job.isComplete && job.error == nil {
                HStack(spacing: 8) {
                    if let progress = job.progress {
                        ProgressView(value: progress).progressViewStyle(.linear)
                        Text("\(Int(progress * 100))%")
                            .font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary).frame(width: 34, alignment: .trailing)
                    } else {
                        ProgressView().progressViewStyle(.linear)
                    }
                }
            }
        }
        .padding(.vertical, 11)
        .overlay(alignment: .bottom) { Rectangle().fill(Color.primary.opacity(0.08)).frame(height: 1) }
    }
}

class RadialView: NSView {
    var file: URL?; var actions: [String] = []; var selected = -1
    var onDrop: ((URL, String) -> Void)?
    override init(frame: NSRect) { super.init(frame: frame); registerForDraggedTypes([.fileURL]); wantsLayer = true }
    required init?(coder: NSCoder) { fatalError() }
    override var isOpaque: Bool { false }
    func index(_ p: NSPoint) -> Int {
        let scale = bounds.width / 326
        let dx = (p.x - bounds.midX) / scale, dy = (p.y - bounds.midY) / scale
        let radius = hypot(dx, dy)
        guard radius > 44, radius < 151, !actions.isEmpty else { return -1 }
        var a = atan2(dx, dy) + .pi / Double(actions.count)
        if a < 0 { a += 2 * .pi }; return Int(a / (2 * .pi) * Double(actions.count)) % actions.count
    }
    override func draw(_ dirtyRect: NSRect) {
        guard !actions.isEmpty else { return }
        let scale = bounds.width / 326
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current?.cgContext.scaleBy(x:scale,y:scale)
        defer { NSGraphicsContext.restoreGraphicsState() }
        let c = NSPoint(x:163,y:163), n = actions.count
        for i in 0..<n {
            let centerAngle = 90 - Double(i) * 360 / Double(n), half = 180 / Double(n)
            let a = centerAngle - half + 1.5, b = centerAngle + half - 1.5
            let path = NSBezierPath()
            let rad = { (d: Double, r: Double) in NSPoint(x: c.x + cos(d * .pi / 180) * r, y: c.y + sin(d * .pi / 180) * r) }
            path.move(to: rad(a, 49)); path.line(to: rad(a, 143)); path.appendArc(withCenter: c, radius: 143, startAngle: a, endAngle: b); path.line(to: rad(b, 49)); path.appendArc(withCenter: c, radius: 49, startAngle: b, endAngle: a, clockwise: true); path.close()
            (i == selected ? accent.withAlphaComponent(0.65) : NSColor.white.withAlphaComponent(0.10)).setFill(); path.fill()
            NSColor.white.withAlphaComponent(0.42).setStroke(); path.lineWidth = 1; path.stroke()
            let p = rad(centerAngle, 99)
            let label = actions[i].uppercased() as NSString
            let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: actions[i].count > 9 ? 11 : 12, weight: .bold), .foregroundColor: NSColor.labelColor]
            let size = label.size(withAttributes: attrs); label.draw(at: NSPoint(x: p.x-size.width/2, y: p.y-size.height/2), withAttributes: attrs)
        }
        accent.withAlphaComponent(0.72).setFill(); NSBezierPath(ovalIn: NSRect(x: c.x-41, y: c.y-41, width: 82, height: 82)).fill()
        let s = (selected >= 0 ? actions[selected].uppercased() : "SHIFT\n+ DROP") as NSString
        let style = NSMutableParagraphStyle(); style.alignment = .center
        s.draw(in: NSRect(x: c.x-39, y: c.y-16, width: 78, height: 36), withAttributes: [.font: NSFont.systemFont(ofSize: 10, weight: .bold), .paragraphStyle: style, .foregroundColor: NSColor.white])
    }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { draggingUpdated(sender) }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        selected = index(convert(sender.draggingLocation, from: nil)); needsDisplay = true; return selected >= 0 ? .copy : []
    }
    override func draggingExited(_ sender: NSDraggingInfo?) { selected = -1; needsDisplay = true }
    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { selected >= 0 }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard selected >= 0, let u = (sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL])?.first else { return false }
        onDrop?(u, actions[selected]); return true
    }
    override func mouseDown(with event: NSEvent) {
        let i = index(convert(event.locationInWindow, from: nil)); if i >= 0, let file { onDrop?(file, actions[i]) }
    }
}

struct Mark { var a: CGPoint; var b: CGPoint; var redact: Bool }
class EditModel: ObservableObject {
    let source: URL; let image: NSImage; let mode: String
    @Published var left: Double = 0; @Published var right: Double = 0; @Published var top: Double = 0; @Published var bottom: Double = 0
    @Published var padding: Double = 70; @Published var radius: Double = 22; @Published var shadow: Double = 20; @Published var quality: Double = 0.7
    @Published var brightness: Double = 0; @Published var contrast: Double = 1; @Published var saturation: Double = 1; @Published var rotation: Double = 0
    @Published var background = Color.gray; @Published var gradient = true; @Published var marks: [Mark] = []; @Published var message = ""
    var onSave: ((URL) -> Void)?
    init(source: URL, image: NSImage, mode: String) { self.source = source; self.image = image; self.mode = mode }
    func render() throws -> NSImage {
        var cg = try bitmap(image)
        if mode == "Edit" {
            let ci = CIImage(cgImage:cg).applyingFilter("CIColorControls",parameters:[kCIInputBrightnessKey:brightness,kCIInputContrastKey:contrast,kCIInputSaturationKey:saturation]).transformed(by:CGAffineTransform(rotationAngle:rotation * .pi / 180))
            guard let adjusted = CIContext().createCGImage(ci,from:ci.extent) else { throw failure("Could not adjust image") }; cg = adjusted
        }
        let w = CGFloat(cg.width), h = CGFloat(cg.height)
        let crop = CGRect(x: w * left, y: h * top, width: w * (1-left-right), height: h * (1-top-bottom)).integral
        guard crop.width > 0, crop.height > 0, let cut = cg.cropping(to: crop) else { throw failure("The crop area is empty.") }
        let pad = mode == "Add BG" ? CGFloat(padding) * max(w,h)/1000 : 0
        let size = NSSize(width: CGFloat(cut.width)+pad*2, height: CGFloat(cut.height)+pad*2)
        guard let rep = NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:Int(size.width),pixelsHigh:Int(size.height),bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0), let ctx = NSGraphicsContext(bitmapImageRep:rep) else { throw failure("Image is too large to render") }
        NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = ctx
        let rect = NSRect(origin: .zero, size: size)
        if mode == "Add BG" {
            if gradient { NSGradient(colors: [NSColor(background), NSColor(calibratedWhite:0.20,alpha:1), NSColor(calibratedWhite:0.65,alpha:1)])?.draw(in: rect, angle: 35) }
            else { NSColor(background).setFill(); rect.fill() }
        } else { NSColor.clear.setFill(); rect.fill() }
        NSGraphicsContext.saveGraphicsState()
        let target = NSRect(x: pad, y: pad, width: CGFloat(cut.width), height: CGFloat(cut.height))
        let path = NSBezierPath(roundedRect: target, xRadius: mode == "Add BG" ? radius * max(w,h)/1000 : 0, yRadius: mode == "Add BG" ? radius * max(w,h)/1000 : 0)
        if mode == "Add BG" {
            NSGraphicsContext.saveGraphicsState()
            let sh = NSShadow(); sh.shadowColor = .black.withAlphaComponent(0.35); sh.shadowBlurRadius = shadow * max(w,h)/1000; sh.shadowOffset = NSSize(width: 0, height: -5); sh.set()
            NSColor.white.setFill(); path.fill(); NSGraphicsContext.restoreGraphicsState()
        }
        path.addClip()
        NSImage(cgImage: cut, size: target.size).draw(in: target)
        NSGraphicsContext.restoreGraphicsState()
        for m in marks {
            let a = NSPoint(x: m.a.x * size.width, y: (1-m.a.y) * size.height), b = NSPoint(x: m.b.x * size.width, y: (1-m.b.y) * size.height)
            if m.redact { NSColor.black.setFill(); NSRect(x: min(a.x,b.x), y: min(a.y,b.y), width: abs(a.x-b.x), height: abs(a.y-b.y)).fill() }
            else { accent.setStroke(); let p = NSBezierPath(); p.move(to: a); p.line(to: b); p.lineWidth = max(3, size.width/180); p.lineCapStyle = .round; p.stroke() }
        }
        NSGraphicsContext.restoreGraphicsState(); let out = NSImage(size:size); out.addRepresentation(rep); return out
    }
    func save() {
        do { let ext = mode == "Compress" ? "jpg" : "png"; let u = uniqueURL(source, " \(mode)", ext); try saveImage(render(), to: u, quality: quality); message = "Saved \(u.lastPathComponent)"; onSave?(u) } catch { message = error.localizedDescription }
    }
}
struct Editor: View {
    @ObservedObject var m: EditModel
    @State var start: CGPoint?
    func slider(_ label: String, _ binding: Binding<Double>, _ range: ClosedRange<Double>) -> some View { HStack { Text(label).frame(width: 64, alignment: .leading); Slider(value: binding, in: range).tint(.gray) } }
    var body: some View {
        VStack(spacing: 14) {
            Text(m.mode == "Crop" ? "Crop Image" : m.mode).font(.headline)
            GeometryReader { g in
                let im = m.mode == "Crop" ? m.image : ((try? m.render()) ?? m.image)
                Image(nsImage: im).resizable().scaledToFit().frame(maxWidth: .infinity, maxHeight: .infinity)
                    .overlay(GeometryReader { inner in
                        let s = im.size, scale = min(inner.size.width/s.width, inner.size.height/s.height), w = s.width*scale, h = s.height*scale
                        if m.mode == "Crop" {
                            let ox = (inner.size.width-w)/2, oy = (inner.size.height-h)/2
                            Path { p in p.addRect(CGRect(x:ox,y:oy,width:w,height:h)); p.addRect(CGRect(x:ox+w*m.left,y:oy+h*m.top,width:w*(1-m.left-m.right),height:h*(1-m.top-m.bottom))) }.fill(Color.black.opacity(0.45),style:FillStyle(eoFill:true)).allowsHitTesting(false)
                            Rectangle().stroke(Color.gray,lineWidth:2).frame(width:w*(1-m.left-m.right),height:h*(1-m.top-m.bottom)).position(x:ox+w*(m.left+(1-m.left-m.right)/2),y:oy+h*(m.top+(1-m.top-m.bottom)/2)).allowsHitTesting(false)
                            ForEach(0..<4) { corner in
                                let right = corner % 2 == 1, bottom = corner >= 2
                                Circle().fill(Color.gray).frame(width:14,height:14).position(x:ox+w*(right ? 1-m.right : m.left),y:oy+h*(bottom ? 1-m.bottom : m.top)).gesture(DragGesture(coordinateSpace:.named("crop")).onChanged { value in
                                    let x = max(0,min(0.45,(value.location.x-ox)/w)), y = max(0,min(0.45,(value.location.y-oy)/h))
                                    if right { m.right = max(0,min(0.45,1-(value.location.x-ox)/w)) } else { m.left = x }
                                    if bottom { m.bottom = max(0,min(0.45,1-(value.location.y-oy)/h)) } else { m.top = y }
                                })
                            }
                        }
                        Color.clear.contentShape(Rectangle()).frame(width: w,height: h).position(x: inner.size.width/2,y: inner.size.height/2)
                            .allowsHitTesting(m.mode != "Crop")
                            .gesture(DragGesture(minimumDistance: 1).onChanged { value in
                                guard m.mode == "Redact" || m.mode == "Annotate" else { return }
                                let ox = (inner.size.width-w)/2, oy = (inner.size.height-h)/2
                                let p = CGPoint(x: max(0,min(1,(value.location.x-ox)/w)), y: max(0,min(1,(value.location.y-oy)/h)))
                                let a = CGPoint(x: max(0,min(1,(value.startLocation.x-ox)/w)), y: max(0,min(1,(value.startLocation.y-oy)/h)))
                                if m.mode == "Annotate" { m.marks.append(Mark(a: start ?? a,b: p,redact: false)); start = p }
                            }.onEnded { value in
                                if m.mode == "Redact" { let ox = (inner.size.width-w)/2, oy = (inner.size.height-h)/2; let point = { (p: CGPoint) in CGPoint(x: max(0,min(1,(p.x-ox)/w)),y: max(0,min(1,(p.y-oy)/h))) }; m.marks.append(Mark(a: point(value.startLocation),b: point(value.location),redact: true)) }; start = nil
                            })
                    }.coordinateSpace(name:"crop"))
            }.frame(minHeight: 260)
            if m.mode == "Crop" {
                slider("Left", $m.left, 0...0.45); slider("Right", $m.right, 0...0.45); slider("Top", $m.top, 0...0.45); slider("Bottom", $m.bottom, 0...0.45)
            }
            if m.mode == "Add BG" {
                HStack { ColorPicker("Background", selection: $m.background); Toggle("Gradient", isOn: $m.gradient) }
                HStack { ForEach(0..<8) { i in let colors: [Color] = [.gray,.pink,.purple,.blue,.mint,.green,.black,.white]; Button { m.background = colors[i] } label: { Circle().fill(colors[i]).frame(width: 23,height: 23) }.buttonStyle(.plain) } }
                slider("Padding", $m.padding, 0...250); slider("Corners", $m.radius, 0...100); slider("Shadow", $m.shadow, 0...70)
            }
            if m.mode == "Edit" { slider("Brightness", $m.brightness, -0.7...0.7); slider("Contrast", $m.contrast, 0.3...2); slider("Color", $m.saturation, 0...2); HStack { Text("Rotate"); Button("↶ 90°") { m.rotation -= 90 }; Button("↷ 90°") { m.rotation += 90 }; Button("Reset") { m.brightness = 0; m.contrast = 1; m.saturation = 1; m.rotation = 0 } } }
            if m.mode == "Compress" { slider("Quality", $m.quality, 0.1...1); Text("Saves a JPEG. Transparency is replaced with a solid background.").font(.caption) }
            if m.mode == "Redact" || m.mode == "Annotate" { HStack { Text(m.mode == "Redact" ? "Drag over an area to permanently cover it." : "Drag to draw on the image.").font(.caption); Button("Undo") { if !m.marks.isEmpty { m.marks.removeLast() } } } }
            Text(m.message).font(.caption).lineLimit(3).textSelection(.enabled)
            HStack { Text("Original stays unchanged").font(.caption).foregroundStyle(.secondary); Spacer(); Button("Save Copy") { m.save() }.buttonStyle(.borderedProminent).tint(.gray).keyboardShortcut("s", modifiers: .command) }
        }.padding(20).frame(minWidth: 420, idealWidth: 460, minHeight: 580).background(Color.clear)
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    var status: NSStatusItem!; var panel: NSPanel!; var radial: RadialView!; var timer: Timer?; var windows: [NSWindow] = []; var welcome: NSWindow?
    var conversionPanel: NSPanel?; let conversions = ConversionCenter()
    let conversionQueue: OperationQueue = { let queue = OperationQueue(); queue.name = "FileHalo.Conversions"; queue.maxConcurrentOperationCount = 2; queue.qualityOfService = .userInitiated; return queue }()
    var current: URL?; var shiftTracking = false; var manual = false
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        // Follow the system appearance, including dark mode.
        registerLoginItem()
        status = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        status.button?.image = NSImage(systemSymbolName: "circle.hexagongrid.fill", accessibilityDescription: appName); status.button?.contentTintColor = accent
        let menu = NSMenu(); menu.addItem(withTitle: "FileHalo — File tools", action: nil, keyEquivalent: "")
        menu.addItem(item("Choose File…", #selector(choose), "o")); menu.addItem(item("Conversion Progress…", #selector(showConversions), "")); menu.addItem(item("How to Use", #selector(showWelcome), "")); menu.addItem(.separator()); menu.addItem(item("Quit FileHalo", #selector(quit), "q")); status.menu = menu
        panel = NSPanel(contentRect: NSRect(x: 0,y: 0,width: 248,height: 248), styleMask: [.borderless,.nonactivatingPanel], backing: .buffered, defer: false)
        panel.title = "FileHalo Wheel"
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = true; panel.level = .popUpMenu; panel.collectionBehavior = [.canJoinAllSpaces,.fullScreenAuxiliary]; panel.hidesOnDeactivate = false
        radial = RadialView(frame: NSRect(x: 0,y: 0,width: 248,height: 248)); radial.onDrop = { [weak self] u,a in self?.panel.orderOut(nil); self?.manual = false; self?.perform(u,a) }; panel.contentView = glassHost(radial,cornerRadius:124)
        timer = Timer.scheduledTimer(withTimeInterval: 0.045, repeats: true) { [weak self] _ in self?.tick() }
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 { self?.panel.orderOut(nil); self?.manual = false; return nil }; return event
        }
        if let i = CommandLine.arguments.firstIndex(of:"--preview"), CommandLine.arguments.count > i+2 { perform(URL(fileURLWithPath:CommandLine.arguments[i+1]),CommandLine.arguments[i+2]) }
    }
    func registerLoginItem() {
        guard #available(macOS 13.0, *) else { return }
        do {
            if SMAppService.mainApp.status != .enabled { try SMAppService.mainApp.register() }
        } catch {
            NSLog("FileHalo could not register its login item: %@", error.localizedDescription)
        }
    }
    func item(_ title: String,_ action: Selector,_ key: String) -> NSMenuItem { let i = NSMenuItem(title: title,action: action,keyEquivalent: key); i.target = self; return i }
    @objc func quit() { NSApp.terminate(nil) }
    @objc func showConversions() { presentConversions() }
    func presentConversions() {
        if conversionPanel == nil {
            let view = ConversionProgressView(center: conversions)
            let w = NSPanel(contentRect: NSRect(x: 0,y: 0,width: 450,height: 340), styleMask: [.titled,.closable,.utilityWindow,.nonactivatingPanel], backing: .buffered, defer: false)
            w.title = "FileHalo Conversions"; w.isReleasedWhenClosed = false; w.isOpaque = false; w.backgroundColor = .clear
            w.titlebarAppearsTransparent = true; w.level = .floating; w.hidesOnDeactivate = false
            w.contentView = glassHost(NSHostingView(rootView: view), cornerRadius: 18); w.center(); conversionPanel = w
        }
        conversionPanel?.orderFrontRegardless()
    }
    @objc func showWelcome() {
        if let welcome { welcome.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); return }
        let view = VStack(alignment: .leading, spacing: 20) {
            HStack { Image(systemName: "circle.hexagongrid.fill").font(.system(size: 42)).foregroundStyle(.primary); Text("FileHalo").font(.system(size: 36,weight: .bold,design: .rounded)) }
            Text("A little circle. A lot of possibilities.").font(.title3)
            Text("1. Start dragging a file in Finder or on your desktop.\n2. Hold Shift briefly to summon the wheel.\n3. Drop onto a format or tool.").lineSpacing(8)
            Text("Drop on Tools to see image tools, or Formats to return to format choices. Converted files are saved beside the original. PDFs export every page to images.").foregroundStyle(.secondary)
            HStack { Button("Choose a File…") { self.choose() }.buttonStyle(.borderedProminent).tint(.gray) }
            Text("Runs locally • No uploads • Look for the FileHalo icon in the menu bar").font(.caption).foregroundStyle(.secondary)
        }.padding(30).frame(width: 440).background(Color.clear)
        let w = NSWindow(contentRect: NSRect(x: 0,y: 0,width: 500,height: 390),styleMask: [.titled,.closable],backing: .buffered,defer: false); w.title = "Welcome to FileHalo"; w.isOpaque = false; w.backgroundColor = .clear; w.titlebarAppearsTransparent = true; w.contentView = glassHost(NSHostingView(rootView: view)); w.center(); w.isReleasedWhenClosed = false; welcome = w; w.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }
    @objc func choose() { let p = NSOpenPanel(); p.canChooseDirectories = false; p.allowsMultipleSelection = false; NSApp.activate(ignoringOtherApps: true); if p.runModal() == .OK, let u = p.url { current = u; manual = true; display(u, tools: false) } }
    func formats(_ u: URL) -> [String] {
        let ext = u.pathExtension.lowercased()
        if ["mp4","mov","mkv","webm","avi"].contains(ext) { return ["mp4","mov","webm","mp3","wav","m4a"] }
        if ["mp3","wav","m4a","aac","flac","ogg"].contains(ext) { return ["mp3","wav","m4a","flac","ogg"] }
        if ext == "pdf" { return ["docx","jpg","png","txt","Tools"] }
        if ["txt","docx","rtf","html","odt","doc"].contains(ext) { return ["pdf","txt","docx"] }
        return ["jpg","png","webp","heic","tiff","avif","bmp","pdf","Tools"]
    }
    func display(_ u: URL, tools: Bool) {
        radial.file = u; radial.actions = tools ? ["Compress","Metadata","Edit","Annotate","Add BG","Crop","Redact","Formats"] : formats(u); radial.selected = -1; radial.needsDisplay = true
        let p = NSEvent.mouseLocation; let screen = NSScreen.screens.first(where: { $0.frame.contains(p) })?.visibleFrame ?? NSScreen.main!.visibleFrame
        let x = max(screen.minX,min(p.x-124,screen.maxX-248)), y = max(screen.minY,min(p.y-124,screen.maxY-248))
        if !panel.isVisible { panel.setFrameOrigin(NSPoint(x: x,y: y)) }; panel.orderFrontRegardless()
    }
    func tick() {
        let dragging = NSEvent.pressedMouseButtons & 1 != 0, shift = NSEvent.modifierFlags.contains(.shift)
        if dragging && shift {
            let pb = NSPasteboard(name: .drag)
            if let u = (pb.readObjects(forClasses: [NSURL.self],options: [.urlReadingFileURLsOnly: true]) as? [URL])?.first {
                if !shiftTracking { shiftTracking = true; current = u }
                let desired = formats(u)
                if !panel.isVisible || radial.actions != desired { display(u,tools: false) }
            }
        } else {
            shiftTracking = false
            if !manual && panel.isVisible && !dragging { panel.orderOut(nil) }
        }

    }
    func report(_ s: String, error: Bool = false) {
        NSApp.activate(ignoringOtherApps: true); let a = NSAlert(); a.messageText = error ? "Couldn’t complete that" : "Saved successfully"; a.informativeText = s; a.alertStyle = error ? .warning : .informational; a.runModal()
    }
    func perform(_ u: URL,_ action: String) {
        if action == "Tools" || action == "Formats" { manual = true; display(u,tools: action == "Tools"); return }
        if action == "Metadata" {
            do { let attrs = try FileManager.default.attributesOfItem(atPath: u.path); var s = "\(u.lastPathComponent)\n\(u.path)\n\nSize: \(ByteCountFormatter.string(fromByteCount: (attrs[.size] as? NSNumber)?.int64Value ?? 0,countStyle: .file))\nModified: \(attrs[.modificationDate] ?? "Unknown")\n"
                if let src = CGImageSourceCreateWithURL(u as CFURL,nil), let props = CGImageSourceCopyPropertiesAtIndex(src,0,nil) { s += "\n\(props)" }
                let tv = NSTextView(frame: NSRect(x: 0,y: 0,width: 560,height: 450)); tv.string = s; tv.isEditable = false; tv.font = .monospacedSystemFont(ofSize: 12,weight: .regular); let scroll = NSScrollView(frame: tv.frame); scroll.documentView = tv; scroll.hasVerticalScroller = true; tv.autoresizingMask = [.width]; let w = NSWindow(contentRect: tv.frame,styleMask: [.titled,.closable,.resizable],backing: .buffered,defer: false); w.title = "Metadata"; w.contentView = scroll; present(w)
            } catch { report(error.localizedDescription,error: true) }; return
        }
        if ["Crop","Add BG","Redact","Annotate","Compress","Edit"].contains(action) {
            do { let m = EditModel(source: u,image: try loadImage(u),mode: action); m.onSave = { NSWorkspace.shared.activateFileViewerSelecting([$0]) }; let w = NSWindow(contentRect: NSRect(x: 0,y: 0,width: 460,height: 690),styleMask: [.titled,.closable,.resizable],backing: .buffered,defer: false); w.titlebarAppearsTransparent = true; w.isOpaque = false; w.backgroundColor = .clear; w.title = action; w.contentView = glassHost(NSHostingView(rootView: Editor(m: m))); present(w) } catch { report(error.localizedDescription,error: true) }; return
        }
        let id = UUID()
        conversions.add(ConversionJob(id: id, filename: u.lastPathComponent, target: action, progress: nil, status: "Queued"))
        presentConversions()
        conversionQueue.addOperation { [conversions] in
            conversions.update(id, progress: nil, status: "Working…")
            let result = Result { try convert(u, to: action, progress: { value in
                conversions.update(id, progress: value, status: "Converting · \(Int(value * 100))%")
            }) }
            conversions.finish(id, result: result)
            DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self, conversions] in
                if conversions.activeCount == 0 { self?.conversionPanel?.orderOut(nil) }
            }
        }
    }
    func present(_ w: NSWindow) { w.isReleasedWhenClosed = false; windows.append(w); w.center(); w.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true) }
}
let application = NSApplication.shared
if CommandLine.arguments.contains("--self-test") {
    do {
        let dir = URL(fileURLWithPath: CommandLine.arguments.last!).appendingPathComponent("filehalo-tests")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let source = dir.appendingPathComponent("sample.png")
        let image = NSImage(size: NSSize(width: 800,height: 600)); image.lockFocus(); NSColor.white.setFill(); NSRect(x:0,y:0,width:800,height:600).fill(); accent.setFill(); NSRect(x:100,y:100,width:400,height:300).fill(); image.unlockFocus()
        try saveImage(image,to: source)
        for ext in ["jpg","png","tiff","heic","bmp","pdf","webp","avif"] {
            let result = try convert(source,to:ext); guard result.allSatisfy({ FileManager.default.fileExists(atPath:$0.path) }) else { throw failure("Missing conversion " + ext) }; print("PASS image → " + ext)
        }
        let doc = PDFDocument(); doc.insert(PDFPage(image:image)!,at:0); doc.insert(PDFPage(image:image)!,at:1); let pdf = dir.appendingPathComponent("pages.pdf"); guard doc.write(to:pdf) else { throw failure("PDF fixture") }; let pages = try convert(pdf,to:"png"); guard pages.count == 2 else { throw failure("Missing PDF pages") }; print("PASS multipage PDF")
        let txt = dir.appendingPathComponent("text.txt"); try "FileHalo conversion test\nHello from the Mac.".write(to:txt,atomically:true,encoding:.utf8)
        let word = try convert(txt,to:"docx")[0]; guard try textFrom(word).contains("Hello from the Mac") else { throw failure("DOCX roundtrip") }; print("PASS DOCX roundtrip")
        for mode in ["Crop","Add BG","Redact","Annotate","Compress","Edit"] {
            let m = EditModel(source:source,image:image,mode:mode)
            if mode == "Crop" { m.left = 0.1; m.top = 0.1 }
            if mode == "Redact" { m.marks = [Mark(a:CGPoint(x:0.1,y:0.1),b:CGPoint(x:0.5,y:0.5),redact:true)] }
            if mode == "Annotate" { m.marks = [Mark(a:CGPoint(x:0.1,y:0.1),b:CGPoint(x:0.9,y:0.9),redact:false)] }
            let rendered = try m.render(); let cg = try bitmap(rendered)
            if mode == "Crop" { let original = try bitmap(image); guard cg.width == Int(Double(original.width)*0.9) && cg.height == Int(Double(original.height)*0.9) else { throw failure("Crop dimensions \(cg.width)x\(cg.height)") } }
            if mode == "Add BG" { guard cg.width > 800 && cg.height > 600 else { throw failure("Background dimensions") } }
            try saveImage(rendered,to:dir.appendingPathComponent(mode + ".png")); print("PASS editor " + mode)
        }
        let wheel = RadialView(frame:NSRect(x:0,y:0,width:326,height:326)); wheel.actions = ["DOCX","JPG","PNG","TXT"]
        guard wheel.index(NSPoint(x:163,y:263)) == 0, wheel.index(NSPoint(x:263,y:163)) == 1, wheel.index(NSPoint(x:163,y:163)) == -1 else { throw failure("Radial selection") }; print("PASS wheel hit testing")
        print("ALL CHECKS PASSED"); exit(0)
    } catch { fputs("SELF TEST FAILED: \(error)\n",stderr); exit(1) }
}
let delegate = AppDelegate()
application.delegate = delegate
application.run()
