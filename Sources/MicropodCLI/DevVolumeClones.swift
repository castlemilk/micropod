import CryptoKit
import Darwin
import Foundation

enum DevVolumeClones {
    // Darwin returns a length and attribute_set_t followed by the requested attributes.
    static func family(_ path: String) -> UInt64? {
        var request = attrlist()
        request.bitmapcount = UInt16(ATTR_BIT_MAP_COUNT)
        request.commonattr = UInt32(ATTR_CMN_RETURNED_ATTRS)
        request.forkattr = UInt32(ATTR_CMNEXT_CLONEID | ATTR_CMNEXT_CLONE_REFCNT)
        var result = [UInt8](repeating: 0, count: 64)
        return result.withUnsafeMutableBytes { data -> UInt64? in
            guard getattrlist(path, &request, data.baseAddress, data.count, UInt32(FSOPT_ATTR_CMN_EXTENDED)) == 0,
                data.loadUnaligned(as: UInt32.self) >= 36,
                data.loadUnaligned(fromByteOffset: 20, as: UInt32.self) & request.forkattr == request.forkattr,
                data.loadUnaligned(fromByteOffset: 32, as: UInt32.self) > 1
            else { return nil }
            return data.loadUnaligned(fromByteOffset: 24, as: UInt64.self)
        }
    }

    struct Key: Hashable {
        let device: dev_t
        let family: UInt64
        let digest: Data
    }

    static func key(_ path: String, device: dev_t) throws -> Key? {
        guard let family = family(path) else { return nil }
        // A clone family may contain several independently edited versions.
        // Index each content variant once instead of comparing every pair.
        let file = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
        defer { try? file.close() }
        var hash = SHA256()
        while let chunk = try file.read(upToCount: 1 << 20), !chunk.isEmpty { hash.update(data: chunk) }
        return Key(device: device, family: family, digest: Data(hash.finalize()))
    }

    // Only replace a private staged file. Clone families can diverge on write.
    // Verify the cloned bytes and the staged file's own metadata before renaming.
    static func share(_ anchor: String, with staged: String) throws {
        var from = stat(), to = stat()
        guard lstat(anchor, &from) == 0, lstat(staged, &to) == 0,
            from.st_dev == to.st_dev, from.st_ino != to.st_ino, to.st_nlink == 1,
            from.st_mode & S_IFMT == S_IFREG, to.st_mode & S_IFMT == S_IFREG,
            from.st_size == to.st_size, from.st_flags == 0, to.st_flags == 0
        else { return }
        if let existing = family(staged), existing == family(anchor) { return }
        let parent = (staged as NSString).deletingLastPathComponent
        let temp = parent + "/.micropod-clone-" + UUID().uuidString
        var directory = stat()
        guard lstat(parent, &directory) == 0,
            clonefile(anchor, temp, UInt32(CLONE_NOFOLLOW)) == 0
        else { return }  // A destination filesystem without cloning keeps the verified copy.
        defer {
            _ = unlink(temp)
            _ = utimensat(AT_FDCWD, parent, [directory.st_atimespec, directory.st_mtimespec], AT_SYMLINK_NOFOLLOW)
        }
        guard FileManager.default.contentsEqual(atPath: staged, andPath: temp),
            copyfile(staged, temp, nil, copyfile_flags_t(COPYFILE_METADATA | COPYFILE_NOFOLLOW)) == 0,
            utimensat(AT_FDCWD, temp, [to.st_atimespec, to.st_mtimespec], AT_SYMLINK_NOFOLLOW) == 0
        else { return }
        var info = stat()
        guard lstat(temp, &info) == 0, info.st_mode == to.st_mode, info.st_uid == to.st_uid,
            info.st_gid == to.st_gid, info.st_flags == to.st_flags,
            try DevVolumeMigration.xattrs(temp) == DevVolumeMigration.xattrs(staged),
            try DevVolumeMigration.accessList(temp) == DevVolumeMigration.accessList(staged)
        else { return }
        guard rename(temp, staged) == 0 else {
            throw DevVolumeError("Cannot publish cloned file \\(staged): \\(String(cString: strerror(errno)))")
        }
    }
}
