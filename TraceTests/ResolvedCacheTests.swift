import XCTest

/// The remembered-path cache is what makes a repeat click instant, and the
/// only thing that resolves a link while Dropbox is unreachable. Its failure modes are silent: a stale entry
/// reveals the wrong file, and a dropped one just feels slow.
final class ResolvedCacheTests: XCTestCase {

    private var file = ""
    private let link = URL(string: "https://www.dropbox.com/s/abc/Brief.pdf?dl=0")!

    override func setUpWithError() throws {
        try super.setUpWithError()
        ResolvedCache.clear()
        file = NSTemporaryDirectory() + "TraceTests-" + UUID().uuidString + ".pdf"
        FileManager.default.createFile(atPath: file, contents: Data())
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(atPath: file)
        ResolvedCache.clear()
        try super.tearDownWithError()
    }

    func testRemembersAndReturnsAPath() {
        ResolvedCache.remember(link, path: file)
        XCTAssertEqual(ResolvedCache.lookup(link)?.path, file)
        XCTAssertEqual(ResolvedCache.count, 1)
    }

    func testAFreshEntryDoesNotNeedRevalidating() {
        ResolvedCache.remember(link, path: file)
        XCTAssertEqual(ResolvedCache.lookup(link)?.needsRevalidation, false)
    }

    func testRefusesAPathThatHasGone() throws {
        ResolvedCache.remember(link, path: file)
        try FileManager.default.removeItem(atPath: file)
        XCTAssertNil(ResolvedCache.lookup(link), "a moved or deleted file must not be revealed")
    }

    func testTheQueryStringIsNotPartOfTheIdentity() {
        // The same file is shared with dl=0, st=…, and no query at all. They are
        // one link, or the cache misses on almost every real click.
        ResolvedCache.remember(link, path: file)
        let sameFile = URL(string: "https://www.dropbox.com/s/abc/Brief.pdf?dl=1&st=xyz")!
        XCTAssertEqual(ResolvedCache.lookup(sameFile)?.path, file)
    }

    func testDifferentLinksDoNotCollide() {
        ResolvedCache.remember(link, path: file)
        let other = URL(string: "https://www.dropbox.com/s/xyz/Other.pdf")!
        XCTAssertNil(ResolvedCache.lookup(other))
    }

    func testReadsTheOriginalStorageFormat() {
        // Written by a version before entries carried a timestamp. Dropping
        // these would silently empty every existing install's cache.
        let key = (link.host?.lowercased() ?? "") + link.path
        UserDefaults.standard.set([key: file], forKey: "resolvedLinks")

        let hit = ResolvedCache.lookup(link)
        XCTAssertEqual(hit?.path, file)
        XCTAssertEqual(hit?.needsRevalidation, true, "no timestamp means it is due a re-check")
    }

    func testClearEmptiesIt() {
        ResolvedCache.remember(link, path: file)
        ResolvedCache.clear()
        XCTAssertEqual(ResolvedCache.count, 0)
        XCTAssertNil(ResolvedCache.lookup(link))
    }
}
