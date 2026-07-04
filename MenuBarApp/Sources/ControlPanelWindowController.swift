import AppKit
import Foundation

final class ControlPanelWindowController: NSWindowController {
    private let controller: SkyDimoController
    private let onModeApplied: (String?) -> Void
    private let portPopup = NSPopUpButton()
    private let modePopup = NSPopUpButton()
    private let colorWell = NSColorWell()
    private let brightnessSlider = NSSlider(value: defaultCustomColorBrightness, minValue: 0.05, maxValue: 1.0, target: nil, action: nil)
    private let speedSlider = NSSlider(value: 0.45, minValue: 0.0, maxValue: 1.5, target: nil, action: nil)
    private let flickerSlider = NSSlider(value: 0.22, minValue: 0.0, maxValue: 1.0, target: nil, action: nil)
    private let intensitySlider = NSSlider(value: 0.45, minValue: 0.0, maxValue: 1.0, target: nil, action: nil)
    private let fpsSlider = NSSlider(value: defaultFrameRate, minValue: minimumFrameRate, maxValue: maximumFrameRate, target: nil, action: nil)
    private let brightnessValue = NSTextField(labelWithString: "")
    private let speedValue = NSTextField(labelWithString: "")
    private let flickerValue = NSTextField(labelWithString: "")
    private let intensityValue = NSTextField(labelWithString: "")
    private let fpsValue = NSTextField(labelWithString: "")
    private var isUpdatingUI = false

    init(controller: SkyDimoController, onModeApplied: @escaping (String?) -> Void) {
        self.controller = controller
        self.onModeApplied = onModeApplied

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 410),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "SkyDimo Control"
        window.isReleasedWhenClosed = false
        super.init(window: window)

        buildContent()
        setMode("Custom Color", apply: false)
        updateValueLabels()
        updateControlAvailability()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show(activeMode: String?) {
        fpsSlider.doubleValue = controller.currentFrameRate
        refreshPorts()
        setMode(activeMode ?? "Custom Color", apply: false)
        showWindow(nil)
        window?.center()
        NSApp.activate(ignoringOtherApps: true)
    }

    private func buildContent() {
        guard let window else { return }

        let root = NSStackView()
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 14
        root.edgeInsets = NSEdgeInsets(top: 18, left: 18, bottom: 18, right: 18)
        root.translatesAutoresizingMaskIntoConstraints = false

        let title = NSTextField(labelWithString: "SkyDimo")
        title.font = .systemFont(ofSize: 22, weight: .semibold)

        portPopup.target = self
        portPopup.action = #selector(portChanged)
        portPopup.toolTip = "Serial port used for the strip. Auto prefers /dev/cu.usbserial* devices."
        portPopup.widthAnchor.constraint(equalToConstant: 230).isActive = true
        refreshPorts()

        modePopup.addItems(withTitles: [
            "Custom Color",
            "Candle",
            "Amber",
            "Warm White",
            "Neutral White",
            "Red",
            "Soft Flame",
            "Rainbow",
        ])
        modePopup.target = self
        modePopup.action = #selector(modeChanged)
        modePopup.toolTip = "Select what the strip should display."

        colorWell.color = savedCustomNSColor()
        brightnessSlider.doubleValue = savedCustomBrightness()
        colorWell.target = self
        colorWell.action = #selector(apply)
        colorWell.toolTip = "Custom color. Available only in Custom Color mode."

        brightnessSlider.toolTip = "Overall light output. Lower values are dimmer."
        speedSlider.toolTip = "Animation speed for Rainbow and Flame modes."
        flickerSlider.toolTip = "Amount of random-looking flame movement. Available only for Flame modes."
        intensitySlider.toolTip = "Flame heat. Higher values make the flame brighter and yellower."
        fpsSlider.toolTip = "Frames sent to the strip per second. Available for animated modes; default is 80."

        for slider in [brightnessSlider, speedSlider, flickerSlider, intensitySlider, fpsSlider] {
            slider.target = self
            slider.action = #selector(sliderChanged)
            slider.widthAnchor.constraint(equalToConstant: 190).isActive = true
        }

        root.addArrangedSubview(title)
        root.addArrangedSubview(row(label: "Port", control: portPopup))
        root.addArrangedSubview(row(label: "Mode", control: modePopup))
        root.addArrangedSubview(row(label: "Color", control: colorWell))
        root.addArrangedSubview(sliderRow(label: "Brightness", slider: brightnessSlider, valueLabel: brightnessValue))
        root.addArrangedSubview(sliderRow(label: "Speed", slider: speedSlider, valueLabel: speedValue))
        root.addArrangedSubview(sliderRow(label: "Flicker", slider: flickerSlider, valueLabel: flickerValue))
        root.addArrangedSubview(sliderRow(label: "Heat", slider: intensitySlider, valueLabel: intensityValue))
        root.addArrangedSubview(sliderRow(label: "FPS", slider: fpsSlider, valueLabel: fpsValue))

        let buttons = NSStackView()
        buttons.orientation = .horizontal
        buttons.spacing = 8
        buttons.addArrangedSubview(button(title: "Apply", action: #selector(applyAndClose), tooltip: "Apply the selected mode and current settings, then close this panel."))
        buttons.addArrangedSubview(button(title: "Off", action: #selector(off), tooltip: "Send black frames and turn the strip off."))
        buttons.addArrangedSubview(button(title: "Stop", action: #selector(stop), tooltip: "Stop sending frames without changing the last selected preset."))
        root.addArrangedSubview(buttons)

        window.contentView = NSView()
        window.contentView?.addSubview(root)
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor),
            root.topAnchor.constraint(equalTo: window.contentView!.topAnchor),
            root.bottomAnchor.constraint(equalTo: window.contentView!.bottomAnchor),
        ])
    }

    private func row(label: String, control: NSView) -> NSStackView {
        let labelView = NSTextField(labelWithString: label)
        labelView.widthAnchor.constraint(equalToConstant: 82).isActive = true
        labelView.toolTip = control.toolTip

        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 12
        stack.addArrangedSubview(labelView)
        stack.addArrangedSubview(control)
        return stack
    }

    private func sliderRow(label: String, slider: NSSlider, valueLabel: NSTextField) -> NSStackView {
        valueLabel.alignment = .right
        valueLabel.widthAnchor.constraint(equalToConstant: 42).isActive = true
        valueLabel.toolTip = slider.toolTip

        let stack = row(label: label, control: slider)
        stack.addArrangedSubview(valueLabel)
        return stack
    }

    private func button(title: String, action: Selector, tooltip: String) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.bezelStyle = .rounded
        button.toolTip = tooltip
        return button
    }

    @objc private func modeChanged() {
        setMode(modePopup.titleOfSelectedItem ?? "Custom Color", apply: true)
    }

    @objc private func portChanged() {
        guard !isUpdatingUI else { return }
        let selected = portPopup.selectedItem?.representedObject as? String
        controller.setSerialPort(selected)
        apply()
    }

    @objc private func sliderChanged() {
        updateValueLabels()
        apply()
    }

    @objc private func apply() {
        applyCurrentMode()
    }

    @objc private func applyAndClose() {
        applyCurrentMode()
        colorWell.deactivate()
        NSColorPanel.shared.orderOut(nil)
        window?.close()
    }

    private func applyCurrentMode() {
        guard !isUpdatingUI else { return }
        guard let mode = modePopup.titleOfSelectedItem else { return }
        controller.setFrameRate(fpsSlider.doubleValue)
        switch mode {
        case "Soft Flame":
            controller.runFlame(
                brightness: brightnessSlider.doubleValue,
                flicker: flickerSlider.doubleValue,
                speed: speedSlider.doubleValue,
                intensity: intensitySlider.doubleValue
            )
        case "Rainbow":
            controller.runRainbow(brightness: brightnessSlider.doubleValue, speed: speedSlider.doubleValue)
        case "Custom Color":
            saveCustomColor()
            controller.runColor(rgb(from: colorWell.color, brightness: brightnessSlider.doubleValue))
        default:
            controller.runColor(rgb(from: colorWell.color, brightness: brightnessSlider.doubleValue))
        }
        onModeApplied(mode)
    }

    @objc private func off() {
        onModeApplied(nil)
        controller.off()
    }

    @objc private func stop() {
        onModeApplied(nil)
        controller.stop()
    }

    private func updateValueLabels() {
        brightnessValue.stringValue = String(format: "%.2f", brightnessSlider.doubleValue)
        speedValue.stringValue = String(format: "%.2f", speedSlider.doubleValue)
        flickerValue.stringValue = String(format: "%.2f", flickerSlider.doubleValue)
        intensityValue.stringValue = String(format: "%.2f", intensitySlider.doubleValue)
        fpsValue.stringValue = String(format: "%.0f", fpsSlider.doubleValue)
    }

    private func refreshPorts() {
        let selectedPort = controller.currentSerialPort
        isUpdatingUI = true
        portPopup.removeAllItems()

        portPopup.addItem(withTitle: "Auto")
        portPopup.lastItem?.representedObject = automaticSerialPortValue

        let ports = SerialPort.portCandidates()
        for port in ports {
            portPopup.addItem(withTitle: port.replacingOccurrences(of: "/dev/", with: ""))
            portPopup.lastItem?.representedObject = port
        }

        if let selectedPort, ports.contains(selectedPort) {
            selectPortPopupValue(selectedPort)
        } else if let selectedPort {
            portPopup.addItem(withTitle: "\(selectedPort.replacingOccurrences(of: "/dev/", with: "")) (missing)")
            portPopup.lastItem?.representedObject = selectedPort
            selectPortPopupValue(selectedPort)
        } else {
            selectPortPopupValue(automaticSerialPortValue)
        }
        isUpdatingUI = false
    }

    private func selectPortPopupValue(_ value: String) {
        for item in portPopup.itemArray {
            if item.representedObject as? String == value {
                portPopup.select(item)
                return
            }
        }
        portPopup.selectItem(at: 0)
    }

    private func setMode(_ mode: String, apply: Bool) {
        isUpdatingUI = true
        modePopup.selectItem(withTitle: mode)
        if modePopup.titleOfSelectedItem == nil {
            modePopup.selectItem(withTitle: "Custom Color")
        }

        switch modePopup.titleOfSelectedItem ?? "Custom Color" {
        case "Custom Color":
            colorWell.color = savedCustomNSColor()
            brightnessSlider.doubleValue = savedCustomBrightness()
        case "Candle":
            colorWell.color = NSColor(calibratedRed: 1.0, green: 0.70, blue: 0.28, alpha: 1.0)
            brightnessSlider.doubleValue = 1.0
        case "Amber":
            colorWell.color = NSColor(calibratedRed: 1.0, green: 0.62, blue: 0.18, alpha: 1.0)
            brightnessSlider.doubleValue = 1.0
        case "Warm White":
            colorWell.color = NSColor(calibratedRed: 1.0, green: 0.76, blue: 0.36, alpha: 1.0)
            brightnessSlider.doubleValue = 1.0
        case "Neutral White":
            colorWell.color = NSColor(calibratedRed: 1.0, green: 0.88, blue: 0.64, alpha: 1.0)
            brightnessSlider.doubleValue = 1.0
        case "Red":
            colorWell.color = .red
            brightnessSlider.doubleValue = 1.0
        case "Soft Flame":
            brightnessSlider.doubleValue = 1.0
            flickerSlider.doubleValue = 0.18
            speedSlider.doubleValue = 0.45
            intensitySlider.doubleValue = 0.45
        case "Rainbow":
            brightnessSlider.doubleValue = 1.0
            speedSlider.doubleValue = 0.20
        default:
            break
        }

        isUpdatingUI = false
        updateValueLabels()
        updateControlAvailability()
        if apply {
            self.apply()
        }
    }

    private func updateControlAvailability() {
        let mode = modePopup.titleOfSelectedItem ?? "Custom Color"
        let isCustomColor = mode == "Custom Color"
        let isStaticPreset = ["Candle", "Amber", "Warm White", "Neutral White", "Red"].contains(mode)
        let isRainbow = mode == "Rainbow"
        let isFlame = mode == "Soft Flame"

        colorWell.isEnabled = isCustomColor
        brightnessSlider.isEnabled = isCustomColor || isStaticPreset || isRainbow || isFlame
        brightnessValue.isEnabled = brightnessSlider.isEnabled
        speedSlider.isEnabled = isRainbow || isFlame
        speedValue.isEnabled = speedSlider.isEnabled
        flickerSlider.isEnabled = isFlame
        flickerValue.isEnabled = flickerSlider.isEnabled
        intensitySlider.isEnabled = isFlame
        intensityValue.isEnabled = intensitySlider.isEnabled
        fpsSlider.isEnabled = isRainbow || isFlame
        fpsValue.isEnabled = fpsSlider.isEnabled
    }

    private func rgb(from color: NSColor, brightness: Double) -> RGB {
        let converted = color.usingColorSpace(.sRGB) ?? color
        return RGB(
            r: UInt8(max(0, min(255, round(converted.redComponent * brightness * 255)))),
            g: UInt8(max(0, min(255, round(converted.greenComponent * brightness * 255)))),
            b: UInt8(max(0, min(255, round(converted.blueComponent * brightness * 255))))
        )
    }

    private func saveCustomColor() {
        UserDefaults.standard.set(hex(from: colorWell.color), forKey: customColorHexKey)
        UserDefaults.standard.set(brightnessSlider.doubleValue, forKey: customColorBrightnessKey)
    }

    private func savedCustomNSColor() -> NSColor {
        let rgb = parseRGB(UserDefaults.standard.string(forKey: customColorHexKey) ?? defaultCustomColorHex)
        return NSColor(
            calibratedRed: CGFloat(rgb.r) / 255.0,
            green: CGFloat(rgb.g) / 255.0,
            blue: CGFloat(rgb.b) / 255.0,
            alpha: 1.0
        )
    }

    private func savedCustomBrightness() -> Double {
        if UserDefaults.standard.object(forKey: customColorBrightnessKey) == nil {
            return defaultCustomColorBrightness
        }
        return max(0.05, min(1.0, UserDefaults.standard.double(forKey: customColorBrightnessKey)))
    }

    private func hex(from color: NSColor) -> String {
        let converted = color.usingColorSpace(.sRGB) ?? color
        let red = Int(max(0, min(255, round(converted.redComponent * 255))))
        let green = Int(max(0, min(255, round(converted.greenComponent * 255))))
        let blue = Int(max(0, min(255, round(converted.blueComponent * 255))))
        return String(format: "#%02x%02x%02x", red, green, blue)
    }
}
