//
//  GeminiExecutableLocator.swift
//  AtelierCode
//
//  Created by Codex on 3/14/26.
//

import Foundation

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
        let homeDirectory = NSHomeDirectory()

        return [
            "/opt/homebrew/bin/gemini",
            "/usr/local/bin/gemini",
            "\(homeDirectory)/.local/bin/gemini",
            "\(homeDirectory)/bin/gemini"
        ]
    }

    let knownPaths: [String]

    private let fileExists: FileExistsHandler
    private let whichLookup: WhichLookupHandler

    init(
        knownPaths: [String] = Self.commonInstallPaths,
        fileExists: @escaping FileExistsHandler = { FileManager.default.isExecutableFile(atPath: $0) },
        whichLookup: @escaping WhichLookupHandler = Self.systemWhichLookup
    ) {
        self.knownPaths = knownPaths
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
}
