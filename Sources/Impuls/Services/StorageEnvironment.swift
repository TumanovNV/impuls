import Foundation

/// `~/Library/Application Support/Impuls`, and the difference between naming it
/// and making it.
///
/// Those used to be one act: the stores' `defaultFileURL` was a `static let`
/// whose initializer called `createDirectory`, so merely *asking where the notes
/// live* created the folder. Nothing in the app minded — it asks on the way to
/// reading them — but a test asserting the app's own layout created
/// `Application Support/Impuls` on a machine that had never run Impuls. A path
/// is an answer to a question, not an instruction.
///
/// Resolution is therefore pure, and the folder is created by the code that is
/// about to write into it, which is also the only code that needs it to exist.
enum ApplicationSupport {
    /// Pure. Creates nothing, touches nothing, and `base` exists so a test can
    /// prove that on a directory that is not there.
    static func file(named name: String, in base: URL) -> URL {
        base
            .appendingPathComponent("Impuls", isDirectory: true)
            .appendingPathComponent(name, isDirectory: false)
    }

    static func file(named name: String) -> URL {
        file(named: name, in: userBase)
    }

    /// Called immediately before a write — never on the way to a path.
    static func ensureParentDirectory(for url: URL) {
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
    }

    /// `urls(for:in:)` enumerates; it is `url(for:in:appropriateFor:create:)`
    /// that would create, and it is deliberately not used here.
    private static var userBase: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    }
}

/// Where the file-backed stores keep what they hold.
///
/// These paths used to be constants on the store types, which made
/// `~/Library/Application Support/Impuls` a fact about the process rather than a
/// dependency of an object. Anything that built a `NotchViewModel` therefore
/// read the real files, and `stop()` — which flushes the notes synchronously so
/// nothing typed is lost on quit — wrote one of them back. Tests build the view
/// model too: a multi-display test, which mentions notes nowhere, left a line of
/// its own text in a real `notes.json`. The store was right; there was simply no
/// way to build one that pointed somewhere else.
///
/// The app uses `.live` and nothing else, so its behaviour is unchanged. A test
/// passes its own value into a temporary directory, which means persistence is
/// exercised for real — load, debounce, atomic write, synchronous flush — inside
/// a sandbox that goes away with the test, rather than being stubbed out.
struct StorageEnvironment {
    var notes: URL
    var snippets: URL

    /// Built on demand rather than passed in, so `.live` neither opens the
    /// archive nor takes its key merely by being read.
    ///
    /// A test passes `nil` — deliberately, and not a temporary file. The
    /// archive's key is a single generic password in the login keychain, shared
    /// with the user's real history, and `delete()`, which
    /// `ClipboardStore.configurePersistence` reaches on any switch-off, revokes
    /// it. Pointing a test at a temporary archive would still leave it holding
    /// the one key that makes the user's own archive readable. `ClipboardStore`
    /// has taken an optional persistence since 1.4.3 for this reason.
    var makeClipboardHistory: () -> ClipboardHistoryPersistence?

    static var live: StorageEnvironment {
        StorageEnvironment(
            notes: NoteStore.defaultFileURL,
            snippets: SnippetStore.defaultFileURL,
            makeClipboardHistory: { ClipboardHistoryPersistence() }
        )
    }
}
