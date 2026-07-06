import Foundation

/// App-managed git workdirs under Application Support (spec §4.5 / §5.5).
/// The app never modifies user-cloned repos in place, and never pushes to the
/// default branch directly.
struct RepoWorkspace {
    /// "owner/name"
    let repo: String
    let token: String

    var directory: URL {
        AppPaths.repos.appendingPathComponent(repo.replacingOccurrences(of: "/", with: "__"))
    }

    private var remoteURL: String { "https://github.com/\(repo).git" }

    /// Auth via header so the token never lands in .git/config or process
    /// lists as part of the URL.
    private var authArgs: [String] {
        let basic = Data("x-access-token:\(token)".utf8).base64EncodedString()
        return ["-c", "http.extraheader=Authorization: Basic \(basic)"]
    }

    // MARK: Git plumbing

    @discardableResult
    func git(_ arguments: [String], auth: Bool = false, cwd: URL? = nil) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = (auth ? authArgs : []) + arguments
        process.currentDirectoryURL = cwd ?? directory
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        try process.run()
        process.waitUntilExit()
        let stdout = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        guard process.terminationStatus == 0 else {
            let stderr = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw AppError.integration("git \(arguments.first ?? "") failed: \(Redactor.redact(stderr).prefix(400))")
        }
        return stdout
    }

    // MARK: Operations

    /// Clone if missing, otherwise fetch + hard-sync to the remote default branch.
    func sync(defaultBranch: String) throws {
        if FileManager.default.fileExists(atPath: directory.appendingPathComponent(".git").path) {
            try git(["fetch", "origin", defaultBranch], auth: true)
            try git(["checkout", defaultBranch])
            try git(["reset", "--hard", "origin/\(defaultBranch)"])
        } else {
            try git(["clone", "--depth", "50", remoteURL, directory.path], auth: true, cwd: AppPaths.repos)
        }
    }

    func createBranch(_ name: String, from defaultBranch: String) throws {
        try git(["checkout", "-B", name, "origin/\(defaultBranch)"])
    }

    /// Apply a unified diff produced by the LLM.
    func applyDiff(_ diff: String) throws {
        let patchURL = AppPaths.scratch.appendingPathComponent("patch-\(UUID().uuidString).diff")
        defer { try? FileManager.default.removeItem(at: patchURL) }
        var normalized = diff
        if !normalized.hasSuffix("\n") { normalized += "\n" }
        try Data(normalized.utf8).write(to: patchURL)
        try git(["apply", "--whitespace=fix", patchURL.path])
    }

    func commitAll(message: String) throws {
        try git(["add", "-A"])
        try git(["-c", "user.name=OpenAvatar", "-c", "user.email=openavatar@localhost",
                 "commit", "-m", message])
    }

    func push(branch: String) throws {
        try git(["push", "-u", "origin", branch], auth: true)
    }

    /// Revert a merge commit and push a revert branch (used by github.revert_pr).
    func revertMergeCommit(_ sha: String, defaultBranch: String, branch: String) throws {
        try sync(defaultBranch: defaultBranch)
        try createBranch(branch, from: defaultBranch)
        try git(["-c", "user.name=OpenAvatar", "-c", "user.email=openavatar@localhost",
                 "revert", "-m", "1", "--no-edit", sha])
        try push(branch: branch)
    }

    func currentDiff(against defaultBranch: String) throws -> String {
        try git(["diff", "origin/\(defaultBranch)"])
    }

    /// Optional per-repo build/test command (configured in Settings).
    func runTestCommand(_ command: String) throws -> (ok: Bool, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", command]
        process.currentDirectoryURL = directory
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()
        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return (process.terminationStatus == 0, String(output.suffix(2000)))
    }

    /// Compact repo map for planner context: top-level tree + README head.
    func repoMap(maxEntries: Int = 60) -> String {
        guard let output = try? git(["ls-files"]) else { return "" }
        let files = output.split(separator: "\n").prefix(maxEntries)
        return files.joined(separator: "\n")
    }
}
