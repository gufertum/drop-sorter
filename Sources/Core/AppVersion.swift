import Foundation

/// The version as people see it. The values come from `BuildInfo`, which build.sh generates from the
/// VERSION file and git: a release build is the commit tagged vX.Y.Z with a clean tree, every other
/// build is a dev build and carries its commit.
enum AppVersion {
    /// Semver from VERSION, e.g. "1.0.0" (MCP server info, REST health).
    static let version = BuildInfo.version
    /// "1.0.0 (61)" for a release, "1.0.0-dev+abc1234 (61)" for a dev build.
    static let display = format(version: BuildInfo.version, build: BuildInfo.build, devCommit: BuildInfo.devCommit)

    static func format(version: String, build: String, devCommit: String?) -> String {
        (devCommit.map { "\(version)-dev+\($0)" } ?? version) + (build.isEmpty ? "" : " (\(build))")
    }
}
