import Foundation
import Testing
@testable import BestOCRKit

/// #24 — the `ocr-to` skill's safety rules, as code. Every test here exists
/// because the rule it pins was previously prose an agent could skip.
struct MarkdownMathTests {
    /// pandoc's own rule: the opening `$` has a non-space to its right, the
    /// closing `$` has a non-space to its left and is not followed by a digit.
    /// Getting this wrong in either direction is expensive — a false negative
    /// sends equations to macdoc as literal LaTeX, a false positive sends prose
    /// through a math-aware path that mangles currency.
    @Test(arguments: [
        "the estimator $\\hat{\\beta}$ is unbiased",
        "$$y = X\\beta + \\varepsilon$$",
        "inline $x^2$ and more text",
    ])
    func detectsRealMath(markdown: String) {
        #expect(MarkdownMath.containsMath(markdown))
    }

    @Test(arguments: [
        "it costs $5 and $10 more",          // currency: closing $ preceded by space
        "$ x $",                              // opening $ followed by space
        "plain prose with no dollars at all",
        "a lone $ sign",
    ])
    func rejectsNonMath(markdown: String) {
        #expect(!MarkdownMath.containsMath(markdown))
    }

    /// A price list must not be turned into an equation by a trailing digit.
    @Test func closingDollarFollowedByDigitIsNotMath() {
        #expect(!MarkdownMath.containsMath("from $10to $20"))
    }

    @Test func fencedCodeIsNotMath() {
        let markdown = """
        text

        ```bash
        echo "$HOME/$USER"
        ```

        more text
        """
        #expect(!MarkdownMath.containsMath(markdown))
    }

    @Test func inlineCodeSpansAreNotMath() {
        #expect(!MarkdownMath.containsMath("use `$x$` as a placeholder"))
    }

    @Test func escapedDollarsAreNotMath() {
        #expect(!MarkdownMath.containsMath("costs \\$5 and \\$10"))
    }

    /// Display math split across lines is the common OCR output shape.
    @Test func multilineDisplayMathIsMath() {
        let markdown = """
        before

        $$
        \\sum_{i=1}^{n} x_i
        $$

        after
        """
        #expect(MarkdownMath.containsMath(markdown))
    }

    @Test func mathInsideAFenceStaysExcludedButMathOutsideCounts() {
        let markdown = """
        ```
        $inside$
        ```
        $outside^2$
        """
        #expect(MarkdownMath.containsMath(markdown))
    }
}

struct OutputPlannerTests {
    /// The rule that exists because a hand-made `.docx` next to the input was
    /// nearly overwritten: output goes to its own directory by default.
    @Test func defaultOutputDirectoryIsNeverTheInputDirectory() {
        let input = URL(fileURLWithPath: "/data/scans/exam.pdf")
        let out = OutputPlanner.defaultOutDir(for: input)
        #expect(out.lastPathComponent == "bestocr-out")
        #expect(out.deletingLastPathComponent().path == "/data/scans")
        #expect(out.path != input.deletingLastPathComponent().path)
    }

    @Test func plansMarkdownAndTargetPerInput() {
        let plans = OutputPlanner.plan(inputs: [URL(fileURLWithPath: "/a/one.pdf")],
                                      outDir: URL(fileURLWithPath: "/out"),
                                      targetExtension: "docx")
        #expect(plans.count == 1)
        #expect(plans[0].markdown.path == "/out/one.md")
        #expect(plans[0].target.path == "/out/one.docx")
    }

    /// Two same-named files from different folders in one batch must not
    /// overwrite each other — the second silently winning is the whole bug.
    @Test func duplicateStemsAreDisambiguatedBySourceFolder() {
        let plans = OutputPlanner.plan(
            inputs: [URL(fileURLWithPath: "/a/2024/exam.pdf"),
                     URL(fileURLWithPath: "/a/2025/exam.pdf")],
            outDir: URL(fileURLWithPath: "/out"), targetExtension: "docx")
        let targets = plans.map(\.target.lastPathComponent)
        #expect(Set(targets).count == 2)
        // Suffixed symmetrically: with only one renamed you cannot tell from the
        // output which file came from which folder.
        #expect(targets.contains("exam-2024.docx"))
        #expect(targets.contains("exam-2025.docx"))
    }

    /// Same stem AND same parent name — disambiguation must still terminate
    /// with distinct names rather than looping or colliding.
    @Test func stemsThatCollideEvenAfterFolderSuffixFallBackToAnIndex() {
        let plans = OutputPlanner.plan(
            inputs: [URL(fileURLWithPath: "/x/v/exam.pdf"),
                     URL(fileURLWithPath: "/y/v/exam.pdf"),
                     URL(fileURLWithPath: "/z/v/exam.pdf")],
            outDir: URL(fileURLWithPath: "/out"), targetExtension: "docx")
        #expect(Set(plans.map(\.target.path)).count == 3)
        #expect(Set(plans.map(\.markdown.path)).count == 3)
    }

    /// Refusing is the honest CLI behaviour: it cannot ask, so it must not guess.
    @Test func existingOutputsAreReportedSoTheRunCanRefuse() throws {
        let dir = try Fixtures.tempDir()
        let plans = OutputPlanner.plan(inputs: [URL(fileURLWithPath: "/a/one.pdf")],
                                      outDir: dir, targetExtension: "docx")
        #expect(OutputPlanner.existingOutputs(plans).isEmpty)
        try "already here".write(to: plans[0].target, atomically: true, encoding: .utf8)
        #expect(OutputPlanner.existingOutputs(plans) == [plans[0].target])
    }
}

struct DocxValidatorTests {
    /// "The command exited 0" is not evidence that a document was produced.
    @Test func rejectsMissingEmptyAndNonZipFiles() throws {
        let dir = try Fixtures.tempDir()
        let missing = dir.appendingPathComponent("nope.docx")
        #expect(throws: OCREngineError.self) { try DocxValidator.validate(missing) }

        let empty = dir.appendingPathComponent("empty.docx")
        try Data().write(to: empty)
        #expect(throws: OCREngineError.self) { try DocxValidator.validate(empty) }

        let text = dir.appendingPathComponent("text.docx")
        try "not a zip at all".write(to: text, atomically: true, encoding: .utf8)
        #expect(throws: OCREngineError.self) { try DocxValidator.validate(text) }
    }

    /// A ZIP that is not a Word document is the subtle failure — a converter can
    /// emit one and still exit 0.
    @Test func rejectsAZipWithoutTheWordDocumentPart() throws {
        let dir = try Fixtures.tempDir()
        let url = dir.appendingPathComponent("odd.docx")
        var bytes = Data([0x50, 0x4B, 0x03, 0x04])   // PK\03\04
        bytes.append(Data("some/other/part.xml".utf8))
        try bytes.write(to: url)
        #expect(throws: OCREngineError.self) { try DocxValidator.validate(url) }
    }

    @Test func acceptsAZipCarryingTheWordDocumentPart() throws {
        let dir = try Fixtures.tempDir()
        let url = dir.appendingPathComponent("ok.docx")
        var bytes = Data([0x50, 0x4B, 0x03, 0x04])
        bytes.append(Data("word/document.xml".utf8))
        try bytes.write(to: url)
        try DocxValidator.validate(url)
    }
}

struct FileConverterTests {
    /// Content decides, not preference: math goes to pandoc when it exists
    /// because only pandoc yields native OMath (#3).
    @Test func mathPrefersPandocAndPlainTextPrefersMacdoc() {
        #expect(FileConverter.order(hasMath: true, forced: nil, pandocAvailable: true)
                == [.pandoc, .macdoc])
        #expect(FileConverter.order(hasMath: false, forced: nil, pandocAvailable: true)
                == [.macdoc, .pandoc])
    }

    /// pandoc missing must not strand a math document — macdoc still converts
    /// it, and the fidelity loss is disclosed rather than hidden.
    @Test func withoutPandocMathStillConvertsViaMacdoc() {
        #expect(FileConverter.order(hasMath: true, forced: nil, pandocAvailable: false)
                == [.macdoc])
    }

    /// An explicit choice is honoured with no fallback — the user overrode the
    /// heuristic on purpose, and silently using the other tool would make the
    /// attribution in the report a lie.
    @Test func anExplicitConverterIsTheOnlyCandidate() {
        #expect(FileConverter.order(hasMath: true, forced: .macdoc, pandocAvailable: true)
                == [.macdoc])
        #expect(FileConverter.order(hasMath: false, forced: .pandoc, pandocAvailable: true)
                == [.pandoc])
    }

    @Test func attributionNamesTheFidelityConsequence() {
        #expect(FileConverter.attribution(.pandoc).contains("OMath"))
        let macdoc = FileConverter.attribution(.macdoc)
        #expect(macdoc.contains("LaTeX"))
        #expect(macdoc.contains("pandoc"))   // says how to get native equations
    }

    @Test func availabilityCarriesAnInstallHintWhenAbsent() {
        for kind in FileConverter.Kind.allCases {
            if case .unavailable(let reason, let hint) = FileConverter.availability(kind) {
                #expect(!reason.isEmpty)
                #expect(hint?.isEmpty == false)
            }
        }
    }

    // Live: both converters are probe-gated, so this skips cleanly when absent.
    @Test(arguments: FileConverter.Kind.allCases)
    func converterProducesAValidDocx(kind: FileConverter.Kind) throws {
        guard case .available = FileConverter.availability(kind) else {
            print("SKIP: \(kind.rawValue) not installed")
            return
        }
        let dir = try Fixtures.tempDir()
        let markdown = dir.appendingPathComponent("sample.md")
        try "# Title\n\nThe estimator $\\hat{\\beta}$ is unbiased.\n"
            .write(to: markdown, atomically: true, encoding: .utf8)
        let target = dir.appendingPathComponent("sample.docx")
        let outcome = try FileConverter.convert(kind, markdown: markdown, target: target)
        #expect(outcome.kind == kind)
        try DocxValidator.validate(target)
    }
}
