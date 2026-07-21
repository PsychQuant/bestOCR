import AppKit
import Foundation

/// Programmatic fixtures — no binary files in git. Big clean type so Vision
/// and tesseract recognize deterministically.
enum Fixtures {
    static func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("bestocr-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// 800×200 white PNG with `text` drawn in 72 pt black bold.
    static func textImage(_ text: String) throws -> URL {
        let size = NSSize(width: 800, height: 200)
        let image = NSImage(size: size, flipped: false) { rect in
            NSColor.white.setFill()
            rect.fill()
            (text as NSString).draw(
                at: NSPoint(x: 40, y: 60),
                withAttributes: [
                    .font: NSFont.boldSystemFont(ofSize: 72),
                    .foregroundColor: NSColor.black,
                ]
            )
            return true
        }
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else {
            throw NSError(domain: "Fixtures", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "PNG encode failed"])
        }
        let url = try tempDir().appendingPathComponent("fixture.png")
        try png.write(to: url)
        return url
    }

    /// US-letter PDF with `pages` pages, each showing `text` + page number in 48 pt.
    static func textPDF(_ text: String, pages: Int) throws -> URL {
        let url = try tempDir().appendingPathComponent("fixture.pdf")
        var mediaBox = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let ctx = CGContext(url as CFURL, mediaBox: &mediaBox, nil) else {
            throw NSError(domain: "Fixtures", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "PDF context failed"])
        }
        for page in 1...pages {
            ctx.beginPDFPage(nil)
            let attr = NSAttributedString(
                string: "\(text) page \(page)",
                attributes: [.font: NSFont.boldSystemFont(ofSize: 48),
                             .foregroundColor: NSColor.black]
            )
            let line = CTLineCreateWithAttributedString(attr)
            ctx.textPosition = CGPoint(x: 72, y: 400)
            CTLineDraw(line, ctx)
            ctx.endPDFPage()
        }
        ctx.closePDF()
        return url
    }
}
