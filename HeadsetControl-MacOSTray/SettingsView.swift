import SwiftUI

struct SettingsView: View {
    @AppStorage("sidetoneOff") var sidetoneOff: Int = 0
    @AppStorage("sidetoneLow") var sidetoneLow: Int = 32
    @AppStorage("sidetoneMid") var sidetoneMid: Int = 64
    @AppStorage("sidetoneHigh") var sidetoneHigh: Int = 96
    @AppStorage("sidetoneMax") var sidetoneMax: Int = 128
    var onClose: (() -> Void)? = nil
    @AppStorage("updateInterval") var updateInterval: Double = 600
    @AppStorage("headsetcontrolPath") var headsetcontrolPath: String = "/opt/homebrew/bin/headsetcontrol"
    @AppStorage("testMode") var testMode: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            Text("HeadsetControl-MacOSTray")
                .font(.largeTitle)
                .bold()
                .padding(.top, 16)
                .padding(.bottom, 8)

            // General Settings Section
            VStack(alignment: .leading, spacing: 12) {
                Text("General Settings")
                    .font(.headline)
                HStack(alignment: .center) {
                    Text("Test Mode:")
                    Picker("", selection: $testMode) {
                        Text("Enabled").tag(true)
                        Text("Disabled").tag(false)
                    }
                    .pickerStyle(.menu)
                }
                HStack(alignment: .center) {
                    Text("Update Interval (seconds):")
                    Slider(value: $updateInterval, in: 60...3600, step: 30)
                    Text("\(Int(updateInterval)) s")
                }
                TextField("Binary Path:", text: $headsetcontrolPath)
                    .textFieldStyle(.roundedBorder)
                    .disabled(false)
            }
            Divider()

            // Sidetone Section
            VStack(alignment: .leading, spacing: 12) {
                Text("Sidetone")
                    .font(.headline)
                Text("Sidetone Level Values (set -1 to hide)")
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Off:")
                        TextField("Off", value: $sidetoneOff, formatter: NumberFormatter())
                    }
                    HStack {
                        Text("Low:")
                        TextField("Low", value: $sidetoneLow, formatter: NumberFormatter())
                    }
                    HStack {
                        Text("Mid:")
                        TextField("Mid", value: $sidetoneMid, formatter: NumberFormatter())
                    }
                    HStack {
                        Text("High:")
                        TextField("High", value: $sidetoneHigh, formatter: NumberFormatter())
                    }
                    HStack {
                        Text("Max:")
                        TextField("Max", value: $sidetoneMax, formatter: NumberFormatter())
                    }
                }
            }
            Divider()

            // Buttons Section
            HStack(spacing: 8) {
                Spacer()
                Button("Refresh") {
                    NotificationCenter.default.post(name: .refreshHeadsetStatus, object: nil)
                }
                Button("Close") {
                    onClose?()
                }
                Spacer()
            }
        }
        .padding()
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
