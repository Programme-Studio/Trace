import XCTest

/// `LocalLookup` is what turns a Dropbox path into something Finder can be
/// pointed at, and it has to tell three situations apart: found, the whole
/// Dropbox folder is missing, and this one item hasn't synced. Getting the last
/// two the wrong way round is the difference between a useful message and a
/// wrong one.
final class LocalLookupTests: XCTestCase {

    private var root = ""

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = NSTemporaryDirectory() + "TraceTests-" + UUID().uuidString
        try FileManager.default.createDirectory(
            atPath: root + "/2026/Projects", withIntermediateDirectories: true
        )
        FileManager.default.createFile(atPath: root + "/2026/Projects/Brief.pdf", contents: Data())
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(atPath: root)
        try super.tearDownWithError()
    }

    func testFindsAFileFromItsLowercasedPath() throws {
        // Dropbox returns path_lower, so the real spelling has to be recovered.
        let located = LocalLookup.locate(dropboxPath: "/2026/projects/brief.pdf", root: root)
        guard case .found(let path) = located else {
            return XCTFail("expected .found, got \(located)")
        }
        XCTAssertTrue(path.hasSuffix("Brief.pdf"), "expected the real spelling, got \(path)")
        XCTAssertTrue(FileManager.default.fileExists(atPath: path))
    }

    func testReportsAMissingRootRatherThanAMissingFile() {
        let located = LocalLookup.locate(dropboxPath: "/2026/x.pdf", root: root + "-gone")
        guard case .rootMissing = located else {
            return XCTFail("expected .rootMissing, got \(located)")
        }
    }

    func testAMissingLeafIsReportedAsTheLeaf() {
        let located = LocalLookup.locate(dropboxPath: "/2026/projects/absent.pdf", root: root)
        guard case .notSynced(_, let deepest, let isLeaf) = located else {
            return XCTFail("expected .notSynced, got \(located)")
        }
        XCTAssertTrue(isLeaf, "the file is the only missing part, so this is a leaf")
        XCTAssertTrue(deepest.hasSuffix("Projects"), "expected the deepest real folder, got \(deepest)")
    }

    func testAMissingFolderIsNotReportedAsALeaf() {
        // Selective sync: a whole folder is excluded, so the advice has to be
        // about the folder rather than about a file still downloading.
        let located = LocalLookup.locate(dropboxPath: "/2026/archive/old/x.pdf", root: root)
        guard case .notSynced(let missing, _, let isLeaf) = located else {
            return XCTFail("expected .notSynced, got \(located)")
        }
        XCTAssertFalse(isLeaf)
        XCTAssertTrue(missing.hasSuffix("archive"), "expected the outermost missing part, got \(missing)")
    }

    func testFindsAFolder() {
        let located = LocalLookup.locate(dropboxPath: "/2026/projects", root: root)
        guard case .found(let path) = located else {
            return XCTFail("expected .found, got \(located)")
        }
        XCTAssertTrue(path.hasSuffix("Projects"))
    }
}
