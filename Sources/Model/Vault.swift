#if !os(macOS)
import Foundation

/// The Obsidian vault, on the phone.
///
/// iOS gives no path into another app's iCloud container, so the journal cannot be
/// opened the way it is on the Mac. What iOS does allow is a folder the person hands
/// over themselves: a document picker returns a security-scoped URL, and a bookmark
/// keeps it across launches. That is the whole mechanism.
///
/// None of it needs an iCloud entitlement, which is the point. An entitlement means a
/// paid developer account, and this app is signed with a free one.
@MainActor
final class Vault: ObservableObject {
    static let shared = Vault()
    private static let key = "vaultBookmark"

    /// The folder holding the daily notes, or nil while none has been picked. Nil is
    /// not an error: it is the state the app ships in, and the workouts come from the
    /// calendar feed until it changes.
    @Published private(set) var journalDir: URL?

    /// What to show for it. The folder's own name, not the path, which for a file
    /// provider URL is long and says nothing.
    var label: String? { journalDir?.lastPathComponent }

    /// Held for the life of the app. The access has to be open whenever a note is read,
    /// and there is no moment in a calendar's life when it is done reading.
    private var scoped: URL?

    private init() { restore() }

    /// Takes the folder the picker returned.
    func adopt(_ url: URL) {
        guard url.startAccessingSecurityScopedResource() else { return }
        if let data = try? url.bookmarkData() {
            UserDefaults.standard.set(data, forKey: Self.key)
        }
        open(url)
    }

    func forget() {
        scoped?.stopAccessingSecurityScopedResource()
        scoped = nil
        journalDir = nil
        UserDefaults.standard.removeObject(forKey: Self.key)
    }

    private func restore() {
        guard let data = UserDefaults.standard.data(forKey: Self.key) else { return }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: data, bookmarkDataIsStale: &stale),
              url.startAccessingSecurityScopedResource() else { return }
        // A stale bookmark still resolves. Writing the fresh one back is what stops it
        // failing the next time the folder moves.
        if stale, let fresh = try? url.bookmarkData() {
            UserDefaults.standard.set(fresh, forKey: Self.key)
        }
        open(url)
    }

    /// The vault root and the journal folder inside it are both reasonable things to
    /// point at, and the picker gives no way to say which was meant, so accept either.
    private func open(_ url: URL) {
        scoped = url
        let inner = url.appendingPathComponent(Config.journalFolder)
        var isDir: ObjCBool = false
        let hasInner = FileManager.default.fileExists(atPath: inner.path, isDirectory: &isDir)
        journalDir = hasInner && isDir.boolValue ? inner : url
    }
}
#endif
