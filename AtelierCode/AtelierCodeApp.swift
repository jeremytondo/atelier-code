//
//  AtelierCodeApp.swift
//  AtelierCode
//
//  Created by Jeremy Margaritondo on 3/12/26.
//

import SwiftUI

@main
struct AtelierCodeApp: App {
    @State private var store = ACPStore()

    var body: some Scene {
        WindowGroup {
            ContentView(store: store)
        }
    }
}
