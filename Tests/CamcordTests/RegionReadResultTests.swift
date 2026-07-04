import Testing

@testable import Camcord

@Suite("RegionReadResult")
struct RegionReadResultTests {

    @Test("text only → text, unchanged")
    func textOnly() {
        let r = RegionReadResult(text: "hello\nworld", barcodes: [])
        #expect(r.clipboardString == "hello\nworld")
        #expect(!r.isEmpty)
    }

    @Test("barcode only → the payload")
    func barcodeOnly() {
        let r = RegionReadResult(text: "", barcodes: ["https://example.com"])
        #expect(r.clipboardString == "https://example.com")
        #expect(!r.isEmpty)
    }

    @Test("codes come before text")
    func codesFirst() {
        let r = RegionReadResult(text: "scan me", barcodes: ["WIFI:S:net;;"])
        #expect(r.clipboardString == "WIFI:S:net;;\nscan me")
    }

    @Test("multiple codes each on their own line")
    func multipleCodes() {
        let r = RegionReadResult(text: "", barcodes: ["one", "two"])
        #expect(r.clipboardString == "one\ntwo")
    }

    @Test("an OCR line that duplicates a code payload is dropped")
    func dropsDuplicateLine() {
        // The digits printed under an EAN barcode: OCR reads them, the scanner decodes them.
        let r = RegionReadResult(text: "0123456789012", barcodes: ["0123456789012"])
        #expect(r.clipboardString == "0123456789012")
    }

    @Test("a spaced EAN caption is deduped against the raw payload (whitespace-normalized)")
    func dropsSpacedDuplicateLine() {
        // EAN captions are printed with grouping spaces; payloadString has none.
        let r = RegionReadResult(text: "5 901234 123457", barcodes: ["5901234123457"])
        #expect(r.clipboardString == "5901234123457")
    }

    @Test("duplicate drop only removes exact-line matches, keeps other text")
    func keepsNonDuplicateText() {
        let r = RegionReadResult(text: "Price\n0123456789012\n$9.99", barcodes: ["0123456789012"])
        #expect(r.clipboardString == "0123456789012\nPrice\n$9.99")
    }

    @Test("empty text and no codes is empty and trims to nothing")
    func empty() {
        let r = RegionReadResult(text: "", barcodes: [])
        #expect(r.isEmpty)
        #expect(r.clipboardString == "")
    }

    @Test("surrounding whitespace/newlines are trimmed")
    func trims() {
        let r = RegionReadResult(text: "\n  spaced  \n", barcodes: [])
        #expect(r.clipboardString == "spaced")
    }
}
