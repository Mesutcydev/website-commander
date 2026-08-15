import Foundation

@MainActor
final class WorkspacePortabilityStore: ObservableObject {
    static let shared = WorkspacePortabilityStore()

    @Published private(set) var assets: [SharedAsset] = []
    @Published private(set) var mountedFolders: [MountedFolder] = []

    private let fileManager: FileManager
    private let defaults: UserDefaults
    private let mountedFoldersKey = "mountedWorkspaceFoldersV1"

    init(
        fileManager: FileManager = .default,
        defaults: UserDefaults = .standard
    ) {
        self.fileManager = fileManager
        self.defaults = defaults
        loadMountedFolders()
        refreshAssets()
    }

    var sharedDirectoryURL: URL {
        fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SiteAgent_Shared", isDirectory: true)
    }

    func refreshAssets() {
        ensureSharedDirectory()
        let keys: Set<URLResourceKey> = [.fileSizeKey, .contentModificationDateKey]
        let urls = (try? fileManager.contentsOfDirectory(
            at: sharedDirectoryURL,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]
        )) ?? []

        assets = urls.compactMap { url in
            guard !url.hasDirectoryPath else { return nil }
            let values = try? url.resourceValues(forKeys: keys)
            return SharedAsset(
                url: url,
                name: url.lastPathComponent,
                byteCount: Int64(values?.fileSize ?? 0),
                modifiedAt: values?.contentModificationDate
            )
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    @discardableResult
    func importFile(from sourceURL: URL) throws -> SharedAsset {
        ensureSharedDirectory()
        let name = sourceURL.lastPathComponent
        guard Self.isSafeFilename(name) else { throw PortabilityError.invalidFilename }
        let destination = uniqueDestination(for: name)
        let scoped = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if scoped { sourceURL.stopAccessingSecurityScopedResource() }
        }
        try fileManager.copyItem(at: sourceURL, to: destination)
        refreshAssets()
        return assets.first(where: { $0.url == destination })
            ?? SharedAsset(url: destination, name: destination.lastPathComponent, byteCount: 0)
    }

    func deleteAsset(_ asset: SharedAsset) throws {
        guard asset.url.deletingLastPathComponent().standardizedFileURL
                == sharedDirectoryURL.standardizedFileURL else {
            throw PortabilityError.invalidFilename
        }
        try fileManager.removeItem(at: asset.url)
        refreshAssets()
    }

    func mountFolder(_ url: URL) throws {
        let scoped = url.startAccessingSecurityScopedResource()
        defer {
            if scoped { url.stopAccessingSecurityScopedResource() }
        }
        let bookmark = try url.bookmarkData(
            options: .minimalBookmark,
            includingResourceValuesForKeys: [.nameKey],
            relativeTo: nil
        )
        let folder = MountedFolder(displayName: url.lastPathComponent, bookmarkData: bookmark)
        mountedFolders.removeAll { $0.displayName == folder.displayName }
        mountedFolders.append(folder)
        mountedFolders.sort {
            $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
        }
        saveMountedFolders()
    }

    func unmountFolder(id: UUID) {
        mountedFolders.removeAll { $0.id == id }
        saveMountedFolders()
    }

    func withResolvedFolder<T>(
        id: UUID,
        operation: (URL) throws -> T
    ) throws -> T {
        guard let folder = mountedFolders.first(where: { $0.id == id }) else {
            throw PortabilityError.folderUnavailable
        }
        var stale = false
        let url = try URL(
            resolvingBookmarkData: folder.bookmarkData,
            options: .withoutUI,
            relativeTo: nil,
            bookmarkDataIsStale: &stale
        )
        guard !stale else { throw PortabilityError.folderUnavailable }
        let scoped = url.startAccessingSecurityScopedResource()
        defer {
            if scoped { url.stopAccessingSecurityScopedResource() }
        }
        return try operation(url)
    }

    static func isSafeFilename(_ filename: String) -> Bool {
        !filename.isEmpty
            && filename != "."
            && filename != ".."
            && !filename.contains("/")
            && !filename.contains("\\")
            && !filename.contains("\0")
    }

    private func ensureSharedDirectory() {
        if !fileManager.fileExists(atPath: sharedDirectoryURL.path) {
            try? fileManager.createDirectory(
                at: sharedDirectoryURL,
                withIntermediateDirectories: true
            )
        }
    }

    private func uniqueDestination(for filename: String) -> URL {
        let original = sharedDirectoryURL.appendingPathComponent(filename)
        guard fileManager.fileExists(atPath: original.path) else { return original }

        let base = (filename as NSString).deletingPathExtension
        let ext = (filename as NSString).pathExtension
        var suffix = 2
        while true {
            let candidateName = ext.isEmpty
                ? "\(base)-\(suffix)"
                : "\(base)-\(suffix).\(ext)"
            let candidate = sharedDirectoryURL.appendingPathComponent(candidateName)
            if !fileManager.fileExists(atPath: candidate.path) { return candidate }
            suffix += 1
        }
    }

    private func loadMountedFolders() {
        guard let data = defaults.data(forKey: mountedFoldersKey),
              let decoded = try? JSONDecoder().decode([MountedFolder].self, from: data) else {
            return
        }
        mountedFolders = decoded
    }

    private func saveMountedFolders() {
        defaults.set(try? JSONEncoder().encode(mountedFolders), forKey: mountedFoldersKey)
    }
}
