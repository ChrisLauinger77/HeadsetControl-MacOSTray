//
//  ContentView.swift
//  HeadsetControl_MacOSTray
//
//  Created by Christian Lauinger on 16.09.25.
//

import SwiftUI

struct ContentView: View {
    var body: some View {
        VStack {
            Image(systemName: "globe")
                .imageScale(.large)
                .foregroundStyle(.tint)
            Text(NSLocalizedString("HeadsetControl-MacOSTray", comment: "App name"))
        }
        .padding()
    }
}

#Preview {
    ContentView()
}

