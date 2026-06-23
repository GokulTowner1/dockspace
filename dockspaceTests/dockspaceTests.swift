//
//  dockspaceTests.swift
//  dockspaceTests
//
//  Created by gokul on 10/06/26.
//

import Testing
import Foundation
@testable import dockspace

struct dockspaceTests {

    @Test func searchDoesNotMatchDocumentsPathSegment() async throws {
        let engine = SearchEngine()
        let workspaces = [
            Workspace(name: "dockspace", path: "/Users/dev/Documents/swiftui/dockspace", projectType: .swift),
            Workspace(name: "distributor", path: "/Users/dev/Documents/Towner/distributor"),
            Workspace(name: "ranger", path: "/Users/dev/Documents/Synamic/ranger", projectType: .flutter),
        ]

        let results = engine.search(query: "di", in: workspaces)
        let names = Set(results.map(\.name))
        #expect(names.contains("distributor"))
        #expect(!names.contains("dockspace"))
        #expect(!names.contains("ranger"))
    }

    @Test func searchMatchesWorkspaceNameAndPath() async throws {
        let engine = SearchEngine()
        let workspaces = [
            Workspace(name: "Dockspace", path: "/Users/dev/dockspace", projectType: .swift),
            Workspace(name: "Marketing Site", path: "/Users/dev/sites/marketing", projectType: .react),
            Workspace(name: "API Server", path: "/Users/dev/api-server", projectType: .nodejs),
        ]

        let byName = engine.search(query: "dock", in: workspaces)
        #expect(byName.first?.name == "Dockspace")

        let byPath = engine.search(query: "marketing", in: workspaces)
        #expect(byPath.first?.name == "Marketing Site")

        let multi = engine.search(query: "api node", in: workspaces)
        #expect(multi.first?.name == "API Server")
    }

    @Test func recentListFollowsEditorHistoryOrder() async throws {
        let workspaces = [
            Workspace(name: "Old Scan", path: "/tmp/old", editorRecencyRank: 40),
            Workspace(name: "Editor Recent", path: "/tmp/editor", editorRecencyRank: 2),
            Workspace(
                name: "dockspace",
                path: "/tmp/dockspace",
                lastOpened: Date().addingTimeInterval(-3600),
                editorRecencyRank: 0,
                launchCount: 3
            ),
            Workspace(
                name: "ranger",
                path: "/tmp/ranger",
                lastOpened: Date(),
                editorRecencyRank: 5,
                launchCount: 1
            ),
        ]

        let recent = WorkspaceRecency.recentSection(from: workspaces)
        #expect(recent.first?.name == "dockspace")
        #expect(recent.contains(where: { $0.name == "Editor Recent" }))
        #expect(!recent.contains(where: { $0.name == "Old Scan" }))
    }

    @Test func sanitizeCachedClearsSyntheticLastOpened() async throws {
        let polluted = Workspace(
            name: "Never Opened",
            path: "/tmp/never",
            lastOpened: Date(),
            launchCount: 0
        )
        let clean = WorkspaceRecency.sanitizeCached(polluted)
        #expect(clean.lastOpened == nil)
    }

    @Test @MainActor func automationStepDecodesTypedConfiguration() async throws {
        let step = AutomationStep(
            type: .runTerminalCommand,
            title: "Run dev server",
            configuration: TerminalCommandConfiguration(
                command: "npm run dev",
                workingDirectory: "/tmp/project"
            ),
            waitCondition: .processStarts("node")
        )

        let config = try #require(step.decodedConfiguration(TerminalCommandConfiguration.self))
        #expect(config.command == "npm run dev")
        #expect(config.workingDirectory == "/tmp/project")
        #expect(step.waitCondition?.processName == "node")
    }

    @Test @MainActor func starterAutomationOpensWorkspaceInPreferredEditor() async throws {
        let workspace = Workspace(
            name: "Dockspace",
            path: "/tmp/dockspace",
            appType: .cursor,
            projectType: .swift
        )

        let automation = WorkspaceAutomation.starter(for: workspace)
        #expect(automation.workspacePath == workspace.path)
        #expect(automation.enabledStepCount == 1)

        let step = try #require(automation.steps.first)
        let config = try #require(step.decodedConfiguration(OpenWorkspaceConfiguration.self))
        #expect(step.type == .openWorkspace)
        #expect(config.path == workspace.path)
        #expect(config.appType == .cursor)
    }

    @Test @MainActor func waitConditionBuildsHumanReadableStatus() async throws {
        let condition = WaitCondition.windowAppears(
            appName: "Cursor",
            titleContains: "Dockspace",
            timeout: 12
        )

        #expect(condition.type == .windowAppears)
        #expect(condition.timeout == 12)
        #expect(condition.displayTitle == "Wait for Cursor window")
    }
}
