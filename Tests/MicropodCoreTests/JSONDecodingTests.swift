import XCTest

@testable import MicropodCore

final class JSONDecodingTests: XCTestCase {
    func testContainerListEntryDecoding() throws {
        let json = """
            [{
              "configuration":{"capAdd":["ALL"],"capDrop":[],"creationDate":"2026-08-11T12:25:37Z","dns":{"nameservers":[],"options":[],"searchDomains":[]},"id":"buildkit","image":{"descriptor":{"digest":"sha256:b5b3f7fa81e662db6929f1ad66d835d151a1b03f682cfe5f9fcb17fa46d6bcc9","mediaType":"application/vnd.oci.image.index.v1+json","size":856},"reference":"ghcr.io/apple/container-builder-shim/builder:0.13.1"},"initProcess":{"arguments":["--debug","--vsock"],"environment":["PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin","BUILDKIT_SETUP_CGROUPV2_ROOT=1"],"executable":"/usr/local/bin/container-builder-shim","rlimits":[],"supplementalGroups":[],"terminal":false,"user":{"id":{"gid":0,"uid":0}},"workingDirectory":"/"},"labels":{"com.apple.container.plugin":"builder","com.apple.container.resource.role":"builder"},"mounts":[{"destination":"/run","options":[],"source":"","type":{"tmpfs":{}}},{"destination":"/var/lib/container-builder-shim/exports","options":[],"source":"/Users/benebsworth/Library/Application Support/com.apple.container/builder","type":{"virtiofs":{}}}],"networks":[{"network":"default","options":{"hostname":"buildkit"}}],"platform":{"architecture":"arm64","os":"linux","variant":"v8"},"publishedPorts":[],"publishedSockets":[],"readOnly":false,"resources":{"cpuOverhead":1,"cpus":2,"memoryInBytes":2147483648},"rosetta":true,"runtimeHandler":"container-runtime-linux","ssh":false,"sysctls":{},"useInit":false,"virtualization":false},"id":"buildkit","status":{"networks":[],"state":"stopped"}}]
            """
        let entries = try MicropodJSON.decodeArray(ContainerListEntry.self, from: Data(json.utf8), context: "test")
        XCTAssertEqual(entries.count, 1)
        let entry = entries[0]
        XCTAssertEqual(entry.id, "buildkit")
        XCTAssertEqual(entry.status.state, "stopped")
        XCTAssertEqual(entry.configuration.image?.reference, "ghcr.io/apple/container-builder-shim/builder:0.13.1")
        XCTAssertEqual(entry.configuration.resources?.cpus, 2)
        XCTAssertEqual(entry.configuration.mounts?.count, 2)
        XCTAssertEqual(entry.configuration.mounts?[0].typeName, "tmpfs")
        XCTAssertEqual(entry.configuration.mounts?[1].typeName, "virtiofs")

        let mapped = ModelMapper.container(from: entry)
        XCTAssertEqual(mapped.id, "buildkit")
        XCTAssertEqual(mapped.state, "stopped")
        XCTAssertEqual(mapped.image, "ghcr.io/apple/container-builder-shim/builder:0.13.1")
        XCTAssertEqual(mapped.resources.memoryBytes, 2147483648)
        XCTAssertEqual(mapped.platform, "linux/arm64")
        XCTAssertEqual(mapped.mounts.count, 2)
        XCTAssertEqual(mapped.mounts[1].type, "virtiofs")
        XCTAssertTrue(mapped.rosetta)
        XCTAssertEqual(mapped.env.count, 2)
        XCTAssertEqual(mapped.labels["com.apple.container.plugin"], "builder")
    }

    func testContainerListEntryWithRunningNetwork() throws {
        let json = """
            [{"configuration":{"creationDate":"2026-08-12T01:55:03Z","id":"api","networks":[{"network":"default","options":{}}]},"id":"api","status":{"networks":[{"hostname":"api","ipv4Address":"192.168.64.8/24","ipv4Gateway":"192.168.64.1","ipv6Address":"fd97:7f2f:97db:3103::/64","macAddress":"fe:f1:0a:a9:77:95","mtu":1280,"network":"default","variant":"reserved"}],"state":"running"}}]
            """
        let entries = try MicropodJSON.decodeArray(ContainerListEntry.self, from: Data(json.utf8), context: "test")
        let mapped = ModelMapper.container(from: entries[0])
        XCTAssertEqual(mapped.state, "running")
        XCTAssertEqual(mapped.ipv4Address, "192.168.64.8")
        XCTAssertEqual(mapped.networks, ["default"])
    }

    func testStatsEntryDecoding() throws {
        let json = """
            [{"blockReadBytes":3870720,"blockWriteBytes":0,"cpuUsageUsec":5121,"id":"micropod-stats-probe","memoryLimitBytes":1073741824,"memoryUsageBytes":4055040,"networkRxBytes":28744,"networkTxBytes":602,"numProcesses":1}]
            """
        let entries = try MicropodJSON.decodeArray(ContainerStatsEntry.self, from: Data(json.utf8), context: "test")
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].id, "micropod-stats-probe")
        XCTAssertEqual(entries[0].memoryUsageBytes, 4055040)
        XCTAssertEqual(entries[0].memoryLimitBytes, 1073741824)
        XCTAssertEqual(entries[0].numProcesses, 1)
        XCTAssertEqual(entries[0].cpuUsageUsec, 5121)
    }

    func testStatsEmptyArray() throws {
        let entries = try MicropodJSON.decodeArray(ContainerStatsEntry.self, from: Data("[]".utf8), context: "test")
        XCTAssertTrue(entries.isEmpty)
    }

    func testImageVerboseDecoding() throws {
        let json = """
            [{"configuration":{"creationDate":"2026-04-16T23:53:24Z","descriptor":{"digest":"sha256:d9e853e87e55526f6b2917df91a2115c36dd7c696a35be12163d44e6e2a4b6bc","mediaType":"application/vnd.oci.image.index.v1+json","size":9226},"name":"docker.io/library/alpine:3.20"},"id":"d9e853e87e55526f6b2917df91a2115c36dd7c696a35be12163d44e6e2a4b6bc","variants":[{"config":{"architecture":"amd64","created":"2026-04-16T23:53:26.803599608Z","os":"linux","rootfs":{"type":"layers","diffIDs":["sha256:3912c0143b10cb8a85d155266092fa0a8b17e9e389d5d1ca4de7ce9ff91e1a03"]}},"digest":"sha256:3912c0143b10cb8a85d155266092fa0a8b17e9e389d5d1ca4de7ce9ff91e1a03","platform":"linux/amd64","size":3454976}]}]
            """
        let entries = try MicropodJSON.decodeArray(ImageListEntry.self, from: Data(json.utf8), context: "test")
        XCTAssertEqual(entries.count, 1)
        let mapped = ModelMapper.image(from: entries[0])
        XCTAssertEqual(mapped.id, "d9e853e87e55526f6b2917df91a2115c36dd7c696a35be12163d44e6e2a4b6bc")
        XCTAssertEqual(mapped.names, ["docker.io/library/alpine:3.20"])
        XCTAssertEqual(mapped.sizeBytes, 3454976)
        XCTAssertEqual(mapped.variants.count, 1)
        XCTAssertEqual(mapped.variants[0].os, "linux")
        XCTAssertEqual(mapped.variants[0].architecture, "amd64")
    }

    func testSystemDFDecoding() throws {
        let json = """
            {"containers":{"active":0,"reclaimable":5816197120,"sizeInBytes":5816197120,"total":1},"images":{"active":1,"reclaimable":7455502336,"sizeInBytes":8973778944,"total":8},"volumes":{"active":0,"reclaimable":0,"sizeInBytes":0,"total":0}}
            """
        let response = try MicropodJSON.decode(DiskUsageResponse.self, from: Data(json.utf8), context: "test")
        let mapped = ModelMapper.diskUsage(from: response)
        XCTAssertEqual(mapped.containers.sizeBytes, 5816197120)
        XCTAssertEqual(mapped.totalReclaimableBytes, 5816197120 + 7455502336)
    }

    func testSystemStatusDecoding() throws {
        let json = """
            {"apiServerAppName":"container-apiserver","apiServerBuild":"release","apiServerCommit":"0190097d06df0b9065f4c2d2c7873c649d81d493","apiServerVersion":"container-apiserver version 1.2.2 (build: release, commit: 0190097)","appRoot":"/Users/benebsworth/Library/Application Support/com.apple.container/","installRoot":"/usr/local/","status":"running"}
            """
        let response = try MicropodJSON.decode(SystemStatusResponse.self, from: Data(json.utf8), context: "test")
        let mapped = ModelMapper.systemStatus(from: response, cliVersion: "1.2.2")
        XCTAssertEqual(mapped.status, "running")
        XCTAssertEqual(mapped.cliVersion, "1.2.2")
        XCTAssertEqual(mapped.apiServerVersion, "container-apiserver version 1.2.2 (build: release, commit: 0190097)")
        XCTAssertEqual(mapped.appRoot, "/Users/benebsworth/Library/Application Support/com.apple.container/")
    }

    func testVolumeListDecoding() throws {
        let json = """
            [{"configuration":{"creationDate":"2026-08-12T04:16:19Z","driver":"local","format":"ext4","labels":{},"name":"micropod-vol-probe","options":{},"sizeInBytes":549755813888,"source":"/Users/benebsworth/Library/Application Support/com.apple.container/volumes/micropod-vol-probe/volume.img"},"id":"micropod-vol-probe"}]
            """
        let entries = try MicropodJSON.decodeArray(VolumeListEntry.self, from: Data(json.utf8), context: "test")
        let mapped = ModelMapper.volume(from: entries[0])
        XCTAssertEqual(mapped.id, "micropod-vol-probe")
        XCTAssertEqual(mapped.driver, "local")
        XCTAssertEqual(mapped.format, "ext4")
        XCTAssertEqual(mapped.sizeBytes, 549755813888)
    }

    func testNetworkListDecoding() throws {
        let json = """
            [{"configuration":{"creationDate":"2026-08-12T01:55:03Z","labels":{"com.apple.container.resource.role":"builtin"},"mode":"nat","name":"default","options":{},"plugin":"container-network-vmnet"},"id":"default","status":{"ipv4Gateway":"192.168.64.1","ipv4Subnet":"192.168.64.0/24","ipv6Subnet":"fd97:7f2f:97db:3103::/64"}}]
            """
        let entries = try MicropodJSON.decodeArray(NetworkListEntry.self, from: Data(json.utf8), context: "test")
        let mapped = ModelMapper.network(from: entries[0])
        XCTAssertEqual(mapped.id, "default")
        XCTAssertEqual(mapped.ipv4Subnet, "192.168.64.0/24")
        XCTAssertTrue(mapped.builtin)
        XCTAssertEqual(mapped.plugin, "container-network-vmnet")
    }

    func testPublishedPortNestedShape() throws {
        let json =
            #"[{"configuration":{"publishedPorts":[{"port":{"hostPort":8080,"containerPort":80},"protocol":"tcp"}]},"id":"web","status":{"state":"running"}}]"#
        let entries = try MicropodJSON.decodeArray(ContainerListEntry.self, from: Data(json.utf8), context: "test")
        XCTAssertEqual(entries[0].configuration.publishedPorts?.first?.hostPort, 8080)
        XCTAssertEqual(entries[0].configuration.publishedPorts?.first?.containerPort, 80)
        XCTAssertEqual(entries[0].configuration.publishedPorts?.first?.protocolName, "tcp")
    }
}
