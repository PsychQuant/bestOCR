import Foundation

/// "The converter exited 0" is not evidence that a document exists. The
/// `ocr-to` skill asked an agent to check this by hand (#1 step 5); here it is a
/// gate the pipeline cannot skip.
public enum DocxValidator {
    /// A `.docx` is a ZIP whose main part is `word/document.xml`. ZIP stores
    /// entry names uncompressed in each local header, so a byte search for the
    /// name is a sound structural check without unzipping anything.
    static let requiredPart = "word/document.xml"
    static let zipMagic: [UInt8] = [0x50, 0x4B, 0x03, 0x04]   // "PK\u{03}\u{04}"

    public static func validate(_ url: URL) throws {
        guard let data = try? Data(contentsOf: url) else {
            throw OCREngineError(engine: "convert",
                                 message: "no output produced at \(url.path)")
        }
        guard !data.isEmpty else {
            throw OCREngineError(engine: "convert",
                                 message: "output is empty: \(url.path)")
        }
        guard data.starts(with: zipMagic) else {
            throw OCREngineError(engine: "convert",
                                 message: "output is not a ZIP container, so it is not a docx: \(url.path)")
        }
        guard data.range(of: Data(requiredPart.utf8)) != nil else {
            throw OCREngineError(engine: "convert",
                                 message: "output is a ZIP but has no \(requiredPart) — not a Word document: \(url.path)")
        }
    }
}
