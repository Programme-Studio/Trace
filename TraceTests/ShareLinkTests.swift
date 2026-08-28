import XCTest

/// The link-shape logic decides how many network round trips a click costs, and
/// a wrong answer here never looks like a bug — it looks like Dropbox being
/// slow. That is exactly why it is worth pinning down.
final class ShareLinkTests: XCTestCase {

    private func url(_ string: String) -> URL {
        guard let url = URL(string: string) else {
            XCTFail("not a URL: \(string)")
            return URL(fileURLWithPath: "/")
        }
        return url
    }

    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: "preferredLinkShape")
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: "preferredLinkShape")
        super.tearDown()
    }

    // MARK: - What gets intercepted

    func testInterceptsShareLinks() {
        XCTAssertTrue(ShareLink.shouldIntercept(url("https://www.dropbox.com/scl/fi/abc/f.pdf?rlkey=k")))
        XCTAssertTrue(ShareLink.shouldIntercept(url("https://dropbox.com/s/abc/f.pdf")))
    }

    func testIgnoresOtherHosts() {
        XCTAssertFalse(ShareLink.shouldIntercept(url("https://example.com/scl/fi/abc")))
        // Suffix matching must not be fooled by a host that merely ends in the
        // same letters.
        XCTAssertFalse(ShareLink.shouldIntercept(url("https://notdropbox.com/s/abc")))
        XCTAssertFalse(ShareLink.shouldIntercept(url("https://dropbox.com.evil.test/s/abc")))
    }

    func testIgnoresOurOwnAuthFlow() {
        // Intercepting these would break authorising the app, and the loop is
        // invisible from inside it.
        for path in ["/oauth2/authorize", "/developers/apps", "/account", "/login", "/logout"] {
            XCTAssertFalse(
                ShareLink.shouldIntercept(url("https://www.dropbox.com" + path)),
                "should not intercept \(path)"
            )
        }
    }

    func testHostMatchingIsCaseInsensitive() {
        XCTAssertTrue(ShareLink.shouldIntercept(url("https://WWW.DROPBOX.COM/s/abc/f.pdf")))
    }

    // MARK: - Which forms get asked about

    func testModernLinkNeverAsksWithoutItsKey() {
        // On an /scl/ link the rlkey *is* the credential, so a query-stripped
        // variant is a round trip spent to be told no.
        let variants = ShareLink.variants(of: url("https://www.dropbox.com/scl/fi/a/f.pdf?rlkey=k&dl=0"))
        XCTAssertFalse(
            variants.contains { !$0.contains("rlkey") },
            "no variant may drop the rlkey: \(variants)"
        )
    }

    func testModernLinkDropsOnlyTheNoiseParameters() {
        let variants = ShareLink.variants(of: url("https://www.dropbox.com/scl/fi/a/f.pdf?rlkey=k&dl=0&st=xyz"))
        XCTAssertEqual(variants.first, "https://www.dropbox.com/scl/fi/a/f.pdf?rlkey=k&dl=0&st=xyz")
        XCTAssertTrue(variants.contains("https://www.dropbox.com/scl/fi/a/f.pdf?rlkey=k"))
    }

    func testLegacyLinkAlsoTriesTheBareForm() {
        let variants = ShareLink.variants(of: url("https://www.dropbox.com/s/a/f.pdf?dl=0"))
        XCTAssertTrue(variants.contains("https://www.dropbox.com/s/a/f.pdf"))
    }

    func testVariantsAreDistinctAndNeverEmpty() {
        for link in [
            "https://www.dropbox.com/scl/fi/a/f.pdf?rlkey=k",
            "https://www.dropbox.com/s/a/f.pdf",
            "https://www.dropbox.com/s/a/f.pdf?dl=0"
        ] {
            let variants = ShareLink.variants(of: url(link))
            XCTAssertFalse(variants.isEmpty, "no variants for \(link)")
            XCTAssertEqual(Set(variants).count, variants.count, "duplicate variants for \(link)")
        }
    }

    // MARK: - Learning which form works

    func testRememberedShapeIsTriedFirst() {
        let link = url("https://www.dropbox.com/s/a/f.pdf?dl=0")
        let bare = "https://www.dropbox.com/s/a/f.pdf"

        XCTAssertNotEqual(ShareLink.variants(of: link).first, bare, "precondition")

        ShareLink.rememberShape(of: link, matching: bare)
        XCTAssertEqual(ShareLink.variants(of: link).first, bare)
        // Learning an order must not lose a form.
        XCTAssertEqual(ShareLink.variants(of: link).count, 2)
    }

    func testRememberingAnUnknownFormChangesNothing() {
        let link = url("https://www.dropbox.com/s/a/f.pdf?dl=0")
        let before = ShareLink.variants(of: link)
        ShareLink.rememberShape(of: link, matching: "https://example.com/not-a-variant")
        XCTAssertEqual(ShareLink.variants(of: link), before)
    }

    func testARememberedShapeThatThisLinkLacksIsIgnored() {
        // "bare" is never offered for an /scl/ link. Having learned it from a
        // legacy link must not reorder — or drop — anything here.
        ShareLink.rememberShape(
            of: url("https://www.dropbox.com/s/a/f.pdf?dl=0"),
            matching: "https://www.dropbox.com/s/a/f.pdf"
        )
        let variants = ShareLink.variants(of: url("https://www.dropbox.com/scl/fi/a/f.pdf?rlkey=k&dl=0"))
        XCTAssertEqual(variants.first, "https://www.dropbox.com/scl/fi/a/f.pdf?rlkey=k&dl=0")
    }
}
