import Darwin
import Foundation

/// Content last exchanged by a source/view pair. FSEvents can deliver an old
/// notification after the other side has changed; a notification alone does
/// not establish which side contains a new write.
struct SharedViewSync {
    let source: URL
    let view: URL
    private var exchanged = ExchangedFiles()

    init(source: URL, view: URL) throws {
        self.source = source.resolvingSymlinksInPath().standardizedFileURL
        self.view = view.resolvingSymlinksInPath().standardizedFileURL
        // The view is the snapshot just cloned. The source can already have
        // changed again before its delayed notification arrives.
        for name in try Self.files(in: self.view) {
            exchanged[name] = try ChunkHash.computeFile(self.view.appendingPathComponent(name))
        }
    }

    mutating func synchronize(changedPath: String, fromView: Bool) throws -> [String] {
        let origin = fromView ? view : source
        let destination = fromView ? source : view
        let changed = URL(fileURLWithPath: changedPath).resolvingSymlinksInPath().standardizedFileURL.path
        guard changed == origin.path || changed.hasPrefix(origin.path + "/") else { return [] }
        let relative = String(changed.dropFirst(origin.path.count)).trimmingCharacters(
            in: CharacterSet(charactersIn: "/"))
        guard !relative.split(separator: "/").contains(where: { $0.hasPrefix(".sharedfs-") }) else { return [] }
        var directory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: changed, isDirectory: &directory)
        let names: Set<String>
        if relative.isEmpty || directory.boolValue {
            names = try Self.files(in: origin, below: URL(fileURLWithPath: changed, isDirectory: true))
                .union(exchanged.paths(below: relative))
        } else if !exists {
            names = exchanged.paths(below: relative, includingFile: true)
        } else {
            names = [relative]
        }
        var propagated: [String] = []
        for name in names.sorted() {
            let input = origin.appendingPathComponent(name)
            let output = destination.appendingPathComponent(name)
            let hash = try Self.hashIfPresent(input)
            guard hash != exchanged[name] else { continue }
            if hash == nil {
                if FileManager.default.fileExists(atPath: output.path) {
                    try FileManager.default.removeItem(at: output)
                }
                exchanged[name] = nil
            } else {
                let copiedHash = try Self.replace(from: input, to: output)
                exchanged[name] = copiedHash
            }
            propagated.append(name)
        }
        return propagated
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

    private static func files(in root: URL, below directory: URL? = nil) throws -> Set<String> {
        let subtree = directory ?? root
        var failure: Error?
        guard
            let enumerator = FileManager.default.enumerator(
                at: subtree, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
                errorHandler: { _, error in
                    failure = error
                    return false
                })
        else { throw SharedFSError.sourceUnreadable(subtree) }
        var names = Set<String>()
        for case let file as URL in enumerator {
            let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            if values.isRegularFile == true, values.isSymbolicLink != true {
                let name = relativePath(from: root, to: file)
                if !file.lastPathComponent.hasPrefix("."), !name.contains(".sb-") { names.insert(name) }
            }
        }
        if let failure { throw failure }
        return names
    }

    private static func replace(from input: URL, to output: URL) throws -> ChunkHash {
        let parent = output.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let staging = parent.appendingPathComponent(".sharedfs-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: staging) }
        if clonefile(input.path, staging.path, 0) != 0 {
            try FileManager.default.copyItem(at: input, to: staging)
        }
        // Hash the actual snapshot, so its echo cannot overwrite a newer
        // source write that happens while the snapshot is being copied.
        let hash = try ChunkHash.computeFile(staging)
        guard rename(staging.path, output.path) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        return hash
    }
}

/// FSEvents can report a directory after its files are already gone. Keep the paths
/// that were last exchanged so deletion discovery only visits that directory's subtree.
private struct ExchangedFiles {
    private var hashes: [String: ChunkHash] = [:]
    private var children: [String: Set<String>] = [:]

    subscript(path: String) -> ChunkHash? {
        get { hashes[path] }
        set {
            var child = path
            if let newValue {
                guard hashes.updateValue(newValue, forKey: path) == nil else { return }
                while !child.isEmpty {
                    let parent = Self.parent(of: child)
                    guard children[parent, default: []].insert(child).inserted else { return }
                    child = parent
                }
            } else {
                hashes.removeValue(forKey: path)
                while !child.isEmpty && children[child] == nil && hashes[child] == nil {
                    let parent = Self.parent(of: child)
                    children[parent]?.remove(child)
                    if children[parent]?.isEmpty == true { children[parent] = nil }
                    child = parent
                }
            }
        }
    }

    func paths(below directory: String, includingFile: Bool = false) -> Set<String> {
        if directory.isEmpty { return Set(hashes.keys) }
        var paths: Set<String> = includingFile && hashes[directory] != nil ? [directory] : []
        var pending = Array(children[directory] ?? [])
        while let path = pending.popLast() {
            if hashes[path] != nil { paths.insert(path) }
            if let nested = children[path] { pending.append(contentsOf: nested) }
        }
        return paths
    }

    private static func parent(of path: String) -> String {
        guard let slash = path.lastIndex(of: "/") else { return "" }
        return String(path[..<slash])
    }
}
