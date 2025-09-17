import SwiftUI

struct SettingsView: View {
    var onClose: (() -> Void)? = nil
    @AppStorage("updateInterval") var updateInterval: Double = 600
    @AppStorage("headsetcontrolPath") var headsetcontrolPath: String = "/opt/homebrew/bin/headsetcontrol"
    @AppStorage("testMode") var testMode: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Overall header with app name
            Text("HeadsetControl-MacOSTray")
                .font(.largeTitle)
                .bold()
                .padding(.top, 16)
                .padding(.bottom, 8)
                .frame(maxWidth: .infinity, alignment: .center)
            Form {
                Section(header: Text("General Settings").font(.headline)) {
                    Picker("Test Mode:", selection: $testMode) {
                        Text("Enabled").tag(true)
                        Text("Disabled").tag(false)
                    }
                    .pickerStyle(.menu)
                    .frame(width: 240)
                    HStack {
                        Text("Update Interval (seconds):")
                        Slider(value: $updateInterval, in: 60...3600, step: 30)
                            .frame(width: 200)
                        Text("\(Int(updateInterval)) s")
                            .frame(width: 60, alignment: .leading)
                    }
                    HStack {
                        Text("binary Path:")
                        TextField("Path", text: $headsetcontrolPath)
                            .frame(width: 300)
                            .textFieldStyle(.roundedBorder)
                            .disabled(false)
                    }
                }
                Section(header: Text("Other Settings").font(.headline)) {
                    // Placeholder for future settings group
                    Text("More settings coming soon...")
                }
                Section {
                    HStack {
                        Spacer()
                        Button("Refresh") {
                            NotificationCenter.default.post(name: .refreshHeadsetStatus, object: nil)
                        }
                        Button("Close") {
                            onClose?()
                        }
                    }
                }
            }
        }
        .padding()
        .frame(minWidth: 500, minHeight: 400)
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
