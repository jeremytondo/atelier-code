//
//  ACPTransportTests.swift
//  AtelierCodeTests
//
//  Created by Codex on 3/14/26.
//

import Foundation
import Testing
@testable import AtelierCode

struct ACPTransportTests {
    private func canonicalPath(_ path: String) -> String {
        let fileManager = FileManager.default
        var existingURL = URL(fileURLWithPath: path).standardizedFileURL
        var missingPathComponents: [String] = []

        while
            existingURL.path != "/",
            !fileManager.fileExists(atPath: existingURL.path)
        {
            missingPathComponents.insert(existingURL.lastPathComponent, at: 0)
            existingURL.deleteLastPathComponent()
        }

        return missingPathComponents
            .reduce(existingURL.resolvingSymlinksInPath()) { partialURL, component in
                partialURL.appendingPathComponent(component)
            }
            .path
    }

    @Test func executableLocatorResolvesKnownInstallPaths() throws {
        let locator = GeminiExecutableLocator(
            knownPaths: ["/known/gemini", "/fallback/gemini"],
            fileExists: { $0 == "/known/gemini" },
            whichLookup: { _ in "/resolved/from/which" }
        )

        let url = try locator.locate()

        #expect(url.path == "/known/gemini")
    }

    @Test func executableLocatorFallsBackToWhich() throws {
        let locator = GeminiExecutableLocator(
            knownPaths: ["/known/gemini"],
            fileExists: { $0 == "/resolved/from/which" },
            whichLookup: { executableName in
                #expect(executableName == "gemini")
                return "/resolved/from/which"
            }
        )

        let url = try locator.locate()

        #expect(url.path == "/resolved/from/which")
    }

    @Test func executableLocatorDiscoversMiseInstallUnderUserHome() throws {
        let fileManager = FileManager.default
        let tempHomeURL = fileManager.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let executableURL = tempHomeURL
            .appendingPathComponent(".local/share/mise/installs/gemini/0.33.1/bin/gemini")

        try fileManager.createDirectory(
            at: executableURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("#!/bin/sh\n".utf8).write(to: executableURL)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executableURL.path)
        let canonicalTempHomePath = canonicalPath(tempHomeURL.path)
        let canonicalExecutablePath = canonicalPath(executableURL.path)
        defer {
            try? fileManager.removeItem(at: tempHomeURL)
        }

        let locator = GeminiExecutableLocator(
            userHomeDirectory: canonicalTempHomePath,
            fileExists: { canonicalPath($0) == canonicalExecutablePath },
            whichLookup: { _ in nil }
        )

        let url = try locator.locate()

        #expect(canonicalPath(url.path) == canonicalExecutablePath)
    }

    @Test func commonInstallPathsIncludeMiseShimPath() {
        let homeDirectory = "/Users/tester"

        let paths = GeminiExecutableLocator.commonInstallPaths(userHomeDirectory: homeDirectory)

        #expect(paths.contains("\(homeDirectory)/.local/share/mise/shims/gemini"))
    }

    @Test func commonInstallPathsPreferMiseInstallBeforeHomebrew() throws {
        let fileManager = FileManager.default
        let tempHomeURL = fileManager.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let executableURL = tempHomeURL
            .appendingPathComponent(".local/share/mise/installs/gemini/0.33.1/bin/gemini")

        try? fileManager.createDirectory(
            at: executableURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let canonicalTempHomePath = canonicalPath(tempHomeURL.path)
        let canonicalExecutablePath = canonicalPath(executableURL.path)
        defer {
            try? fileManager.removeItem(at: tempHomeURL)
        }

        let paths = GeminiExecutableLocator.commonInstallPaths(userHomeDirectory: canonicalTempHomePath)
        let normalizedPaths = paths.map(canonicalPath)
        let miseInstallIndex = try #require(normalizedPaths.firstIndex(of: canonicalExecutablePath))
        let homebrewIndex = try #require(paths.firstIndex(of: "/opt/homebrew/bin/gemini"))

        #expect(miseInstallIndex < homebrewIndex)
    }

    @Test func missingExecutableReturnsClearError() {
        let locator = GeminiExecutableLocator(
            knownPaths: ["/known/gemini", "/fallback/gemini"],
            fileExists: { _ in false },
            whichLookup: { _ in nil }
        )

        do {
            _ = try locator.locate()
            #expect(Bool(false))
        } catch let error as GeminiExecutableLocatorError {
            let description = error.errorDescription ?? ""
            #expect(description.contains("/known/gemini"))
            #expect(description.contains("/usr/bin/which gemini"))
        } catch {
            #expect(Bool(false))
        }
    }

    @Test func jsonlFramingHandlesCompleteReads() {
        var framer = JSONLMessageFramer()

        let messages = framer.ingest(Data("{\"jsonrpc\":\"2.0\"}\n".utf8))

        #expect(messages == [Data("{\"jsonrpc\":\"2.0\"}".utf8)])
    }

    @Test func jsonlFramingHandlesPartialReads() {
        var framer = JSONLMessageFramer()

        let firstMessages = framer.ingest(Data("{\"jsonrpc\":".utf8))
        let secondMessages = framer.ingest(Data("\"2.0\"}\n".utf8))

        #expect(firstMessages.isEmpty)
        #expect(secondMessages == [Data("{\"jsonrpc\":\"2.0\"}".utf8)])
    }

    @Test func jsonlFramingHandlesMultipleMessagesPerRead() {
        var framer = JSONLMessageFramer()

        let messages = framer.ingest(
            Data("{\"id\":1}\n{\"id\":2}\n".utf8)
        )

        #expect(messages.count == 2)
        #expect(messages[0] == Data("{\"id\":1}".utf8))
        #expect(messages[1] == Data("{\"id\":2}".utf8))
    }

    @Test func jsonlFramingHandlesCRLFAndFlushesRemainingBufferedData() {
        var framer = JSONLMessageFramer()

        let firstMessages = framer.ingest(Data("{\"id\":1}\r\n{\"id\":2}".utf8))
        let remainingMessages = framer.finish()

        #expect(firstMessages == [Data("{\"id\":1}".utf8)])
        #expect(remainingMessages == [Data("{\"id\":2}".utf8)])
    }

    @Test func jsonlFramingAppendsTrailingNewlineForOutgoingMessages() {
        let framedMessage = JSONLMessageFramer.frame(Data("{\"method\":\"initialize\"}".utf8))

        #expect(String(decoding: framedMessage, as: UTF8.self) == "{\"method\":\"initialize\"}\n")
    }

    @Test func processEnvironmentAddsExecutableDirectoryAndFallbackPATHEntries() {
        let environment = GeminiProcessEnvironment.make(
            currentEnvironment: ["PATH": "/usr/bin:/bin"],
            userHomeDirectory: "/Users/tester",
            executableDirectory: "/opt/homebrew/bin",
            interactiveShellPATH: ""
        )

        #expect(
            environment["PATH"] ==
            "/opt/homebrew/bin:/usr/bin:/bin:/Users/tester/.local/share/mise/shims:/Users/tester/.local/bin:/Users/tester/bin:/usr/local/bin:/usr/sbin:/sbin"
        )
        #expect(environment["HOME"] == "/Users/tester")
    }

    @Test func processEnvironmentPrefersInteractiveShellPATHEntries() {
        let environment = GeminiProcessEnvironment.make(
            currentEnvironment: ["PATH": "/usr/bin:/bin"],
            userHomeDirectory: "/Users/tester",
            executableDirectory: "/Users/tester/.local/share/mise/installs/gemini/latest/bin",
            interactiveShellPATH: "/usr/local/go/bin:/opt/homebrew/sbin:/usr/bin:/Users/tester/.local/share/go"
        )

        #expect(
            environment["PATH"] ==
            "/Users/tester/.local/share/mise/installs/gemini/latest/bin:/usr/local/go/bin:/opt/homebrew/sbin:/usr/bin:/Users/tester/.local/share/go:/bin:/Users/tester/.local/share/mise/shims:/Users/tester/.local/bin:/Users/tester/bin:/opt/homebrew/bin:/usr/local/bin:/usr/sbin:/sbin"
        )
    }

    @Test func processEnvironmentSetsNoBrowser() {
        let environment = GeminiProcessEnvironment.make(
            currentEnvironment: [:],
            userHomeDirectory: "/Users/tester",
            executableDirectory: nil,
            interactiveShellPATH: ""
        )

        #expect(environment["NO_BROWSER"] == "1")
    }

    @Test func processEnvironmentPreservesExistingHomeValue() {
        let environment = GeminiProcessEnvironment.make(
            currentEnvironment: ["HOME": "/custom/home"],
            userHomeDirectory: "/Users/tester",
            executableDirectory: nil,
            interactiveShellPATH: ""
        )

        #expect(environment["HOME"] == "/custom/home")
    }
}
