import Foundation
import MicropodCore
import SwiftProtobuf

/// An operator-facing acceptance command. All workload calls use the existing
/// authenticated native API; no host shell, password or recovery override.
enum UpdateVerification {
    struct Workload: Codable, Sendable {
        let id: String
        let volume: String
        let expectedExit: Int32
        var before: Data?
        var after: Data?
        var artifact: String?
        var exit: Int32?
        var logBefore = false
        var logAfter = false
        var streamCompleted = false
        var maximumLogGapSeconds: Double?
        var runtimeIdentityBefore: String?
        var runtimeIdentityAfter: String?
    }
    struct Report: Codable {
        let schema: Int
        let id: UUID
        let automatic: Bool
        let startedAt: Date
        var finishedAt: Date?
        var update: UpdateContinuityReceipt?
        var workloads: [Workload]
        var passed = false
        var error: String?
    }

    static func run(_ args: [String], json: Bool) async throws -> Int32 {
        let parsed = try parseArgs(
            args, boolFlags: ["--automatic"], valueFlags: ["--image"], commandName: "update verify")
        guard parsed.positionals.isEmpty else {
            throw UsageError(message: "update verify [--automatic] [--image IMAGE]")
        }
        let client = AppControlClient()
        let status = try await client.updateStatus()
        guard status["desktopRuntimeContext"] as? String == "managed",
            status["restartGuard"] as? String == "idle",
            !UpdateContinuityStore.standard.requiresRecovery
        else {
            throw MicropodError.message(
                "Update verification needs a ready dedicated desktop and no retained update transaction")
        }
        let image = parsed.value("--image") ?? "docker.io/library/alpine:3.23.2"
        let id = UUID()
        let prefix = "mp-update-" + id.uuidString.lowercased().prefix(12)
        let automatic = parsed.has("--automatic")
        var report = Report(
            schema: 1, id: id, automatic: automatic, startedAt: Date(),
            workloads: [
                Workload(id: prefix + "-ok", volume: prefix + "-ok-data", expectedExit: 0),
                Workload(id: prefix + "-nonzero", volume: prefix + "-nonzero-data", expectedExit: 7),
            ])
        let evidenceURL = UpdateContinuityStore.standard.root.appendingPathComponent(
            "verification/" + id.uuidString + ".json")
        try RuntimeDurableFile.write(report, to: evidenceURL)
        let logs = report.workloads.map { _ in LogEvidence() }
        var streams: [Task<Void, Error>] = []
        do {
            for (index, workload) in report.workloads.enumerated() {
                var volume = Micropod_V1_CreateVolumeRequest()
                volume.name = workload.volume
                volume.size = "64m"
                let _: Micropod_V1_Empty = try await rpc("VolumeService", "CreateVolume", volume)
                var request = Micropod_V1_RunContainerRequest()
                request.image = image
                request.noPull = true
                request.name = workload.id
                request.detach = true
                request.cpus = 1
                request.memory = "256m"
                request.runtime = "apple"
                request.volumes = [workload.volume + ":/evidence"]
                request.labels = ["micropod.update-verification": id.uuidString]
                // A bounded lifetime avoids leaving an endless job if the CLI
                // itself crashes. The retained record identifies both resources.
                request.entrypoint = "/bin/sh"
                request.arguments = [
                    "-c",
                    "echo '\(id.uuidString)' > /evidence/identity; echo $$ > /evidence/pid; echo BEFORE-\(id.uuidString); n=0; while [ ! -f /evidence/finish ] && [ $n -lt 900 ]; do echo tick-$n; n=$((n+1)); sleep 1; done; test -f /evidence/finish || exit 124; echo AFTER-\(id.uuidString); cat /evidence/identity; exit \(workload.expectedExit)",
                ]
                let created: Micropod_V1_ContainerRef = try await rpc("ContainerService", "RunContainer", request)
                guard created.id == workload.id else {
                    throw MicropodError.message("Verification workload identity changed at creation")
                }
                report.workloads[index].before = try await inspect(workload.id)
                let log = logs[index]
                streams.append(
                    Task {
                        var request = Micropod_V1_StreamLogsRequest()
                        request.id = workload.id
                        for try await bytes in IsolatedRuntimeTransport.shared.stream(
                            path: "/api/micropod.v1.ContainerService/StreamContainerLogs",
                            body: try request.jsonUTF8Data())
                        {
                            try await log.consume(bytes, marker: id.uuidString)
                            if await log.completed { break }
                        }
                        try await log.finish()
                    })
            }
            for log in logs {
                for _ in 0..<100 {
                    if await log.sawBefore { break }
                    try await Task.sleep(for: .milliseconds(100))
                }
                guard await log.sawBefore else {
                    throw MicropodError.message("Verification log stream did not establish its initial marker")
                }
            }
            for index in report.workloads.indices {
                report.workloads[index].runtimeIdentityBefore = try await guestIdentity(report.workloads[index].id)
            }
            try RuntimeDurableFile.write(report, to: evidenceURL)
            if !json {
                print("Verification workloads are running; retaining their logs and volume data across the update.")
            }
            if automatic {
                _ = try await client.call("app.hide")
                _ = try await client.call(
                    "update.configure",
                    params: ["automaticInstallation": true, "automaticChecks": true, "idleSeconds": 0])
                _ = try await client.checkForUpdates()
                // Automatic policy owns the apply. Never call update.apply in
                // this branch or mistake a manual install for auto acceptance.
                for _ in 0..<600 {
                    if let receipt = try UpdateContinuityStore.standard.read(), receipt.updatedAt >= report.startedAt,
                        receipt.isTerminal
                    {
                        guard receipt.phase == .succeeded else {
                            throw MicropodError.message("Automatic update did not complete")
                        }
                        break
                    }
                    try await Task.sleep(for: .seconds(1))
                }
            } else {
                guard try await UpdateCommands.applyApp(json: true, quiet: true) == ExitCode.ok else {
                    throw MicropodError.message("The app update failed")
                }
            }
            guard let update = try UpdateContinuityStore.standard.read(), update.phase == .succeeded,
                update.updatedAt >= report.startedAt
            else { throw MicropodError.message("No verified replacement completed during this test") }
            try update.verifyServices()
            report.update = update
            for index in report.workloads.indices {
                let workload = report.workloads[index]
                report.workloads[index].after = try await inspect(workload.id)
                report.workloads[index].runtimeIdentityAfter = try await guestIdentity(workload.id)
                guard let before = report.workloads[index].before, let after = report.workloads[index].after,
                    try sameIdentity(before, after),
                    report.workloads[index].runtimeIdentityBefore == report.workloads[index].runtimeIdentityAfter
                else { throw MicropodError.message("Verification workload was replaced during the update") }
                var exec = Micropod_V1_ExecRequest()
                exec.id = workload.id
                exec.arguments = ["/bin/sh", "-c", "cat /evidence/identity; touch /evidence/finish"]
                let result: Micropod_V1_ExecResponse = try await rpc("ContainerService", "Exec", exec)
                guard result.exitCode == 0,
                    result.output.trimmingCharacters(in: .whitespacesAndNewlines) == id.uuidString
                else {
                    throw MicropodError.message("Verification volume data changed during the update")
                }
                report.workloads[index].artifact = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
                var wait = Micropod_V1_WaitContainerRequest()
                wait.id = workload.id
                wait.timeoutSeconds = 30
                let resultExit: Micropod_V1_WaitContainerResponse = try await rpc(
                    "ContainerService", "WaitContainer", wait)
                guard resultExit.exited, resultExit.known, resultExit.exitCode == workload.expectedExit else {
                    throw MicropodError.message("Verification exit result was missing or incorrect")
                }
                report.workloads[index].exit = resultExit.exitCode
            }
            for (index, task) in streams.enumerated() {
                for _ in 0..<300 {
                    if await logs[index].completed { break }
                    try await Task.sleep(for: .milliseconds(100))
                }
                guard await logs[index].completed else {
                    throw MicropodError.message(
                        "Verification log stream did not finish within 30 seconds of the workload exit")
                }
                try await task.value
                report.workloads[index].logBefore = await logs[index].sawBefore
                report.workloads[index].logAfter = await logs[index].sawAfter
                report.workloads[index].streamCompleted = await logs[index].completed
                report.workloads[index].maximumLogGapSeconds = await logs[index].maximumGap
                guard report.workloads[index].logBefore, report.workloads[index].logAfter,
                    report.workloads[index].streamCompleted
                else { throw MicropodError.message("Verification log continuity was incomplete") }
            }
            report.passed = true
            report.finishedAt = Date()
            try RuntimeDurableFile.write(report, to: evidenceURL)
            // Delete only the two stopped, identified test containers. Volumes
            // and their artifacts remain available for review.
            for workload in report.workloads {
                var request = Micropod_V1_DeleteContainerRequest()
                request.id = workload.id
                let _: Micropod_V1_Empty = try await rpc("ContainerService", "DeleteContainer", request)
            }
            if automatic { try await restoreAutomaticSettings(status, client: client) }
            if json {
                print(String(decoding: try JSONEncoder().encode(report), as: UTF8.self))
            } else {
                print(
                    "Verified both workloads, continuous logs, retained volume data and exit codes 0 and 7. Evidence: \(evidenceURL.path)"
                )
            }
            return ExitCode.ok
        } catch {
            streams.forEach { $0.cancel() }
            report.error = error.localizedDescription
            report.passed = false
            report.finishedAt = Date()
            try? RuntimeDurableFile.write(report, to: evidenceURL)
            if automatic { try? await restoreAutomaticSettings(status, client: client) }
            throw MicropodError.message(
                "\(error.localizedDescription). Test resources and evidence were retained at \(evidenceURL.path)")
        }
    }

    private static func restoreAutomaticSettings(_ status: [String: Any], client: AppControlClient) async throws {
        _ = try await client.call(
            "update.configure",
            params: [
                "automaticInstallation": status["automaticInstallation"] as? Bool ?? true,
                "automaticChecks": status["automaticChecks"] as? Bool ?? true,
                "idleSeconds": status["automaticIdleSeconds"] as? Double ?? 600,
            ])
    }

    private static func rpc<Request: Message, Response: Message>(
        _ service: String, _ method: String, _ request: Request
    ) async throws -> Response {
        let bytes = try await IsolatedRuntimeTransport.shared.request(
            path: "/api/micropod.v1.\(service)/\(method)", body: request.jsonUTF8Data())
        return try Response(jsonUTF8Data: bytes)
    }
    private static func inspect(_ id: String) async throws -> Data {
        var request = Micropod_V1_ContainerRef()
        request.id = id
        let container: Micropod_V1_Container = try await rpc("ContainerService", "GetContainer", request)
        return try container.jsonUTF8Data()
    }
    private static func guestIdentity(_ id: String) async throws -> String {
        var request = Micropod_V1_ExecRequest()
        request.id = id
        request.arguments = [
            "/bin/sh", "-c",
            "cat /proc/sys/kernel/random/boot_id; pid=$(cat /evidence/pid); echo \"$pid\"; awk '{print $22}' \"/proc/$pid/stat\"",
        ]
        let response: Micropod_V1_ExecResponse = try await rpc("ContainerService", "Exec", request)
        let value = response.output.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = value.split(separator: "\n")
        guard response.exitCode == 0, parts.count == 3, UUID(uuidString: String(parts[0])) != nil,
            let pid = Int(parts[1]), pid > 0, UInt64(parts[2]) != nil
        else {
            throw MicropodError.message("Verification could not establish the guest boot and process identity")
        }
        return value
    }

    static func sameIdentity(_ before: Data, _ after: Data) throws -> Bool {
        let left = try Micropod_V1_Container(jsonUTF8Data: before)
        let right = try Micropod_V1_Container(jsonUTF8Data: after)
        return !left.id.isEmpty && !left.createdAt.isEmpty && left.id == right.id && left.createdAt == right.createdAt
            && left.image == right.image && left.mounts == right.mounts && left.ipv4Address == right.ipv4Address
            && right.state == "running"
    }

    actor LogEvidence {
        var buffer = Data()
        var sawBefore = false
        var sawAfter = false
        var completed = false
        var lastFrameAt: TimeInterval?
        var maximumGap: TimeInterval = 0
        func consume(_ bytes: Data, marker: String) throws {
            guard !completed else { throw MicropodError.message("Unexpected log data after completion") }
            buffer.append(bytes)
            guard buffer.count <= 1024 * 1024 else { throw MicropodError.message("Oversized verification log frame") }
            while buffer.count >= 5 {
                let head = Array(buffer.prefix(5))
                let size = Int(head[1]) << 24 | Int(head[2]) << 16 | Int(head[3]) << 8 | Int(head[4])
                guard size <= 1024 * 1024 else { throw MicropodError.message("Oversized verification log frame") }
                guard buffer.count >= 5 + size else { return }
                let payload = Data(buffer.dropFirst(5).prefix(size))
                buffer.removeFirst(5 + size)
                if head[0] == 2 {
                    let end = try JSONSerialization.jsonObject(with: payload) as? [String: Any]
                    guard end?["error"] == nil else { throw MicropodError.message("Verification log stream failed") }
                    completed = true
                } else if head[0] == 0 {
                    let now = ProcessInfo.processInfo.systemUptime
                    if let lastFrameAt { maximumGap = max(maximumGap, now - lastFrameAt) }
                    lastFrameAt = now
                    let text = try Micropod_V1_LogChunk(jsonUTF8Data: payload).text
                    sawBefore = sawBefore || text.contains("BEFORE-" + marker)
                    sawAfter = sawAfter || text.contains("AFTER-" + marker)
                } else {
                    throw MicropodError.message("Unsupported verification log framing")
                }
            }
        }
        func finish() throws {
            guard buffer.isEmpty, completed else {
                throw MicropodError.message("Verification log stream ended without a completion frame")
            }
        }
    }
}
