import Darwin
import Foundation
import XCTest

@testable import MicropodRuntimeHostKit

final class RootRuntimeStorageTests: XCTestCase {
    func testPublishesDirectoryCreatedUnderRestrictiveUmask() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        XCTAssertEqual(mkdir(directory.path, 0o700), 0)
        try RootRuntimeStorage.publishReadableDirectory(directory, ownerUID: getuid())
        var info = stat()
        XCTAssertEqual(lstat(directory.path, &info), 0)
        XCTAssertEqual(info.st_mode & 0o777, 0o755)
    }

    func testRefusesSymlinkForeignOwnerAndWritableDirectory() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let link = directory.appendingPathExtension("link")
        defer {
            try? FileManager.default.removeItem(at: link)
            try? FileManager.default.removeItem(at: directory)
        }
        XCTAssertEqual(mkdir(directory.path, 0o700), 0)
        XCTAssertEqual(symlink(directory.path, link.path), 0)
        XCTAssertThrowsError(try RootRuntimeStorage.publishReadableDirectory(link, ownerUID: getuid()))
        XCTAssertThrowsError(try RootRuntimeStorage.publishReadableDirectory(directory, ownerUID: getuid() + 1))
        XCTAssertEqual(chmod(directory.path, 0o777), 0)
        XCTAssertThrowsError(try RootRuntimeStorage.publishReadableDirectory(directory, ownerUID: getuid()))
    }
}
