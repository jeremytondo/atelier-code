//
//  ACPTransportPhase1Tests.swift
//  AtelierCodeTests
//
//  Created by Codex on 3/14/26.
//

import Foundation
import Testing
@testable import AtelierCode

struct ACPTransportPhase1Tests {

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
        defer {
            try? fileManager.removeItem(at: tempHomeURL)
        }

        let locator = GeminiExecutableLocator(
            userHomeDirectory: tempHomeURL.path,
            fileExists: { $0 == executableURL.path },
            whichLookup: { _ in nil }
        )

        let url = try locator.locate()

        #expect(url.path == executableURL.path)
    }

    @Test func commonInstallPathsIncludeMiseShimPath() {
        let homeDirectory = "/Users/tester"

        let paths = GeminiExecutableLocator.commonInstallPaths(userHomeDirectory: homeDirectory)

        #expect(paths.contains("\(homeDirectory)/.local/share/mise/shims/gemini"))
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

    @Test func jsonlFramingAppendsTrailingNewlineForOutgoingMessages() {
        let framedMessage = JSONLMessageFramer.frame(Data("{\"method\":\"initialize\"}".utf8))

        #expect(String(decoding: framedMessage, as: UTF8.self) == "{\"method\":\"initialize\"}\n")
    }
}
