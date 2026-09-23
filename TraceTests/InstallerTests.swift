import XCTest

/// Where the app is running from decides whether it may take the default
/// browser slot, whether the launch repair runs, and whether a move is offered.
/// A wrong answer either nags an installed copy or lets a Downloads copy claim
/// links it will lose.
final class InstallerTests: XCTestCase {

    private let home = "/Users/someone"

    private func location(_ path: String) -> Installer.Location {
        Installer.location(of: path, home: home)
    }

    func testApplicationsFolders() {
        XCTAssertEqual(location("/Applications/Trace.app"), .applications)
        XCTAssertEqual(location("/Applications/Utilities/Trace.app"), .applications)
        XCTAssertEqual(location("/Users/someone/Applications/Trace.app"), .applications)
    }

    func testDownloadedCopies() {
        XCTAssertEqual(location("/Users/someone/Downloads/Trace.app"), .elsewhere)
        XCTAssertEqual(location("/Users/someone/Desktop/Trace.app"), .elsewhere)
        // A folder merely *named* like Applications is not one.
        XCTAssertEqual(location("/Users/someone/Downloads/Applications Old/Trace.app"), .elsewhere)
    }

    func testTranslocationWinsOverTheTemporaryFolderItLivesIn() {
        XCTAssertEqual(
            location("/private/var/folders/xy/abc/T/AppTranslocation/1234-5678/d/Trace.app"),
            .translocated
        )
    }

    func testBuildAndScriptFolders() {
        XCTAssertEqual(
            location("/Users/someone/Library/Developer/Xcode/DerivedData/Trace-x/Build/Products/Release/Trace.app"),
            .buildFolder
        )
        // Where install.sh and release.sh build and smoke-test.
        XCTAssertEqual(location("/private/var/folders/xy/abc/T/tmp.Q1w2e3/out/Trace.app"), .buildFolder)
        XCTAssertEqual(location("/var/folders/xy/abc/T/tmp.Q1w2e3/out/Trace.app"), .buildFolder)
    }
}
