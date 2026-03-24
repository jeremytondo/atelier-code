import Foundation

enum BridgeExecutableLocatorError: Error, Equatable {
    case missingEmbeddedBridge(expectedPath: URL)
}

struct BridgeExecutableLocator {
    static let executableName = "ateliercode-agent-bridge"

    let bundle: Bundle

    init(bundle: Bundle = .main) {
        self.bundle = bundle
    }

    func embeddedBridgeURL() throws -> URL {
        let bridgeURL = bundle.bundleURL
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("MacOS", isDirectory: true)
            .appendingPathComponent(Self.executableName, isDirectory: false)

        guard FileManager.default.fileExists(atPath: bridgeURL.path) else {
            throw BridgeExecutableLocatorError.missingEmbeddedBridge(expectedPath: bridgeURL)
        }

        return bridgeURL
    }
}
