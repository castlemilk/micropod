import Darwin
import Foundation

/// Content last exchanged by a source/view pair. FSEvents can deliver an old
/// notification after the other side has changed; a notification alone does
/// not establish which side contains a new write.
struct SharedViewSync {
    let source: URL
    let view: URL
    private let sourceEventRoot: String
    private let viewEventRoot: String
    private let ignores: [String]
    private var exchanged: [String: ChunkHash]

    init(source: URL, view: URL) throws {
        self.source = source.resolvingSymlinksInPath().standardizedFileURL
        self.view = view.resolvingSymlinksInPath().standardizedFileURL
        sourceEventRoot = try Self.physicalPath(of: source)
        viewEventRoot = try Self.physicalPath(of: view)
        ignores = try SharedView.loadIgnorePatterns(from: self.source)
        exchanged = [:]
        // The view is the snapshot just cloned. The source can already have
        // changed again before its delayed notification arrives.
        for name in try Self.files(in: self.view, ignores: ignores) {
            exchanged[name] = try ChunkHash.computeFile(self.view.appendingPathComponent(name))
        }
    }

    mutating func synchronize(changedPath: String, fromView: Bool) throws -> [String] {
        let origin = fromView ? view : source
        let destination = fromView ? source : view
        // FSEvents can spell /tmp as /private/tmp. Foundation only folds the
        // alias while the leaf exists. Match the watched directory before
        // examining its child so a removed file or subtree still reaches us.
        let changed = URL(fileURLWithPath: changedPath).standardizedFileURL.path
        let eventRoot = fromView ? viewEventRoot : sourceEventRoot
        guard let root = [origin.path, eventRoot].first(where: { changed == $0 || changed.hasPrefix($0 + "/") })
        else { return [] }
        let relative = String(changed.dropFirst(root.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        // A file event can name a child directly, without an event for its
        // ignored parent. Apply the same directory pruning as the initial view.
        var prefix = ""
        for component in relative.split(separator: "/") {
            prefix += (prefix.isEmpty ? "" : "/") + component
            if component.hasPrefix(".sharedfs-") || SharedView.isIgnored(prefix, patterns: ignores) { return [] }
        }
        var directory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: changed, isDirectory: &directory)
        let names: Set<String>
        if relative.isEmpty || directory.boolValue {
            let prefix = relative.isEmpty ? "" : relative + "/"
            names = Set(try Self.files(in: origin, ignores: ignores).filter { $0.hasPrefix(prefix) })
                .union(exchanged.keys.filter { $0.hasPrefix(prefix) })
        } else if !exists {
            names = Set(exchanged.keys.filter { $0 == relative || $0.hasPrefix(relative + "/") })
        } else {
            names = [relative]
        }
        var propagated: [String] = []
        for name in names.sorted() {
            let input = origin.appendingPathComponent(name)
            let output = destination.appendingPathComponent(name)
            guard
                input.deletingLastPathComponent().resolvingSymlinksInPath().path
                    == input.deletingLastPathComponent().path,
                output.deletingLastPathComponent().resolvingSymlinksInPath().path
                    == output.deletingLastPathComponent().path
            else { continue }
            let hash = try Self.hashIfPresent(input)
            guard hash != exchanged[name] else { continue }
            if hash == nil {
                if FileManager.default.fileExists(atPath: output.path) {
                    try FileManager.default.removeItem(at: output)
                }
                exchanged.removeValue(forKey: name)
            } else {
                let copiedHash = try Self.replace(from: input, to: output)
                exchanged[name] = copiedHash
            }
            propagated.append(name)
        }
        return propagated
    }

    private static func physicalPath(of root: URL) throws -> String {
        guard let path = realpath(root.path, nil) else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { free(path) }
        return String(cString: path)
    }

    private static func hashIfPresent(_ file: URL) throws -> ChunkHash? {
        do {
            let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true else { return nil }
            return try ChunkHash.computeFile(file)
        } catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError
        {
            return nil
        }
    }

    private static func files(in root: URL, ignores: [String]) throws -> Set<String> {
        var failure: Error?
        guard
            let enumerator = FileManager.default.enumerator(
                at: root, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
                errorHandler: { _, error in
                    failure = error
                    return false
                })
        else { throw SharedFSError.sourceUnreadable(root) }
        var names = Set<String>()
        for case let file as URL in enumerator {
            let name = relativePath(from: root, to: file)
            if file.lastPathComponent.hasPrefix(".sharedfs-") || SharedView.isIgnored(name, patterns: ignores) {
                enumerator.skipDescendants()
                continue
            }
            let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            if values.isRegularFile == true, values.isSymbolicLink != true {
                if !file.lastPathComponent.hasPrefix("."), !name.contains(".sb-") { names.insert(name) }
            }
        }
        if let failure { throw failure }
        return names
    }

    private static func replace(from input: URL, to output: URL) throws -> ChunkHash {
        try withSharedFSStaging(beside: output) { staging in
            try SharedFileOperations.native.cloneOrCopy(from: input, to: staging)
            // Record the snapshot so a delayed echo cannot overwrite a newer edit.
            let hash = try ChunkHash.computeFile(staging)
            guard rename(staging.path, output.path) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            return hash
        }
    }
}
