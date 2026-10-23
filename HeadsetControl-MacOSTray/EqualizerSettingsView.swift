import SwiftUI

@MainActor struct EqualizerSettingsView: View {
    @Bindable var model: EqualizerSettingsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(NSLocalizedString("Curves are saved per USB model. Apply sends settings only to the selected connected device.", comment: "EQ storage and explicit apply"))
                .font(.subheadline).foregroundStyle(.secondary)
            Text(NSLocalizedString("Device EQ cannot be read back. The editor shows a saved or new curve; changes are never applied automatically.", comment: "EQ is not readback"))
                .font(.caption).foregroundStyle(.secondary)
            if model.devices.isEmpty {
                Text(NSLocalizedString("Connect a headset with custom equalizer support.", comment: "No EQ device"))
            } else {
                Picker(NSLocalizedString("Device", comment: "Equalizer device"), selection: Binding(
                    get: { model.selectedUSBID },
                    set: { if let id = $0 { model.select(id) } }
                )) {
                    ForEach(model.devices, id: \.usbID) { device in
                        Text(device.product.isEmpty ? device.name : device.product).tag(Optional(device.usbID))
                    }
                }
                Picker(NSLocalizedString("Equalizer", comment: "EQ kind"), selection: $model.kind) {
                    ForEach(model.kinds, id: \.self) { kind in Text(kind.title).tag(kind) }
                }
                .pickerStyle(.segmented)
                if let message = model.metadataMessage {
                    Text(message).foregroundStyle(.secondary)
                }
                if let curve = model.draft {
                    switch curve {
                    case .graphic(let info, let bands):
                        Text(NSLocalizedString("Band values use the device’s native scale. Band frequencies are not reported.", comment: "Graphic EQ units"))
                            .font(.caption).foregroundStyle(.secondary)
                        ForEach(bands.indices, id: \.self) { index in
                            HStack {
                                Text(bandTitle(index)).frame(width: 65, alignment: .leading)
                                Slider(value: sliderBinding(index, info: info), in: info.minimum...info.maximum, step: info.step)
                                    .accessibilityLabel(bandTitle(index))
                                TextField(bandTitle(index), value: graphicBinding(index), format: .number.precision(.fractionLength(0...3)))
                                    .frame(width: 65)
                            }
                        }
                        presetCopyMenu(info: info)
                    case .parametric(let info, let bands):
                        HStack {
                            Text(NSLocalizedString("Band", comment: "EQ column")).frame(width: 40)
                            Text(NSLocalizedString("Frequency (Hz)", comment: "EQ column")).frame(width: 100)
                            Text(NSLocalizedString("Gain (dB)", comment: "EQ column")).frame(width: 75)
                            Text(verbatim: "Q").frame(width: 55)
                            Text(NSLocalizedString("Filter", comment: "EQ column")).frame(maxWidth: .infinity, alignment: .leading)
                        }.font(.caption)
                        ForEach(bands.indices, id: \.self) { index in
                            HStack {
                                Text(verbatim: "\(index + 1)").frame(width: 40)
                                numberField(NSLocalizedString("Frequency (Hz)", comment: "EQ field"), binding: parametricBinding(index, \.frequency), width: 100)
                                numberField(NSLocalizedString("Gain (dB)", comment: "EQ field"), binding: parametricBinding(index, \.gain), width: 75)
                                numberField("Q", binding: parametricBinding(index, \.q), width: 55)
                                Picker(NSLocalizedString("Filter", comment: "EQ filter"), selection: filterBinding(index)) {
                                    ForEach(info.filters, id: \.self) { filter in Text(filter.title).tag(filter) }
                                }.labelsHidden().frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                        Text(String(format: NSLocalizedString("Frequency: %.0f–%.0f Hz · Gain: %g–%g dB (step %g) · Q: %g–%g", comment: "Parametric EQ limits"),
                                    info.frequencyMinimum, info.frequencyMaximum, info.minimum, info.maximum, info.step, info.qMinimum, info.qMaximum))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if !curve.isValid {
                        Text(NSLocalizedString("Use finite values within the device’s ranges and gain step.", comment: "Invalid EQ draft"))
                            .foregroundStyle(.red)
                    }
                }
                if !model.isFresh || model.selectedDevice?.target == nil {
                    Text(NSLocalizedString("Apply is unavailable until this device has a current, unique connection.", comment: "Unsafe EQ target"))
                        .font(.caption).foregroundStyle(.secondary)
                }
                HStack {
                    Button(NSLocalizedString("Reset to Neutral", comment: "Reset EQ draft")) { model.resetToNeutral() }
                        .disabled(model.selectedDevice.flatMap { EqualizerCurve.neutral(for: $0, kind: model.kind) } == nil)
                    Spacer()
                    Button(NSLocalizedString("Save Curve", comment: "Save EQ locally")) { model.saveDraft() }
                        .disabled(model.draft?.isValid != true)
                    Button(NSLocalizedString("Apply", comment: "Apply EQ explicitly")) { model.applyDraft() }
                        .disabled(!model.canApplyDraft)
                }
            }
            if let message = model.message { Text(message).font(.callout) }
            if model.isApplying { ProgressView().controlSize(.small) }
        }
        .textFieldStyle(.roundedBorder)
        .disabled(model.isApplying)
    }

    private func bandTitle(_ index: Int) -> String {
        String(format: NSLocalizedString("Band %d", comment: "Graphic EQ band"), index + 1)
    }

    private func numberField(_ title: String, binding: Binding<Double>, width: CGFloat) -> some View {
        TextField(title, value: binding, format: .number.precision(.fractionLength(0...3)))
            .frame(width: width).accessibilityLabel(title)
    }

    @ViewBuilder private func presetCopyMenu(info: GraphicEqualizerInfo) -> some View {
        if case .success(let presets) = model.selectedDevice?.equalizerPresets {
            Menu(NSLocalizedString("Copy Preset into Custom", comment: "Seed graphic curve")) {
                ForEach(presets, id: \.index) { preset in
                    Button(preset.name ?? AppDefaults.presetName(index: preset.index, fallbackNames: AppDefaults.standard.string(forKey: "equalizerPresets") ?? AppDefaults.equalizerPresets)) {
                        model.copyPreset(preset)
                    }.disabled(!canCopy(preset, info: info))
                }
            }
        }
    }

    private func canCopy(_ preset: HeadsetEqualizerPreset, info: GraphicEqualizerInfo) -> Bool {
        if case .success(let bands) = preset.bands { return info.accepts(bands) }
        return false
    }

    func graphicBinding(_ index: Int) -> Binding<Double> {
        Binding(get: {
            guard case .graphic(_, let bands) = model.draft, bands.indices.contains(index) else { return 0 }
            return bands[index]
        }, set: { value in
            guard case .graphic(let info, var bands) = model.draft, bands.indices.contains(index) else { return }
            bands[index] = value
            model.setDraft(.graphic(info, bands))
        })
    }

    func sliderBinding(_ index: Int, info: GraphicEqualizerInfo) -> Binding<Double> {
        let binding = graphicBinding(index)
        return Binding(get: {
            let value = binding.wrappedValue
            return value.isFinite ? min(info.maximum, max(info.minimum, value)) : info.baseline
        }, set: { binding.wrappedValue = $0 })
    }

    func parametricBinding(_ index: Int, _ path: WritableKeyPath<ParametricEqualizerBand, Double>) -> Binding<Double> {
        Binding(get: {
            guard case .parametric(_, let bands) = model.draft, bands.indices.contains(index) else { return 0 }
            return bands[index][keyPath: path]
        }, set: { value in
            guard case .parametric(let info, var bands) = model.draft, bands.indices.contains(index) else { return }
            bands[index][keyPath: path] = value
            model.setDraft(.parametric(info, bands))
        })
    }

    func filterBinding(_ index: Int) -> Binding<EqualizerFilter> {
        Binding(get: {
            guard case .parametric(_, let bands) = model.draft, bands.indices.contains(index) else { return .peaking }
            return bands[index].filter
        }, set: { value in
            guard case .parametric(let info, var bands) = model.draft, bands.indices.contains(index) else { return }
            bands[index].filter = value
            model.setDraft(.parametric(info, bands))
        })
    }
}
