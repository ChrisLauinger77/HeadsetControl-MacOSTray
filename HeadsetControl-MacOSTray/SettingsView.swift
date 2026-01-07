import SwiftUI
import AppKit

// SwiftUI wrapper for NSImage
struct AppIconImage: NSViewRepresentable {
    func makeNSView(context: Context) -> NSImageView {
        let imageView = NSImageView()
        imageView.image = NSApplication.shared.applicationIconImage
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.wantsLayer = true
        imageView.layer?.cornerRadius = 12
        imageView.layer?.masksToBounds = true
        return imageView
    }
    func updateNSView(_ nsView: NSImageView, context: Context) {}
}

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
    @AppStorage("equalizerPresets") var equalizerPresets: String = "Preset 1,Preset 2,Preset 3,Preset 4"

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            // App Icon at the top
            HStack {
                Spacer()
                AppIconImage()
                    .frame(width: 64, height: 64)
                    .shadow(radius: 4)
                    .padding(.top, 16)
                Spacer()
            }

            Text(NSLocalizedString("HeadsetControl-MacOSTray", comment: "App title"))
                .font(.largeTitle)
                .bold()
                .padding(.top, 8)
                .padding(.bottom, 8)

            // General Settings Section
            VStack(alignment: .leading, spacing: 12) {
                Text(NSLocalizedString("General Settings", comment: "General settings section header"))
                    .font(.headline)
                HStack(alignment: .center) {
                    Text(NSLocalizedString("Test Mode:", comment: "Test mode label"))
                    Picker("", selection: $testMode) {
                        Text(NSLocalizedString("Enabled", comment: "Test mode enabled"))
                            .tag(true)
                        Text(NSLocalizedString("Disabled", comment: "Test mode disabled"))
                            .tag(false)
                    }
                    .pickerStyle(.menu)
                }
                HStack(alignment: .center) {
                    Text(NSLocalizedString("Update Interval (seconds):", comment: "Update interval label"))
                    Slider(value: $updateInterval, in: 60...3600, step: 30)
                    Text("\(Int(updateInterval)) s")
                }
                HStack(alignment: .center) {
                    Text(NSLocalizedString("Binary Path:", comment: "Binary path label"))
                    TextField(NSLocalizedString("Binary Path:", comment: "Binary path label"), text: $headsetcontrolPath)
                        .textFieldStyle(.roundedBorder)
                        .disabled(false)
                }
            }
                
            Divider()

            // Sidetone Section
            VStack(alignment: .leading, spacing: 12) {
                Text(NSLocalizedString("Sidetone", comment: "Sidetone section header"))
                    .font(.headline)
                Text(NSLocalizedString("Sidetone Level Values (set -1 to hide)", comment: "Sidetone level info"))
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text(NSLocalizedString("Off:", comment: "Sidetone off label"))
                        TextField(NSLocalizedString("Off", comment: "Sidetone off field"), value: $sidetoneOff, formatter: NumberFormatter())
                    }
                    HStack {
                        Text(NSLocalizedString("Low:", comment: "Sidetone low label"))
                        TextField(NSLocalizedString("Low", comment: "Sidetone low field"), value: $sidetoneLow, formatter: NumberFormatter())
                    }
                    HStack {
                        Text(NSLocalizedString("Medium:", comment: "Sidetone medium label"))
                        TextField(NSLocalizedString("Medium", comment: "Sidetone medium field"), value: $sidetoneMid, formatter: NumberFormatter())
                    }
                    HStack {
                        Text(NSLocalizedString("High:", comment: "Sidetone high label"))
                        TextField(NSLocalizedString("High", comment: "Sidetone high field"), value: $sidetoneHigh, formatter: NumberFormatter())
                    }
                    HStack {
                        Text(NSLocalizedString("Maximum:", comment: "Sidetone maximum label"))
                        TextField(NSLocalizedString("Maximum", comment: "Sidetone maximum field"), value: $sidetoneMax, formatter: NumberFormatter())
                    }
                }
            }
            Divider()

            // Equalizer Presets Section
            VStack(alignment: .leading, spacing: 12) {
                Text(NSLocalizedString("Equalizer Presets", comment: "Equalizer presets section header"))
                    .font(.headline)
                Text(NSLocalizedString("Comma-separated list of preset names.", comment: "Equalizer presets help text"))
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                TextField(NSLocalizedString("Preset names", comment: "Equalizer presets text field label"), text: $equalizerPresets)
                    .textFieldStyle(.roundedBorder)
            }
            Divider()

            // Buttons Section
            HStack(spacing: 8) {
                Spacer()
                Button(NSLocalizedString("Refresh", comment: "Refresh button")) {
                    NotificationCenter.default.post(name: .refreshHeadsetStatus, object: nil)
                }
                Button(NSLocalizedString("Close", comment: "Close button")) {
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
