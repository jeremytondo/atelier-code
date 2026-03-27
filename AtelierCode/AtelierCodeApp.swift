//
//  AtelierCodeApp.swift
//  AtelierCode
//
//  Created by Jeremy Margaritondo on 3/23/26.
//

import SwiftUI
import AppKit

@main
struct AtelierCodeApp: App {
    @State private var appModel: AppModel

    @MainActor
    init() {
        _appModel = State(initialValue: AppBootstrap.makeAppModel())
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(appModel)
                .preferredColorScheme(appModel.appearancePreference.preferredColorScheme)
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                    appModel.applicationDidBecomeActive()
                }
                .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
                    appModel.applicationWindowDidBecomeKey()
                }
        }
    }
}

private extension AppAppearancePreference {
    var preferredColorScheme: ColorScheme? {
        switch self {
        case .system:
            return nil
        case .light:
            return .light
        case .dark:
            return .dark
        }
    }
}
