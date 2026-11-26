import Foundation
import MicropodCore
import XCTest

@testable import MicropodRuntime

/// The kinds `sharedL0` shares across projects.
final class HVFCacheSharingTests: XCTestCase {
    func testSharedL0SharesOnlyTheStoresTheirToolsVerify() {
        XCTAssertEqual(HVFMachineCachePolicy.globalKinds, ["gomod", "npm", "pnpm"])
        XCTAssertTrue(Set(HVFMachineCachePolicy.globalKinds).isSubset(of: HVFMachineCachePolicy.toolKinds))
        for kind in ["maven", "gradle", "bun", "playwright", "yarn", "pip", "cargo"] {
            XCTAssertFalse(HVFMachineCachePolicy.globalKinds.contains(kind), kind)
        }
    }
}
