//
//  SpeakerTyperApp.swift
//  speakertpyer
//
//  Created by 顏國明 on 2026/1/27.
//

import SwiftUI

@main
struct SpeakerTyperApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    let persistenceController = PersistenceController.shared

    var body: some Scene {
        MenuBarExtra("Saybit", systemImage: "mic.fill") {
            MenuBarView()
                .environment(\.managedObjectContext, persistenceController.container.viewContext)
                .environmentObject(appDelegate.settingsStore)
        }

        Settings {
            SettingsView()
                .environment(\.managedObjectContext, persistenceController.container.viewContext)
                .environmentObject(appDelegate.settingsStore)
        }
    }
}
