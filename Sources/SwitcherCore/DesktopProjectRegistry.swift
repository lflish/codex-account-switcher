import Foundation

/// Preserve local project registrations and explicit local thread membership.
/// Remote memberships, renderer atoms and ChatGPT backing remain account scoped.
enum DesktopProjectRegistryError: LocalizedError {
    case unsupportedState
    case changedState
    var errorDescription: String? {
        switch self {
        case .unsupportedState: "Codex project settings could not be safely preserved. The account has not changed."
        case .changedState: "Codex project settings changed during the switch. Close Codex Desktop and try again."
        }
    }
}

enum DesktopProjectRegistry {
    static let scopeKey = "electron-account-renderer-state-v1"
    static let fields = ["id", "name", "rootPaths", "createdAt", "updatedAt"]

    // Only the explicit legacy snapshot format needs cross-account migration.
    // New/shared, unknown and unreadable JSON stay under Desktop's ownership.
    // A new content-owner marker wins over a leftover legacy snapshot key.
    static func needsMigration(_ bytes: Data) -> Bool {
        guard let root = (try? JSONSerialization.jsonObject(with: bytes)) as? [String: Any] else { return false }
        return root.keys.contains(scopeKey) && !root.keys.contains("electron-renderer-content-owner")
    }

    static func merging(_ bytes: Data, sourceOwner: String, targetOwner: String) throws -> Data? {
        guard needsMigration(bytes), sourceOwner != targetOwner else { return nil }
        guard var root = try JSONSerialization.jsonObject(with: bytes) as? [String: Any] else {
            throw DesktopProjectRegistryError.unsupportedState
        }
        guard !root.keys.contains(where: { $0.hasPrefix("electron-account-renderer-state-") && $0 != scopeKey }) else {
            throw DesktopProjectRegistryError.unsupportedState
        }
        guard var scope = root[scopeKey] as? [String: Any],
              let owner = scope["owner"], owner is NSNull || owner is String,
              var inactive = scope["inactive"] as? [String: Any] else {
            throw DesktopProjectRegistryError.unsupportedState
        }
        func snapshot(_ key: String) throws -> [String: Any]? {
            guard let value = inactive[key] else { return nil }
            guard let value = value as? [String: Any], value["atoms"] is [String: Any],
                  value["globals"] is [String: Any] else { throw DesktopProjectRegistryError.unsupportedState }
            return value
        }
        // On exit Desktop may already have parked the current owner's globals.
        let source: [String: Any]
        if owner as? String == sourceOwner { source = root }
        else if let value = try snapshot(sourceOwner)?["globals"] as? [String: Any] { source = value }
        else { throw DesktopProjectRegistryError.unsupportedState }
        let sourceProjects = try projects(source)
        guard !sourceProjects.isEmpty else { return nil }
        var targetSnapshot = try snapshot(targetOwner) ?? ["atoms": [String: Any](), "globals": [String: Any]()]
        var target = owner as? String == targetOwner ? root : targetSnapshot["globals"] as! [String: Any]
        var targetProjects = try projects(target)
        var order = try strings(target["project-order"])
        let sourceOrder = try strings(source["project-order"])
        var appearances = try dictionary(target["project-appearances"])
        let sourceAppearances = try dictionary(source["project-appearances"])
        let sourceIDs = sourceOrder.filter { sourceProjects[$0] != nil } + sourceProjects.keys.sorted().filter { !sourceOrder.contains($0) }
        var changed = false
        var projectIDs: [String: String] = [:]
        for id in sourceIDs {
            guard let project = sourceProjects[id], let roots = project["rootPaths"] as? [String] else { continue }
            // Exact root sets only: nested directories remain independent projects.
            let matches = targetProjects.keys.filter { normalizedRoots(targetProjects[$0]?["rootPaths"] as? [String] ?? []) == normalizedRoots(roots) }
            guard matches.count <= 1 else { throw DesktopProjectRegistryError.unsupportedState }
            if let existing = matches.first { projectIDs[id] = existing; continue }
            // A reused ID with different roots cannot safely be reassigned.
            guard targetProjects[id] == nil else { throw DesktopProjectRegistryError.unsupportedState }
            targetProjects[id] = project.filter { fields.contains($0.key) }
            projectIDs[id] = id
            if !order.contains(id) { order.append(id) }
            if appearances[id] == nil, let value = sourceAppearances[id] { appearances[id] = try localAppearance(value) }
            changed = true
        }
        if try mergeMemberships(source: source, target: &target, projectIDs: projectIDs) { changed = true }
        guard changed else { return nil }
        target["local-projects"] = targetProjects
        target["project-order"] = order
        target["project-appearances"] = appearances
        if owner as? String == targetOwner {
            root = target
        } else {
            targetSnapshot["globals"] = target
            inactive[targetOwner] = targetSnapshot
            scope["inactive"] = inactive
            root[scopeKey] = scope
        }
        return try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
    }

    private static func mergeMemberships(source: [String: Any], target: inout [String: Any], projectIDs: [String: String]) throws -> Bool {
        let sourceAssignments = try dictionary(source["thread-project-assignments"])
        var assignments = try dictionary(target["thread-project-assignments"])
        let sourceHosts = try dictionary(source["thread-project-membership-host-ids"])
        var hosts = try dictionary(target["thread-project-membership-host-ids"])
        let projectless = Set(try strings(target["projectless-thread-ids"]))
        var imported = Set<String>()
        for thread in sourceAssignments.keys.sorted() {
            guard let assignment = sourceAssignments[thread] as? [String: Any],
                  let kind = assignment["projectKind"] as? String,
                  ["local", "remote"].contains(kind),
                  let projectID = assignment["projectId"] as? String, !projectID.isEmpty else {
                throw DesktopProjectRegistryError.unsupportedState
            }
            guard !projectless.contains(thread), kind == "local", assignment["projectOrigin"] == nil,
                  let destination = projectIDs[projectID] else { continue }
            if let existing = assignments[thread] {
                // A previous directory-only merge can leave a local membership
                // pointing at the source ID although the target kept another ID.
                // Repair only this proved dangling alias; real target placements win.
                guard let existing = existing as? [String: Any],
                      existing["projectKind"] as? String == "local",
                      existing["projectOrigin"] == nil,
                      existing["projectId"] as? String == projectID,
                      destination != projectID,
                      (target["local-projects"] as? [String: Any])?[projectID] == nil else { continue }
            }
            if source["thread-project-membership-host-ids"] != nil, sourceHosts[thread] as? String != "local" { continue }
            if let host = hosts[thread], host as? String != "local" { continue }
            assignments[thread] = ["projectKind": "local", "projectId": destination]
            hosts[thread] = "local"
            imported.insert(thread)
        }
        guard !imported.isEmpty else { return false }
        let sourceOrders = try dictionary(source["sidebar-project-thread-orders"])
        var orders = try dictionary(target["sidebar-project-thread-orders"])
        for sourceID in sourceOrders.keys.sorted() {
            let sourceEntry = try dictionary(sourceOrders[sourceID])
            guard let sourceOrder = sourceEntry["threadIds"] as? [String] else { throw DesktopProjectRegistryError.unsupportedState }
            guard let destination = projectIDs[sourceID] else { continue }
            var targetEntry = try dictionary(orders[destination])
            if orders[destination] != nil, !(targetEntry["threadIds"] is [String]) { throw DesktopProjectRegistryError.unsupportedState }
            var order = try strings(targetEntry["threadIds"])
            for thread in sourceOrder where imported.contains(thread) && !order.contains(thread) {
                guard (assignments[thread] as? [String: String])?["projectId"] == destination else { continue }
                order.append(thread)
            }
            if !order.isEmpty {
                targetEntry["threadIds"] = order
                orders[destination] = targetEntry
            }
        }
        target["thread-project-assignments"] = assignments
        target["thread-project-membership-host-ids"] = hosts
        target["sidebar-project-thread-orders"] = orders
        return true
    }

    private static func normalizedRoots(_ paths: [String]) -> Set<String> {
        Set(paths.map { URL(fileURLWithPath: $0).standardizedFileURL.path })
    }
    private static func localAppearance(_ value: Any) throws -> [String: Any] {
        guard let appearance = value as? [String: Any], let color = appearance["color"] as? String,
              let marker = appearance["marker"] as? [String: Any], let kind = marker["kind"] as? String,
              ["icon", "emoji"].contains(kind), let symbol = marker[kind] as? String, !symbol.isEmpty else {
            throw DesktopProjectRegistryError.unsupportedState
        }
        return ["color": color, "marker": ["kind": kind, kind: symbol]]
    }

    private static func dictionary(_ value: Any?) throws -> [String: Any] {
        guard let value else { return [:] }
        guard let result = value as? [String: Any] else { throw DesktopProjectRegistryError.unsupportedState }
        return result
    }
    private static func strings(_ value: Any?) throws -> [String] {
        guard let value else { return [] }
        guard let result = value as? [String] else { throw DesktopProjectRegistryError.unsupportedState }
        return result
    }
    private static func projects(_ globals: [String: Any]) throws -> [String: [String: Any]] {
        let values = try dictionary(globals["local-projects"])
        var result: [String: [String: Any]] = [:]
        for (id, value) in values {
            guard let project = value as? [String: Any], project["id"] as? String == id,
                  project["name"] is String, let roots = project["rootPaths"] as? [String],
                  !roots.isEmpty, roots.allSatisfy({ !$0.isEmpty }),
                  project["createdAt"] is NSNumber, project["updatedAt"] is NSNumber else {
                throw DesktopProjectRegistryError.unsupportedState
            }
            result[id] = project
        }
        return result
    }
}
