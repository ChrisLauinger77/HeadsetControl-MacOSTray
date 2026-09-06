import Foundation

nonisolated struct ApplicationVersionInfo {
    let version: String
    let build: String

    init(info: [String: Any]? = Bundle.main.infoDictionary) {
        version = info?["CFBundleShortVersionString"] as? String ?? "-"
        build = info?["CFBundleVersion"] as? String ?? "-"
    }

    var versionLine: String { "\(NSLocalizedString("Version", comment: "App version label")): \(version)" }
    var buildLine: String { "\(NSLocalizedString("Build", comment: "App build label")): \(build)" }
}

/// Display values come from the linked APIs. Only channel/revision come from the bundle.
nonisolated struct NativeDependencyVersions: Sendable {
    let headsetControl: String?
    let hidapi: String?
    let snapshotRevision: String?
    let diagnostics: [String]

    init(headsetControl: String?, hidapi: String?, provenance: Data?) {
        self.headsetControl = Self.usableVersion(headsetControl)
        self.hidapi = Self.usableVersion(hidapi)
        var diagnostics: [String] = []
        if self.headsetControl == nil { diagnostics.append("HeadsetControl returned an unavailable or malformed version") }
        if self.hidapi == nil { diagnostics.append("HIDAPI returned an unavailable or malformed version") }

        var snapshotRevision: String?
        if let provenance {
            do {
                let metadata = try JSONDecoder().decode(Provenance.self, from: provenance)
                guard metadata.schema == 2,
                      Self.usableVersion(metadata.headsetcontrol.version) == metadata.headsetcontrol.version,
                      Self.usableVersion(metadata.hidapi.version) == metadata.hidapi.version,
                      metadata.headsetcontrol.revision.utf8.count == 40,
                      metadata.headsetcontrol.revision.range(of: "^[a-f0-9]{40}$", options: .regularExpression) != nil
                else { throw CocoaError(.coderInvalidValue) }
                if self.headsetControl != metadata.headsetcontrol.version {
                    diagnostics.append("HeadsetControl runtime version differs from embedded build provenance")
                }
                if self.hidapi != metadata.hidapi.version {
                    diagnostics.append("HIDAPI runtime version differs from embedded build provenance")
                }
                if metadata.headsetcontrol.channel == .snapshot {
                    snapshotRevision = String(metadata.headsetcontrol.revision.prefix(12))
                }
            } catch {
                diagnostics.append("Invalid embedded build provenance: \(error)")
            }
        } else {
            // Direct development builds need not contain release provenance. Never infer
            // their channel or SHA from the source checkout or a baseline version string.
            diagnostics.append("BuildProvenance.json is unavailable; native channel/revision cannot be verified")
        }
        self.snapshotRevision = snapshotRevision
        self.diagnostics = diagnostics
    }

    var headsetControlDisplay: String {
        let version = headsetControl ?? NSLocalizedString("Unknown", comment: "Unknown native version")
        guard let snapshotRevision else { return version }
        return String(format: NSLocalizedString("%@ snapshot (%@)", comment: "Native version and short pinned snapshot revision"), version, snapshotRevision)
    }

    var hidapiDisplay: String { hidapi ?? NSLocalizedString("Unknown", comment: "Unknown native version") }

    static func usableVersion(_ value: String?) -> String? {
        guard let value, value.utf8.count <= 128 else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let pattern = #"^[0-9]+\.[0-9]+\.[0-9]+(?:-[0-9A-Za-z]+(?:[.-][0-9A-Za-z]+)*)?(?:\+[0-9A-Za-z]+(?:[.-][0-9A-Za-z]+)*)?$"#
        guard trimmed.range(of: pattern, options: .regularExpression) != nil else { return nil }
        return trimmed
    }

    private struct Provenance: Decodable {
        enum Channel: String, Decodable { case release, snapshot }
        struct HeadsetControl: Decodable {
            let version: String
            let revision: String
            let channel: Channel
        }
        struct HIDAPI: Decodable { let version: String }
        let schema: Int
        let headsetcontrol: HeadsetControl
        let hidapi: HIDAPI
    }
}
