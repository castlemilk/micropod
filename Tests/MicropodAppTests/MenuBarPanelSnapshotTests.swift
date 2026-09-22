import AppKit
import MicropodCore
import SwiftUI
import XCTest

@testable import MicropodApp

/// Temporary visual-verification helper: renders the menu bar panel into a
/// PNG at /tmp/menubar-panel.png so layout changes can be eyeballed without
/// clicking the menu bar item. Not a regression test — delete or keep as a
/// manual aid.
final class MenuBarPanelSnapshotTests: XCTestCase {
    @MainActor
    func testRenderPanelToPNG() throws {
        let fixture = try AppTestCLI.makeMock()
        defer { AppTestCLI.cleanUp(fixture) }
        let store = makeRunningStore(client: fixture.client)

        var web = Micropod_V1_Container()
        web.id = "web-frontend"
        web.image = "docker.io/library/nginx:latest"
        web.state = "running"
        var db = Micropod_V1_Container()
        db.id = "postgres-main"
        db.image = "docker.io/library/postgres:17-alpine"
        db.state = "running"
        var worker = Micropod_V1_Container()
        worker.id = "job-runner-3f2a"
        worker.image = "ghcr.io/skunkworq/runner:dev"
        worker.state = "exited"
        store.containers = [web, db, worker]

        var snap = Micropod_V1_StatsSnapshot()
        var s1 = Micropod_V1_ContainerStats()
        s1.id = "web-frontend"
        s1.cpuPercent = 12.4
        s1.memoryUsedBytes = 268_435_456
        var s2 = Micropod_V1_ContainerStats()
        s2.id = "postgres-main"
        s2.cpuPercent = 3.1
        s2.memoryUsedBytes = 134_217_728
        snap.containers = [s1, s2]
        store.statsSnapshot = snap

        store.recordActivity("runtime", "Runtime started", level: .success)
        store.recordActivity("containers", "Started web-frontend", level: .info)
        store.recordActivity("images", "Pull failed for ghcr.io/private/img", level: .error)

        let hosting = NSHostingView(
            rootView: MenuBarPanelView(store: store)
                .environment(\.colorScheme, .dark))
        hosting.frame = NSRect(x: 0, y: 0, width: 340, height: 640)
        // Text layers only rasterize when the view lives in a real window.
        let window = NSWindow(
            contentRect: hosting.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false)
        window.contentView = hosting
        window.orderBack(nil)
        hosting.layoutSubtreeIfNeeded()
        let fitting = hosting.fittingSize
        hosting.frame = NSRect(origin: .zero, size: fitting)
        window.setContentSize(fitting)
        hosting.display()

        guard
            let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds)
        else {
            XCTFail("no bitmap rep")
            return
        }
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        guard
            let png = rep.representation(
                using: NSBitmapImageRep.FileType.png, properties: [:])
        else {
            XCTFail("no png")
            return
        }
        try png.write(to: URL(fileURLWithPath: "/tmp/menubar-panel.png"))
    }

    /// Same trick for the main-window dashboard — rasterizes the card layout
    /// so the GroupBox → PanelCard uplift can be eyeballed.
    @MainActor
    func testRenderDashboardToPNG() throws {
        let fixture = try AppTestCLI.makeMock()
        defer { AppTestCLI.cleanUp(fixture) }
        let store = makeRunningStore(client: fixture.client)

        var web = Micropod_V1_Container()
        web.id = "web-frontend"
        web.image = "docker.io/library/nginx:latest"
        web.state = "running"
        web.createdAt = "2026-09-20T10:00:00Z"
        var db = Micropod_V1_Container()
        db.id = "postgres-main"
        db.image = "docker.io/library/postgres:17-alpine"
        db.state = "running"
        db.createdAt = "2026-09-19T08:30:00Z"
        var worker = Micropod_V1_Container()
        worker.id = "job-runner-3f2a"
        worker.image = "ghcr.io/skunkworq/runner:dev"
        worker.state = "exited"
        store.containers = [web, db, worker]

        var usage = Micropod_V1_DiskUsage()
        var cat = Micropod_V1_DiskCategory()
        cat.sizeBytes = 8_589_934_592
        cat.reclaimableBytes = 2_147_483_648
        usage.containers = cat
        usage.images = cat
        usage.volumes = cat
        usage.totalReclaimableBytes = 6_442_450_944
        store.diskUsage = usage

        store.recordActivity("runtime", "Runtime started", level: .success)
        store.recordActivity("containers", "Started web-frontend", level: .info)
        store.recordActivity("images", "Pull failed for ghcr.io/private/img", level: .error)

        let hosting = NSHostingView(
            rootView: DashboardView(store: store)
                .environment(\.colorScheme, .dark)
                .environment(\.locale, Locale(identifier: "en")))
        hosting.frame = NSRect(x: 0, y: 0, width: 860, height: 720)
        let window = NSWindow(
            contentRect: hosting.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false)
        window.contentView = hosting
        window.orderBack(nil)
        hosting.layoutSubtreeIfNeeded()
        hosting.display()

        guard
            let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds)
        else {
            XCTFail("no bitmap rep")
            return
        }
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        guard
            let png = rep.representation(
                using: NSBitmapImageRep.FileType.png, properties: [:])
        else {
            XCTFail("no png")
            return
        }
        try png.write(to: URL(fileURLWithPath: "/tmp/dashboard.png"))
    }
}
