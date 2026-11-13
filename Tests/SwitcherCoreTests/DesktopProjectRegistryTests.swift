import Foundation
import Testing
@testable import SwitcherCore

struct DesktopProjectRegistryTests {
    private func project(_ id: String, _ roots: [String], backing: Bool = false) -> [String: Any] {
        var result: [String: Any] = ["id": id, "name": id, "rootPaths": roots, "createdAt": 1, "updatedAt": 2]
        if backing { result["chatGptBacking"] = ["accountId": "source", "projectId": "g-p-private"] }
        return result
    }

    @Test func mergesOnlyDirectoryRegistrationsKeepingTargetIDsAndAccountState() throws {
        let source: [String: Any] = ["local-projects": [
            "old": project("old", ["/example/parent/child"], backing: true),
            "parent": project("parent", ["/example/parent"]),
            "other": project("other", ["/offline/volume"]),
            "fourth": project("fourth", ["/example/fourth"])
        ], "project-order": ["old", "parent", "other", "fourth"], "project-appearances": ["old": ["color": "red", "marker": ["kind": "icon", "icon": "folder"]], "parent": ["color": "blue", "marker": ["kind": "icon", "icon": "folder", "privateMarker": "source"], "privateAppearance": "source"]]]
        let target: [String: Any] = ["local-projects": ["current": project("current", ["/example/parent/./child/"], backing: true)],
                                  "project-order": ["remote-id", "current"], "project-appearances": ["current": ["color": "green", "marker": ["kind": "icon", "icon": "folder"], "targetUnknown": true]], "thread-project-assignments": ["private": "current"]]
        let original: [String: Any] = ["unknown": ["preserve": true], "electron-account-renderer-state-v1": ["owner": NSNull(), "inactive": [
            "source": ["atoms": ["private": true], "globals": source],
            "target": ["atoms": ["target-private": true], "globals": target],
            "unrelated": ["atoms": ["untouched": true], "globals": [:]]
        ]]]
        let data = try JSONSerialization.data(withJSONObject: original)
        let updated = try #require(try DesktopProjectRegistry.merging(data, sourceOwner: "source", targetOwner: "target"))
        let result = try #require(try JSONSerialization.jsonObject(with: updated) as? [String: Any])
        let state = try #require(result["electron-account-renderer-state-v1"] as? [String: Any])
        let inactive = try #require(state["inactive"] as? [String: [String: Any]])
        let globals = try #require(inactive["target"]?["globals"] as? [String: Any])
        let projects = try #require(globals["local-projects"] as? [String: [String: Any]])
        #expect(Set(projects.keys) == ["current", "parent", "other", "fourth"])
        #expect(globals["project-order"] as? [String] == ["remote-id", "current", "parent", "other", "fourth"])
        #expect(projects["parent"]?["chatGptBacking"] == nil)
        #expect(projects["current"]?["chatGptBacking"] != nil)
        #expect(projects["current"]?["name"] as? String == "current")
        let finalAppearances = try #require(globals["project-appearances"] as? [String: [String: Any]])
        #expect(Set(finalAppearances["parent"]!.keys) == ["color", "marker"])
        #expect(Set((finalAppearances["parent"]!["marker"] as! [String: Any]).keys) == ["kind", "icon"])
        #expect(finalAppearances["current"]?["targetUnknown"] as? Bool == true)
        #expect(((globals["project-appearances"] as? [String: [String: Any]])?["current"]?["color"] as? String) == "green")
        let originalScopes = (original["electron-account-renderer-state-v1"] as! [String: Any])["inactive"] as! [String: [String: Any]]
        #expect(NSDictionary(dictionary: inactive["source"]!).isEqual(to: originalScopes["source"]!))
        #expect(globals["thread-project-assignments"] != nil)
        #expect(result["local-projects"] == nil)
    }

    @Test func sameRootProjectsRetainLocalHistoryMembershipUsingTargetProjectID() throws {
        let source: [String: Any] = [
            "local-projects": ["old": project("old", ["/work/repo"], backing: true)],
            "project-order": ["old"],
            "thread-project-assignments": [
                "history-only": ["projectKind": "local", "projectId": "old"],
                "already-placed": ["projectKind": "local", "projectId": "old"],
                "explicitly-projectless": ["projectKind": "local", "projectId": "old"],
                "cloud": ["projectKind": "local", "projectId": "old", "projectOrigin": "chatgpt"],
                "remote-host": ["projectKind": "local", "projectId": "old"],
                "missing-host": ["projectKind": "local", "projectId": "old"]
            ],
            "thread-project-membership-host-ids": ["history-only": "local", "already-placed": "local", "explicitly-projectless": "local", "cloud": "local", "remote-host": "ssh:remote"],
            "sidebar-project-thread-orders": ["old": ["threadIds": ["history-only", "cloud"], "source-private": "do-not-copy"]]
        ]
        let target: [String: Any] = [
            "local-projects": ["new": project("new", ["/work/./repo/"], backing: true)],
            "project-order": ["new"],
            "thread-project-assignments": ["history-only": ["projectKind": "local", "projectId": "old"], "already-placed": ["projectKind": "remote", "projectId": "target-remote", "hostId": "ssh:target"]],
            "thread-project-membership-host-ids": ["already-placed": "ssh:target"],
            "projectless-thread-ids": ["explicitly-projectless"],
            "sidebar-project-thread-orders": ["new": ["threadIds": ["target-existing"], "target-unknown": true]]
        ]
        let original: [String: Any] = [DesktopProjectRegistry.scopeKey: ["owner": "source", "inactive": ["target": ["globals": target, "atoms": ["cloud-session": "target-private"]]]], "local-projects": source["local-projects"]!, "project-order": source["project-order"]!, "thread-project-assignments": source["thread-project-assignments"]!, "thread-project-membership-host-ids": source["thread-project-membership-host-ids"]!, "sidebar-project-thread-orders": source["sidebar-project-thread-orders"]!]
        // Installed Desktop's project filter explicitly excludes an assignment
        // for a different project ID, even when the cwd matches the roots.
        func included(_ assignments: [String: [String: String]]) -> Bool {
            guard let assignment = assignments["history-only"] else { return true }
            return assignment["projectKind"] == "local" && assignment["projectId"] == "new"
        }
        #expect(!included(target["thread-project-assignments"] as! [String: [String: String]]))
        let bytes = try JSONSerialization.data(withJSONObject: original)
        let updated = try #require(try DesktopProjectRegistry.merging(bytes, sourceOwner: "source", targetOwner: "target"))
        let result = try #require(try JSONSerialization.jsonObject(with: updated) as? [String: Any])
        let scope = result[DesktopProjectRegistry.scopeKey] as! [String: Any]
        let inactive = scope["inactive"] as! [String: [String: Any]]
        let globals = inactive["target"]!["globals"] as! [String: Any]
        let assignments = globals["thread-project-assignments"] as! [String: [String: String]]
        // The exact same local thread visible in history now resolves under the
        // destination's existing project, even though source and target IDs differ.
        #expect(assignments["history-only"] == ["projectKind": "local", "projectId": "new"])
        #expect(included(assignments))
        #expect(assignments["already-placed"] == ["projectKind": "remote", "projectId": "target-remote", "hostId": "ssh:target"])
        #expect(assignments["explicitly-projectless"] == nil)
        #expect(assignments["cloud"] == nil)
        #expect(assignments["remote-host"] == nil)
        #expect(assignments["missing-host"] == nil)
        #expect(globals["projectless-thread-ids"] as? [String] == ["explicitly-projectless"])
        let finalOrder = (globals["sidebar-project-thread-orders"] as! [String: [String: Any]])["new"]!
        #expect(finalOrder["threadIds"] as? [String] == ["target-existing", "history-only"])
        #expect(finalOrder["target-unknown"] as? Bool == true)
        #expect(finalOrder["source-private"] == nil)
        #expect((globals["thread-project-membership-host-ids"] as? [String: String])?["history-only"] == "local")
        #expect((inactive["target"]?["atoms"] as? [String: String]) == ["cloud-session": "target-private"])
        #expect(NSDictionary(dictionary: result["thread-project-assignments"] as! [String: Any]).isEqual(to: source["thread-project-assignments"] as! [String: Any]))
        #expect(try DesktopProjectRegistry.merging(updated, sourceOwner: "source", targetOwner: "target") == nil)
    }

    @Test func sharedContentOwnerSchemaAlreadyPreservesMembershipWithoutRewritingAccountAtoms() throws {
        // Current Desktop 26.1106 stores these fields globally, and only private
        // preferences/atoms carry an owner suffix. Switching must preserve bytes.
        let object: [String: Any] = [
            "electron-renderer-content-owner": "source",
            "local-projects": ["shared": project("shared", ["/work/repo"])],
            "project-order": ["shared"],
            "thread-project-assignments": ["history": ["projectKind": "local", "projectId": "shared"]],
            "thread-project-membership-host-ids": ["history": "local"],
            "projectless-thread-ids": [],
            "electron-owner-atoms:source": ["cloud-session": "private"],
            "electron-owner-atoms:target": ["target-session": "private"],
            "electron-owner-value:app-server-projects-migration-by-host:target": ["local:/home": ["version": 1, "threadAssignmentsMigrated": false, "pendingThreadAssignmentIds": ["history"]]]
        ]
        let bytes = try JSONSerialization.data(withJSONObject: object)
        #expect(try DesktopProjectRegistry.merging(bytes, sourceOwner: "source", targetOwner: "target") == nil)
    }

    @Test func sharedOwnerMarkerLeavesFutureVersionsUnderDesktopOwnership() throws {
        let bytes = Data(#"{"electron-renderer-content-owner":"source","electron-account-renderer-state-v2":{}}"#.utf8)
        #expect(try DesktopProjectRegistry.merging(bytes, sourceOwner: "source", targetOwner: "target") == nil)
    }

    @Test func parkedLocalMembershipsAreImportedWhenTargetHasNoAssignments() throws {
        let source: [String: Any] = ["local-projects": ["p": project("p", ["/work/repo"])], "thread-project-assignments": ["thread": ["projectKind": "local", "projectId": "p"]]]
        let object: [String: Any] = [DesktopProjectRegistry.scopeKey: ["owner": NSNull(), "inactive": ["source": ["globals": source, "atoms": ["session": "private"]]]]]
        let bytes = try JSONSerialization.data(withJSONObject: object)
        let updated = try #require(try DesktopProjectRegistry.merging(bytes, sourceOwner: "source", targetOwner: "target"))
        let result = try JSONSerialization.jsonObject(with: updated) as! [String: Any]
        let scope = result[DesktopProjectRegistry.scopeKey] as! [String: Any]
        let target = (scope["inactive"] as! [String: [String: Any]])["target"]!
        let globals = target["globals"] as! [String: Any]
        #expect((globals["thread-project-assignments"] as? [String: [String: String]])?["thread"] == ["projectKind": "local", "projectId": "p"])
        #expect((target["atoms"] as? [String: String])?.isEmpty == true)
    }

    @Test func malformedLegacySchemaFailsInsteadOfDiscardingState() throws {
        let data = Data(#"{"electron-account-renderer-state-v1":{"owner":null,"inactive":{"source":{"atoms":{},"globals":{"local-projects":[]}}}}}"#.utf8)
        #expect(throws: DesktopProjectRegistryError.self) {
            try DesktopProjectRegistry.merging(data, sourceOwner: "source", targetOwner: "target")
        }
    }
}

private func syntheticCredential(_ account: String, user: String = "user", actualUser: String? = nil) throws -> Data {
    var auth: [String: String] = ["chatgpt_account_id": account, "chatgpt_user_id": user]
    if let actualUser { auth["user_id"] = actualUser }
    let claims = try JSONSerialization.data(withJSONObject: ["https://api.openai.com/auth": auth]).base64EncodedString()
    return try JSONSerialization.data(withJSONObject: ["tokens": ["account_id": account, "access_token": "header.\(claims).signature"]])
}

struct DesktopProjectStoreTests {
    @Test func sharedStateSwitchesWithAccountIdentityButNoRendererOwnerClaims() async throws {
        let fixture = try await ProjectStoreFixture(rendererClaims: false)
        defer { fixture.clean() }
        let state = Data(#"{ "electron-renderer-content-owner": "source", "local-projects": {}, "thread-project-assignments": {} }"#.utf8)
        try state.write(to: fixture.state)
        let desktop = RecordingProjectDesktop()
        let service = SwitchService(desktop: desktop, store: fixture.store, codex: CredentialIdentity())
        try await service.switchAccount(to: fixture.target.id)
        #expect(try Data(contentsOf: fixture.state) == state)
        #expect(try CredentialIdentity.decode(Data(contentsOf: fixture.auth))?.accountID == "target")
        #expect(try await fixture.store.loadRegistry().activeAccountID == fixture.target.id)
        #expect(await desktop.events == ["close", "reopen"])
    }

    @Test(arguments: [
        #"{"electron-renderer-content-owner":null,"electron-account-renderer-state-v1":"leftover","local-projects":"desktop-owned"}"#,
        #"{"electron-account-renderer-state-v2":{},"local-projects":[]}"#,
        "{incomplete-json",
        "[]"
    ])
    func nonLegacyStateDoesNotParticipateInCredentialRollback(_ stateJSON: String) async throws {
        let fixture = try await ProjectStoreFixture(rendererClaims: false)
        defer { fixture.clean() }
        let state = Data(stateJSON.utf8)
        try state.write(to: fixture.state)
        let auth = try Data(contentsOf: fixture.auth)
        try await fixture.store.saveCurrentCredential()
        try await fixture.store.activateTargetCredential(id: fixture.target.id)
        #expect(try Data(contentsOf: fixture.state) == state)
        #expect(try CredentialIdentity.decode(Data(contentsOf: fixture.auth))?.accountID == "target")
        // A subsequent Desktop write must not be mistaken for a migration that
        // the switcher should roll back. Only auth belongs to this handoff.
        let concurrent = Data(#"{"desktop-changed":true}"#.utf8)
        try concurrent.write(to: fixture.state)
        try await fixture.store.restoreActiveCredential(id: fixture.original.id)
        #expect(try Data(contentsOf: fixture.auth) == auth)
        #expect(try Data(contentsOf: fixture.state) == concurrent)
    }

    @Test func activationAndIdentityFailureRestoreExactStateAndCredential() async throws {
        let fixture = try await ProjectStoreFixture()
        defer { fixture.clean() }
        let state = try Data(contentsOf: fixture.state)
        let auth = try Data(contentsOf: fixture.auth)
        try await fixture.store.saveCurrentCredential()
        try await fixture.store.activateTargetCredential(id: fixture.target.id)
        #expect(try Data(contentsOf: fixture.state) != state)
        try await fixture.store.restoreActiveCredential(id: fixture.original.id)
        #expect(try Data(contentsOf: fixture.state) == state)
        #expect(try Data(contentsOf: fixture.auth) == auth)
        #expect(try FileManager.default.attributesOfItem(atPath: fixture.state.path)[.posixPermissions] as? Int == 0o600)
    }

    @Test func unsupportedStateLeavesCredentialAndStateUntouched() async throws {
        let fixture = try await ProjectStoreFixture()
        defer { fixture.clean() }
        let invalid = Data(#"{"electron-account-renderer-state-v1":"future-version"}"#.utf8)
        try invalid.write(to: fixture.state)
        let auth = try Data(contentsOf: fixture.auth)
        await #expect(throws: DesktopProjectRegistryError.self) {
            try await fixture.store.activateTargetCredential(id: fixture.target.id)
        }
        #expect(try Data(contentsOf: fixture.auth) == auth)
        #expect(try Data(contentsOf: fixture.state) == invalid)
    }

    @Test func malformedMembershipOrderStopsBeforeChangingCredentials() async throws {
        let fixture = try await ProjectStoreFixture()
        defer { fixture.clean() }
        var object = try JSONSerialization.jsonObject(with: Data(contentsOf: fixture.state)) as! [String: Any]
        var scope = object[DesktopProjectRegistry.scopeKey] as! [String: Any]
        var inactive = scope["inactive"] as! [String: [String: Any]]
        let owner = inactive.keys.first!
        var snapshot = inactive[owner]!
        var globals = snapshot["globals"] as! [String: Any]
        globals["sidebar-project-thread-orders"] = ["project": ["threadIds": "unsupported-schema"]]
        snapshot["globals"] = globals
        inactive[owner] = snapshot
        scope["inactive"] = inactive
        object[DesktopProjectRegistry.scopeKey] = scope
        let state = try JSONSerialization.data(withJSONObject: object)
        try state.write(to: fixture.state)
        let auth = try Data(contentsOf: fixture.auth)
        await #expect(throws: DesktopProjectRegistryError.self) {
            try await fixture.store.activateTargetCredential(id: fixture.target.id)
        }
        #expect(try Data(contentsOf: fixture.auth) == auth)
        #expect(try Data(contentsOf: fixture.state) == state)
    }

    @Test func concurrentStateIsNotOverwrittenButCredentialStillRestores() async throws {
        let fixture = try await ProjectStoreFixture()
        defer { fixture.clean() }
        let auth = try Data(contentsOf: fixture.auth)
        try await fixture.store.saveCurrentCredential()
        try await fixture.store.activateTargetCredential(id: fixture.target.id)
        let concurrent = Data("{\"newer-desktop-state\":true}".utf8)
        try concurrent.write(to: fixture.state)
        await #expect(throws: DesktopProjectRegistryError.self) {
            try await fixture.store.restoreActiveCredential(id: fixture.original.id)
        }
        #expect(try Data(contentsOf: fixture.auth) == auth)
        #expect(try Data(contentsOf: fixture.state) == concurrent)
    }

    @Test func refusedDesktopExitDoesNotWriteStateOrCredentials() async throws {
        let fixture = try await ProjectStoreFixture()
        defer { fixture.clean() }
        let auth = try Data(contentsOf: fixture.auth)
        let state = try Data(contentsOf: fixture.state)
        let service = SwitchService(desktop: RefusingProjectDesktop(), store: fixture.store, codex: CredentialIdentity())
        await #expect(throws: OperationError.self) { try await service.switchAccount(to: fixture.target.id) }
        #expect(try Data(contentsOf: fixture.auth) == auth)
        #expect(try Data(contentsOf: fixture.state) == state)
    }

    @Test func missingStateDoesNotBlockNewInstall() async throws {
        let fixture = try await ProjectStoreFixture(rendererClaims: false)
        defer { fixture.clean() }
        try FileManager.default.removeItem(at: fixture.state)
        try await fixture.store.activateTargetCredential(id: fixture.target.id)
        #expect(!FileManager.default.fileExists(atPath: fixture.state.path))
    }

    @Test func symlinkStateIsSkippedWithoutChangingItsDestination() async throws {
        let fixture = try await ProjectStoreFixture(rendererClaims: false)
        defer { fixture.clean() }
        let real = fixture.state.appendingPathExtension("real")
        try FileManager.default.moveItem(at: fixture.state, to: real)
        try FileManager.default.createSymbolicLink(at: fixture.state, withDestinationURL: real)
        let original = try Data(contentsOf: real)
        try await fixture.store.activateTargetCredential(id: fixture.target.id)
        #expect(try Data(contentsOf: real) == original)
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: fixture.state.path) == real.path)
        #expect(try CredentialIdentity.decode(Data(contentsOf: fixture.auth))?.accountID == "target")
    }

    @Test func ownerUsesAuthenticatedUserClaimAndNeverSubject() throws {
        let first = try CredentialIdentity.rendererOwner(from: syntheticCredential("account", user: "legacy", actualUser: "authenticated"))
        let second = try CredentialIdentity.rendererOwner(from: syntheticCredential("account", user: "authenticated"))
        #expect(first == second)
        #expect(first.count == 64)
        #expect(throws: CodexClientError.identityUnavailable) {
            try CredentialIdentity.rendererOwner(from: Data(#"{"tokens":{"account_id":"account","id_token":"header.private.signature"}}"#.utf8))
        }
    }
}

private struct ProjectStoreFixture {
    let directory: URL
    let store: AccountStore
    let original: AccountProfile
    let target: AccountProfile
    var auth: URL { directory.appending(path: "home/auth.json") }
    var state: URL { directory.appending(path: "home/.codex-global-state.json") }

    init(rendererClaims: Bool = true) async throws {
        directory = FileManager.default.temporaryDirectory.appending(path: "project-store-\(UUID())")
        try FileManager.default.createDirectory(at: directory.appending(path: "home"), withIntermediateDirectories: true)
        store = AccountStore(baseURL: directory.appending(path: "store"), activeHomeURL: directory.appending(path: "home"), sharedDesktopMode: true)
        original = AccountProfile(id: UUID(), displayName: "Source", email: nil, accountID: "source", createdAt: Date())
        target = AccountProfile(id: UUID(), displayName: "Target", email: nil, accountID: "target", createdAt: Date())
        let current = rendererClaims ? try syntheticCredential("source") : Data(#"{"tokens":{"account_id":"source","access_token":"opaque-source"}}"#.utf8)
        let next = rendererClaims ? try syntheticCredential("target") : Data(#"{"tokens":{"account_id":"target","access_token":"opaque-target"}}"#.utf8)
        try current.write(to: auth)
        try await store.importCurrentProfile(original)
        let targetHome = try await store.createProfileDirectory(id: target.id)
        try next.write(to: targetHome.appending(path: "auth.json"))
        try await store.addProfile(target)
        let owner = try CredentialIdentity.rendererOwner(from: syntheticCredential("source"))
        let stateObject: [String: Any] = ["electron-account-renderer-state-v1": ["owner": NSNull(), "inactive": [owner: ["atoms": ["private": true], "globals": ["local-projects": ["project": ["id": "project", "name": "Example", "rootPaths": ["/example/offline"], "createdAt": 1, "updatedAt": 2]], "project-order": ["project"], "thread-project-assignments": ["existing-local-thread": ["projectKind": "local", "projectId": "project"]], "thread-project-membership-host-ids": ["existing-local-thread": "local"], "sidebar-project-thread-orders": ["project": ["threadIds": ["existing-local-thread"]]]]]]]]
        try JSONSerialization.data(withJSONObject: stateObject).write(to: state)
    }
    func clean() { try? FileManager.default.removeItem(at: directory) }
}

private struct RefusingProjectDesktop: DesktopControlling {
    func closeDesktop() async throws { throw DesktopProjectRegistryError.changedState }
    func reopenDesktop() async throws { Issue.record("Must not reopen after refused quit") }
}

private actor RecordingProjectDesktop: DesktopControlling {
    var events: [String] = []
    func closeDesktop() async throws { events.append("close") }
    func reopenDesktop() async throws { events.append("reopen") }
}
