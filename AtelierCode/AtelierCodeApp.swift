//
//  AtelierCodeApp.swift
//  AtelierCode
//
//  Created by Jeremy Margaritondo on 3/23/26.
//

import SwiftUI

@main
struct AtelierCodeApp: App {
    @Environment(\.scenePhase) private var scenePhase
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
                .onChange(of: scenePhase) { _, newValue in
                    guard newValue == .active else {
                        return
                    }

                    appModel.applicationDidBecomeActive()
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
