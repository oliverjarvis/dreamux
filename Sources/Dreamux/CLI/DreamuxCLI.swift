import Foundation

/// Headless command-line control of Dreamux, dispatched from `DreamuxMain`
/// before any GUI is created. It creates projects — folders under the
/// projects root — and their first repo using the app's own
/// `GitOperations` bare+worktree layout, so the running (or next-launched)
/// app discovers them through its normal folder scan (`ProjectStore.refresh`).
/// No AppKit, no main actor: the work is plain FileManager + git.
enum DreamuxCLI {
    /// argv[1] values that mean "run the CLI, don't open the GUI".
    static let commandNames: Set<String> = ["add", "clone", "list", "help", "--help", "-h"]

    private struct CLIError: Error { let message: String; init(_ m: String) { self.message = m } }

    /// Runs the CLI for `args` (process arguments minus the executable) and
    /// returns a process exit code.
    static func run(_ args: [String]) -> Int32 {
        guard let command = args.first else { printUsage(); return 2 }
        let rest = Array(args.dropFirst())
        do {
            switch command {
            case "list": try listProjects()
            case "clone": try blocking { try await clone(rest) }
            case "add": try blocking { try await add(rest) }
            case "help", "--help", "-h": printUsage()
            default:
                errln("unknown command '\(command)'")
                printUsage()
                return 2
            }
            return 0
        } catch let error as CLIError {
            errln(error.message)
            return 1
        } catch {
            errln(error.localizedDescription)
            return 1
        }
    }

    // MARK: - Commands

    /// `clone <url> [--name NAME]` — clone a git URL into a new project.
    private static func clone(_ args: [String]) async throws {
        let (positional, name) = parse(args)
        guard let url = positional.first else {
            throw CLIError("clone requires a <url>.  Usage: dreamux clone <url> [--name NAME]")
        }
        let repoName = GitOperations.deriveName(from: url)
        let projectName = name ?? repoName
        let projectDir = try createProjectFolder(named: projectName)
        do {
            _ = try await GitOperations.cloneBare(url: url, into: projectDir, name: repoName)
        } catch {
            try? FileManager.default.removeItem(at: projectDir)   // no half-made project
            throw error
        }
        reportCreated(project: projectName, repo: repoName, at: projectDir)
    }

    /// `add <dir> [--name NAME]` — add a local directory as a new project.
    /// The directory is left in place; its history is cloned into the
    /// project's repo. A non-repo directory is `git init`'d first (Dreamux
    /// projects are git-backed).
    private static func add(_ args: [String]) async throws {
        let (positional, name) = parse(args)
        guard let raw = positional.first else {
            throw CLIError("add requires a <dir>.  Usage: dreamux add <dir> [--name NAME]")
        }
        let dir = URL(fileURLWithPath: (raw as NSString).expandingTildeInPath).standardizedFileURL
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue else {
            throw CLIError("no such directory: \(dir.path)")
        }
        if !isGitRepo(dir) {
            try runGit(["init", "--quiet"], in: dir)
            print("Initialized a git repository in \(dir.path)")
        }
        // cloneBare lays a worktree on the default branch, which needs at
        // least one commit to point at — seed one from the current contents
        // when the repo has no history yet.
        if !hasCommit(dir) {
            try runGit(["add", "-A"], in: dir)
            try runGit(["commit", "--quiet", "--allow-empty", "-m", "Initial commit"], in: dir)
        }
        let repoName = GitOperations.slug(from: dir.lastPathComponent)
        let projectName = name ?? dir.lastPathComponent
        let projectDir = try createProjectFolder(named: projectName)
        do {
            _ = try await GitOperations.cloneBare(url: dir.path, into: projectDir, name: repoName)
        } catch {
            try? FileManager.default.removeItem(at: projectDir)
            throw error
        }
        reportCreated(project: projectName, repo: repoName, at: projectDir)
    }

    /// `list` — the project folders under the projects root.
    private static func listProjects() throws {
        let root = ProjectStore.projectsRootURL()
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? []
        let names = entries.compactMap { url -> String? in
            ((try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true)
                ? url.lastPathComponent : nil
        }.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        if names.isEmpty {
            print("No projects under \(root.path)")
        } else {
            print("Projects under \(root.path):")
            for name in names { print("  \(name)") }
        }
    }

    // MARK: - Helpers

    private static func createProjectFolder(named name: String) throws -> URL {
        let safe = name.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        guard !safe.isEmpty else { throw CLIError("invalid project name") }
        let dir = ProjectStore.projectsRootURL().appendingPathComponent(safe, isDirectory: true)
        guard !FileManager.default.fileExists(atPath: dir.path) else {
            throw CLIError("a project named '\(safe)' already exists at \(dir.path)")
        }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func isGitRepo(_ dir: URL) -> Bool {
        (try? runGit(["rev-parse", "--is-inside-work-tree"], in: dir)) != nil
    }

    private static func hasCommit(_ dir: URL) -> Bool {
        (try? runGit(["rev-parse", "--verify", "--quiet", "HEAD"], in: dir)) != nil
    }

    @discardableResult
    private static func runGit(_ args: [String], in dir: URL) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git"] + args
        process.currentDirectoryURL = dir
        let out = Pipe()
        process.standardOutput = out
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw CLIError("git \(args.joined(separator: " ")) failed (exit \(process.terminationStatus))")
        }
        return String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    }

    /// Split positional args from a `--name`/`-n` (or `--name=`) option.
    private static func parse(_ args: [String]) -> (positional: [String], name: String?) {
        var positional: [String] = []
        var name: String?
        var i = 0
        while i < args.count {
            let arg = args[i]
            if arg == "--name" || arg == "-n" {
                i += 1
                if i < args.count { name = args[i] }
            } else if arg.hasPrefix("--name=") {
                name = String(arg.dropFirst("--name=".count))
            } else {
                positional.append(arg)
            }
            i += 1
        }
        return (positional, name)
    }

    private static func reportCreated(project: String, repo: String, at dir: URL) {
        print("Created project '\(project)' (repo '\(repo)') at \(dir.path)")
        print("Open Dreamux — a new or relaunched window will discover it.")
    }

    /// Run an async throwing body to completion synchronously. Safe to call
    /// on the main thread: the work is nonisolated (git via `GitOperations`,
    /// which runs on the concurrency pool), so blocking here can't deadlock.
    /// Written once by the task, read once after `wait()` returns — the
    /// semaphore is the happens-before edge, so the box is safe.
    private final class Outcome: @unchecked Sendable { var error: Error? }

    private static func blocking(_ body: @escaping @Sendable () async throws -> Void) throws {
        let semaphore = DispatchSemaphore(value: 0)
        let outcome = Outcome()
        Task.detached {
            do { try await body() } catch { outcome.error = error }
            semaphore.signal()
        }
        semaphore.wait()
        if let error = outcome.error { throw error }
    }

    private static func errln(_ message: String) {
        FileHandle.standardError.write(Data("dreamux: \(message)\n".utf8))
    }

    private static func printUsage() {
        print("""
        dreamux — programmatic control of the Dreamux app

        USAGE:
          dreamux clone <url> [--name NAME]   Clone a git URL into a new project
          dreamux add <dir> [--name NAME]     Add a local directory as a new project
          dreamux list                        List existing projects
          dreamux help                        Show this help

        Projects are created as folders under the Dreamux projects root
        (~/Documents/Dreamux, or $DREAMUX_PROJECTS_ROOT). A running app picks
        up a new project the next time one of its windows (re)opens.
        """)
    }
}
