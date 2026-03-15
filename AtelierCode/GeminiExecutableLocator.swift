//
//  GeminiExecutableLocator.swift
//  AtelierCode
//
//  Created by Codex on 3/14/26.
//

import Foundation
import Darwin

nonisolated enum GeminiExecutableLocatorError: LocalizedError, Sendable {
    case executableNotFound(executableName: String, searchedPaths: [String])
    case whichLookupFailed(executableName: String, description: String)

    var errorDescription: String? {
        switch self {
        case .executableNotFound(let executableName, let searchedPaths):
            let joinedPaths = searchedPaths.joined(separator: ", ")
            return "Could not find the \(executableName) executable. Checked \(joinedPaths), then `/usr/bin/which \(executableName)`."
        case .whichLookupFailed(let executableName, let description):
            return "Failed to locate \(executableName) with `/usr/bin/which \(executableName)`: \(description)"
        }
    }
}

nonisolated struct GeminiExecutableLocator: Sendable {
    typealias FileExistsHandler = @Sendable (String) -> Bool
    typealias WhichLookupHandler = @Sendable (String) throws -> String?

    static var commonInstallPaths: [String] {
        commonInstallPaths(userHomeDirectory: userHomeDirectory())
    }

    static func commonInstallPaths(userHomeDirectory: String) -> [String] {
        uniquePaths(
            [
            ] + miseInstallExecutablePaths(userHomeDirectory: userHomeDirectory) + [
            "\(userHomeDirectory)/.local/share/mise/shims/gemini",
            "\(userHomeDirectory)/.local/bin/gemini",
            "\(userHomeDirectory)/bin/gemini",
            "/opt/homebrew/bin/gemini",
            "/usr/local/bin/gemini"
            ]
        )
    }

    let knownPaths: [String]

    private let fileExists: FileExistsHandler
    private let whichLookup: WhichLookupHandler

    init(
        knownPaths: [String]? = nil,
        userHomeDirectory: String = Self.userHomeDirectory(),
        fileExists: @escaping FileExistsHandler = { FileManager.default.isExecutableFile(atPath: $0) },
        whichLookup: @escaping WhichLookupHandler = Self.systemWhichLookup
    ) {
        self.knownPaths = knownPaths ?? Self.commonInstallPaths(userHomeDirectory: userHomeDirectory)
        self.fileExists = fileExists
        self.whichLookup = whichLookup
    }

    func locate(executableName: String = "gemini") throws -> URL {
        if let knownPath = knownPaths.first(where: fileExists) {
            return URL(fileURLWithPath: knownPath)
        }

        do {
            if
                let resolvedPath = try whichLookup(executableName)?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                !resolvedPath.isEmpty,
                fileExists(resolvedPath)
            {
                return URL(fileURLWithPath: resolvedPath)
            }
        } catch {
            throw GeminiExecutableLocatorError.whichLookupFailed(
                executableName: executableName,
                description: error.localizedDescription
            )
        }

        throw GeminiExecutableLocatorError.executableNotFound(
            executableName: executableName,
            searchedPaths: knownPaths
        )
    }

    private static func systemWhichLookup(executableName: String) throws -> String? {
        let process = Process()
        let standardOutputPipe = Pipe()
        let standardErrorPipe = Pipe()

        process.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        process.arguments = [executableName]
        process.standardOutput = standardOutputPipe
        process.standardError = standardErrorPipe

        try process.run()
        process.waitUntilExit()

        let standardOutput = standardOutputPipe.fileHandleForReading.readDataToEndOfFile()
        let resolvedPath = String(decoding: standardOutput, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard process.terminationStatus == 0 else {
            return nil
        }

        return resolvedPath.isEmpty ? nil : resolvedPath
    }

    private static func userHomeDirectory() -> String {
        if let homeDirectory = passwdHomeDirectory() {
            return homeDirectory
        }

        return NSHomeDirectory()
    }

    private static func passwdHomeDirectory() -> String? {
        guard let homeDirectory = getpwuid(getuid())?.pointee.pw_dir else {
            return nil
        }

        return String(cString: homeDirectory)
    }

    private static func miseInstallExecutablePaths(userHomeDirectory: String) -> [String] {
        let installsDirectoryURL = URL(fileURLWithPath: userHomeDirectory, isDirectory: true)
            .appendingPathComponent(".local/share/mise/installs/gemini", isDirectory: true)

        guard
            let versionDirectoryURLs = try? FileManager.default.contentsOfDirectory(
                at: installsDirectoryURL,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )
        else {
            return []
        }

        return versionDirectoryURLs
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
            .map { $0.appendingPathComponent("bin/gemini").path }
    }

    private static func uniquePaths(_ paths: [String]) -> [String] {
        var seenPaths = Set<String>()

        return paths.filter { seenPaths.insert($0).inserted }
    }
}
