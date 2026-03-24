//
//  AtelierCodeApp.swift
//  AtelierCode
//
//  Created by Jeremy Margaritondo on 3/23/26.
//

import SwiftUI

@main
struct AtelierCodeApp: App {
    @State private var appModel = AppModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(appModel)
        }
    }
}
