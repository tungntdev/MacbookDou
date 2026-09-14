import AppKit
import CoreGraphics
import ServiceManagement
import SwiftUI

struct SettingsView: View {
    @ObservedObject var settings: Settings
    @ObservedObject var controller: EffectController
    @State private var language = AppLanguageStore.current
    @State private var hasScreenRecordingAccess = CGPreflightScreenCaptureAccess()

    private let refreshTimer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            if !controller.isSensorAvailable {
                Text(L("sensor.unavailable"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 24)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        Toggle(L("toggle.enabled"), isOn: $settings.isEnabled)
                        Toggle(L("toggle.live"), isOn: $settings.isLiveEnabled)
                            .disabled(!settings.isEnabled)

                        if !hasScreenRecordingAccess {
                            permissionNotice
                        }

                        Button(L("button.preview")) { controller.runPreview() }
                            .disabled(!settings.isEnabled)

                        Divider()
                        startGroup
                        Divider()
                        lookGroup
                        Divider()
                        perspectiveGroup
                    }
                }
                .frame(height: 400)
            }

            Divider()
            footer
        }
        .padding(16)
        .frame(width: 300)
        .onReceive(refreshTimer) { _ in hasScreenRecordingAccess = CGPreflightScreenCaptureAccess() }
    }

    private var header: some View {
        HStack {
            Text("MacbookDuo").font(.headline)
            Spacer()
            Text(String(format: "%.1f°", controller.currentAngleDegrees))
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(.secondary)
        }
    }

    private var permissionNotice: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L("permission.notice"))
                .font(.caption)
                .foregroundStyle(.secondary)
            Button(L("permission.open")) {
                let url = URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_ScreenCapture")!
                NSWorkspace.shared.open(url)
            }
            .font(.caption)
        }
        .padding(8)
        .background(Color.orange.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private var startGroup: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L("group.start")).font(.subheadline).bold()
            Toggle(L("toggle.holdTimeout"), isOn: $settings.isHoldTimeoutEnabled)
            labeledSlider(L("slider.triggerAngle"), value: $settings.triggerAngle, range: 5...130, suffix: "°")
            labeledSlider(L("slider.rampSpan"), value: $settings.rampSpan, range: 5...60, suffix: "°")
        }
        .disabled(!settings.isEnabled)
    }

    private var lookGroup: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L("group.look")).font(.subheadline).bold()
            labeledSlider(L("slider.blurRadius"), value: $settings.maxBlurRadius, range: 10...160, suffix: "pt")
            labeledPercentSlider(L("slider.blurEvenness"), value: $settings.blurEvenness)
            labeledPercentSlider(L("slider.dim"), value: $settings.maxDim)
            labeledSlider(L("slider.dimReach"), value: $settings.dimReach, range: 0.2...1, suffix: "")
        }
        .disabled(!settings.isEnabled)
    }

    private var perspectiveGroup: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L("group.perspective")).font(.subheadline).bold()
            labeledSlider(L("slider.lean"), value: $settings.leanAmount, range: 0...3, suffix: "x")
            labeledPercentSlider(L("slider.perspective"), value: $settings.perspectiveAmount)
        }
        .disabled(!settings.isEnabled)
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker(L("picker.language"), selection: $language) {
                ForEach(AppLanguage.allCases, id: \.self) { Text($0.displayName).tag($0) }
            }
            .pickerStyle(.menu)
            .onChange(of: language) { _, newValue in AppLanguageStore.current = newValue }

            Toggle(L("toggle.showAngle"), isOn: $settings.showsAngleInMenuBar)
            Toggle(L("toggle.launchAtLogin"), isOn: $settings.launchAtLogin)

            HStack {
                Button(L("button.reset")) { settings.resetToDefaults() }
                Spacer()
                Button(L("button.quit")) { NSApp.terminate(nil) }
            }
        }
    }

    private func labeledSlider(_ title: String, value: Binding<Double>, range: ClosedRange<Double>, suffix: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title)
                Spacer()
                Text("\(value.wrappedValue, specifier: "%.0f")\(suffix)").foregroundStyle(.secondary)
            }
            Slider(value: value, in: range)
        }
    }

    private func labeledPercentSlider(_ title: String, value: Binding<Double>) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title)
                Spacer()
                Text("\(Int(value.wrappedValue * 100))%").foregroundStyle(.secondary)
            }
            Slider(value: value, in: 0...1)
        }
    }
}
