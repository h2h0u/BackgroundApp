//
//  BackgroundAppApp.swift
//  BackgroundApp
//
//  Created by Hai Zhou on 9/21/24.
//

import SwiftUI

@main
struct BackgroundAppApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}
