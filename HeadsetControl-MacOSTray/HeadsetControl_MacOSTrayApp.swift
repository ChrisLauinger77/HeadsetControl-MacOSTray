//
//  HeadsetControl_MacOSTrayApp.swift
//  HeadsetControl-MacOSTray
//
//  Created by Christian Lauinger on 16.09.25.
//

import SwiftUI

@main struct
HeadsetControl_MacOSTray: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
  var body: some Scene {
    Settings {
      Text("Settings or main app window")
    }
  }
}


