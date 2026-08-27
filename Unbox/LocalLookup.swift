import Foundation

/// Maps a Dropbox path onto this Mac's disk, and says precisely what's missing
/// when it can't.
///
/// This is where selective sync gets handled. Dropbox may happily report that a
/// file lives at `/Clients/Acme/brief.pdf` while that whole branch is excluded
/// from sync locally — a completely normal state, not a malfunction. Rather than
/// a blanket "not found", we walk the path and report the first component that
/// isn't there, so the message can name the folder to un-exclude.
///
/// Note that online-only ("smart sync") files are *not* this case: the file
/// provider keeps placeholders on disk, so they resolve and open normally.
enum LocalLookup {

    enum Result {
        /// The file or folder is on disk at this path.
        case found(String)

        /// The path exists in Dropbox but a component is missing locally.
        /// `missingComponent` is the Dropbox-relative path of the first thing
        /// that isn't there; `isLeaf` is true when it's the file itself rather
        /// than a parent folder.
        case notSynced(missingComponent: String, deepestLocalFolder: String, isLeaf: Bool)

        /// The Dropbox root itself is gone — app not running, signed out, moved.
        case rootMissing(String)

        /// The path didn't land on disk. Worth a second look before believing it.
        var isMiss: Bool {
            if case .notSynced = self { return true }
            return false
        }
    }

    static func locate(dropboxPath: String, root: String) -> Result {
        let fm = FileManager.default

        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: root, isDirectory: &isDirectory), isDirectory.boolValue else {
            return .rootMissing(root)
        }

        let components = dropboxPath.split(separator: "/").map(String.init)
        var current = root
        var walked: [String] = []

        for (index, component) in components.enumerated() {
            let exact = (current as NSString).appendingPathComponent(component)
            if fm.fileExists(atPath: exact) {
                current = exact
                walked.append(component)
                continue
            }

            // Dropbox gives us a lowercased path; the disk may disagree on case.
            if let entries = try? fm.contentsOfDirectory(atPath: current),
               let match = entries.first(where: { $0.lowercased() == component.lowercased() }) {
                current = (current as NSString).appendingPathComponent(match)
                walked.append(match)
                continue
            }

            return .notSynced(
                missingComponent: (walked + [component]).joined(separator: "/"),
                deepestLocalFolder: current,
                isLeaf: index == components.count - 1
            )
        }

        return .found(trueCase(current))
    }

    /// Dropbox hands back `path_lower`, so the path this walk builds is all
    /// lowercase — `…/2026/projects/uk/5855 stokes place/02 content`. On a
    /// case-insensitive volume that opens perfectly well, which is why it was
    /// never a bug, but it is what the app displays, what it copies to the
    /// clipboard, and what it remembers in the cache, and "02 content" is not
    /// what the folder is called.
    ///
    /// A file reference URL round-trips to the canonical on-disk spelling in
    /// about a millisecond. The `files/get_metadata` call that used to be made
    /// for this same information costs a network round trip — measured at ~750ms
    /// against this account — so this is the same answer roughly a thousand
    /// times cheaper. That call still exists for the genuine miss case, where
    /// the question is whether the file is there at all rather than how it's
    /// spelled.
    private static func trueCase(_ path: String) -> String {
        guard let reference = (URL(fileURLWithPath: path) as NSURL).fileReferenceURL(),
              let resolved = (reference as NSURL).filePathURL
        else { return path }
        return resolved.path
    }
}
