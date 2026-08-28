import XCTest

/// The generated AppleScript is only ever executed against a live Safari, so
/// nothing at runtime tells us it is malformed — a bad script just returns an
/// error and the link quietly opens in a window instead. These pin the shape.
final class SafariTabTests: XCTestCase {

    func testEscapesQuotesAndBackslashes() {
        XCTAssertEqual(SafariTab.escaped("plain"), "plain")
        XCTAssertEqual(SafariTab.escaped("a\"b"), "a\\\"b")
        XCTAssertEqual(SafariTab.escaped("a\\b"), "a\\\\b")
        // Backslash first, or escaping the quote would be undone by escaping the
        // backslash that was just added.
        XCTAssertEqual(SafariTab.escaped("a\\\"b"), "a\\\\\\\"b")
    }

    func testScriptCarriesTheURL() {
        let script = SafariTab.script(for: URL(string: "https://www.dropbox.com/s/a/f.pdf?dl=0")!)
        XCTAssertTrue(script.contains("https://www.dropbox.com/s/a/f.pdf?dl=0"))
        XCTAssertTrue(script.contains("com.apple.Safari"))
        XCTAssertTrue(script.contains("make new tab"))
    }

    func testScriptGivesUpWhenThereIsNoWindow() {
        // Without this guard, `front window` raises inside Safari rather than
        // returning control, and the fallback never runs.
        let script = SafariTab.script(for: URL(string: "https://example.com")!)
        XCTAssertTrue(script.contains("if (count of windows) is 0 then error"))
    }

    func testGeneratedScriptCompiles() {
        // The real check: AppleScript's own parser, which is the thing that will
        // reject a typo in the terminology at runtime.
        let script = SafariTab.script(for: URL(string: "https://www.dropbox.com/s/a/f.pdf")!)
        var error: NSDictionary?
        let compiled = NSAppleScript(source: script)
        XCTAssertNotNil(compiled)
        XCTAssertTrue(compiled?.compileAndReturnError(&error) ?? false,
                      "AppleScript failed to compile: \(error ?? [:])")
    }

    func testOnlyClaimsSafari() {
        let chrome = SafariTab.open(URL(string: "https://example.com")!,
                                    bundleID: "com.google.Chrome")
        XCTAssertFalse(chrome, "must decline any browser other than Safari")
    }
}
