import Foundation

/// Params of the workspace methods that address one workspace:
/// `workspace.focus` and `workspace.close` both take the schema's
/// `WorkspaceTarget`.
struct WorkspaceTargetParams: Encodable, Sendable {
    let workspaceID: WorkspaceID

    enum CodingKeys: String, CodingKey {
        case workspaceID = "workspace_id"
    }

    init(_ workspaceID: WorkspaceID) {
        self.workspaceID = workspaceID
    }
}

/// Params of `workspace.create`.
///
/// `cwd` and `env` exist in the schema but Paddock never sets them: a space
/// created from the column inherits herdr's own default working directory,
/// which is what the TUI does too. `label` is optional — herdr then numbers
/// the space itself.
struct WorkspaceCreateParams: Encodable, Sendable {
    let label: String?
    let focus: Bool

    enum CodingKeys: String, CodingKey {
        case label
        case focus
    }

    init(label: String?, focus: Bool) {
        self.label = label
        self.focus = focus
    }
}

/// Params of `workspace.rename`.
struct WorkspaceRenameParams: Encodable, Sendable {
    let workspaceID: WorkspaceID
    let label: String

    enum CodingKeys: String, CodingKey {
        case workspaceID = "workspace_id"
        case label
    }

    init(workspaceID: WorkspaceID, label: String) {
        self.workspaceID = workspaceID
        self.label = label
    }
}

/// The result of a method whose payload nothing reads.
///
/// Every one of herdr's 57 result shapes is an object tagged with a `type`
/// (`ok`, `workspace_info`, `workspace_created`, …). Decoding just the tag
/// keeps a mutation from failing because herdr enriched a reply Paddock
/// ignores: the column follows the events the mutation causes, never its
/// response. Even the tag is optional, so that a method whose result shape
/// changes can never make a mutation that actually worked look like a failure.
struct HerdrResultTag: Decodable, Sendable {
    let type: String?
}
