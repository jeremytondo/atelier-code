//
//  AtelierCodeApp.swift
//  AtelierCode
//
//  Created by Jeremy Margaritondo on 3/12/26.
//

import SwiftUI

@main
struct AtelierCodeApp: App {
    @State private var shellModel = AppShellModel()

    var body: some Scene {
        WindowGroup {
            AppShellView(model: shellModel)
        }
    }
}
