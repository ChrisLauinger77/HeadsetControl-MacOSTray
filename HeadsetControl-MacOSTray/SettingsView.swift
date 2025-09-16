import SwiftUI

struct SettingsView: View {
    @AppStorage("updateInterval") var updateInterval: Double = 600
    @AppStorage("headsetcontrolPath") var headsetcontrolPath: String = "/opt/homebrew/bin/headsetcontrol"
    @AppStorage("testMode") var testMode: Bool = false
    @Environment(\.presentationMode) var presentationMode
    @State private var intervalString: String = "60"
    @FocusState private var intervalFieldIsFocused: Bool
    @FocusState private var pathFieldIsFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Settings")
                .font(.title)
                .padding(.bottom, 10)
            HStack {
                Picker("Test Mode:", selection: $testMode) {
                    Text("Enabled").tag(true)
                    Text("Disabled").tag(false)
                }
                .pickerStyle(.menu)
                .frame(width: 240)
            }
            HStack {
                Text("Update Interval (seconds):")
                TextField("Interval", text: $intervalString)
                    .frame(width: 80)
                    .focused($intervalFieldIsFocused)
                    .onChange(of: intervalString) { _, newValue in
                        if let value = Double(newValue), value >= 1, value <= 3600 {
                            updateInterval = value
                        }
                    }
            }
            HStack {
                Text("binary Path:")
                TextField("Path", text: $headsetcontrolPath)
                    .frame(width: 300)
                    .focused($pathFieldIsFocused)
            }
            HStack {
                Spacer()
                Button("Refresh") {
                    NotificationCenter.default.post(name: .refreshHeadsetStatus, object: nil)
                }
                Button("Close") {
                    presentationMode.wrappedValue.dismiss()
                }
            }
        }
        .padding()
        .frame(width: 400)
        .onAppear {
            intervalString = String(Int(updateInterval))
            intervalFieldIsFocused = true // Focus interval field on appear
            // Defensive: ensure testMode is always a Bool
            if let value = UserDefaults.standard.object(forKey: "testMode"), !(value is Bool) {
                UserDefaults.standard.set(false, forKey: "testMode")
            }
        }
    }
}

extension Notification.Name {
    static let refreshHeadsetStatus = Notification.Name("refreshHeadsetStatus")
}

struct SettingsView_Previews: PreviewProvider {
    static var previews: some View {
        SettingsView()
    }
}
