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

    var body: some Scene {
        Settings {
            SettingsView {
                NSApp.keyWindow?.close()
            }
            .frame(minWidth: 580, minHeight: 440)
        }
    }
}

