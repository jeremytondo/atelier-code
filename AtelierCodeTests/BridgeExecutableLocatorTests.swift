import Foundation
import Testing
@testable import AtelierCode

struct BridgeExecutableLocatorTests {

    @Test func resolvesEmbeddedBridgeURLFromBundle() throws {
        let appBundleURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("Fixture.app", isDirectory: true)
        let bridgeURL = appBundleURL
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("MacOS", isDirectory: true)
            .appendingPathComponent(BridgeExecutableLocator.executableName, isDirectory: false)

        try FileManager.default.createDirectory(
            at: bridgeURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        FileManager.default.createFile(atPath: bridgeURL.path, contents: Data())

        defer {
            try? FileManager.default.removeItem(at: appBundleURL.deletingLastPathComponent())
        }

        let bundle = try #require(Bundle(url: appBundleURL))
        let locator = BridgeExecutableLocator(bundle: bundle)

        #expect(try locator.embeddedBridgeURL() == bridgeURL)
    }

    @Test func surfacesStructuredErrorWhenBridgeIsMissing() throws {
        let appBundleURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("Fixture.app", isDirectory: true)

        try FileManager.default.createDirectory(at: appBundleURL, withIntermediateDirectories: true)

        defer {
            try? FileManager.default.removeItem(at: appBundleURL.deletingLastPathComponent())
        }

        let bundle = try #require(Bundle(url: appBundleURL))
        let locator = BridgeExecutableLocator(bundle: bundle)
        let expectedURL = appBundleURL
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("MacOS", isDirectory: true)
            .appendingPathComponent(BridgeExecutableLocator.executableName, isDirectory: false)

        #expect(throws: BridgeExecutableLocatorError.missingEmbeddedBridge(expectedPath: expectedURL)) {
            try locator.embeddedBridgeURL()
        }
    }
}
