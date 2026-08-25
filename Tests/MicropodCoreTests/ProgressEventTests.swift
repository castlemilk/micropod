import XCTest

@testable import MicropodCore

final class ProgressEventTests: XCTestCase {
    func testParseProgressLine() {
        let event = ProgressEvent.parse(line: "[3/6] Unpacking image [12s]")
        XCTAssertEqual(event.stage, 3)
        XCTAssertEqual(event.totalStages, 6)
        XCTAssertEqual(event.stageName, "Unpacking image")
    }

    func testParsePlainLine() {
        let event = ProgressEvent.parse(line: "Exporting layers")
        XCTAssertNil(event.stage)
        XCTAssertNil(event.totalStages)
        XCTAssertEqual(event.line, "Exporting layers")
    }

    func testParseBuildStage() {
        let event = ProgressEvent.parse(line: "[2/8] Step 3/8 : RUN apk add --no-cache git")
        XCTAssertEqual(event.stage, 2)
        XCTAssertEqual(event.totalStages, 8)
        XCTAssertNotNil(event.stageName)
    }
}

final class ModelMapperTests: XCTestCase {
    func testContainerExitCode() throws {
        let json = """
            [{"configuration":{},"id":"exited-container","status":{"state":"exited","exitCode":137}}]
            """
        let entries = try MicropodJSON.decodeArray(ContainerListEntry.self, from: Data(json.utf8), context: "test")
        let mapped = ModelMapper.container(from: entries[0])
        XCTAssertEqual(mapped.state, "exited")
        XCTAssertEqual(mapped.exitCode, "137")
    }

    func testImageWithNoVariants() throws {
        let json = #"[{"configuration":{"name":"example.com/app:latest"},"id":"abc","variants":[]}]"#
        let entries = try MicropodJSON.decodeArray(ImageListEntry.self, from: Data(json.utf8), context: "test")
        let mapped = ModelMapper.image(from: entries[0])
        XCTAssertEqual(mapped.sizeBytes, 0)
        XCTAssertTrue(mapped.variants.isEmpty)
        XCTAssertEqual(mapped.names, ["example.com/app:latest"])
    }
}

final class ByteFormatTests: XCTestCase {
    func testFormatsBytes() {
        XCTAssertTrue(ByteFormat.string(Int64(0)).contains("Zero") || ByteFormat.string(Int64(0)).contains("0"))
        XCTAssertTrue(ByteFormat.string(Int64(5_816_197_120)).contains("5.82"))
        XCTAssertTrue(ByteFormat.string(Int64(1_073_741_824)).contains("1.07"))
    }
}
