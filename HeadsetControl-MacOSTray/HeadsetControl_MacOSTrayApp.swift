//
//  HeadsetControl_MacOSTrayApp.swift
//  HeadsetControl-MacOSTray
//
//  Created by Christian Lauinger on 16.09.25.
//

import SwiftUI
import AppKit

@main struct
HeadsetControl_MacOSTray: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    init() { _ = AppDefaults.standard }

    var body: some Scene {
        Settings {
            SettingsView(equalizer: appDelegate.equalizerSettings, onClose: {
                NSApp.keyWindow?.close()
            }, onANCCommand: { appDelegate.performANCSettingsCommand($0) })
            .frame(minWidth: 580, minHeight: 440)
        }
    }
}
