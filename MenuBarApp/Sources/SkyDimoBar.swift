import AppKit
import Darwin
import Foundation

private let ledCount = 65
private let defaultFrameRate = 80.0
private let minimumFrameRate = 10.0
private let maximumFrameRate = 120.0
private let lastPresetKey = "lastPreset"
private let selectedSerialPortKey = "selectedSerialPort"
private let automaticSerialPortValue = "auto"
private let customColorHexKey = "customColorHex"
private let customColorBrightnessKey = "customColorBrightness"
private let defaultCustomColorHex = "#ffb347"
private let defaultCustomColorBrightness = 1.0
private let turnOffOnDisplaySleepKey = "turnOffOnDisplaySleep"
private let redCalibration = 1.0
private let greenCalibration = 0.72
private let blueCalibration = 0.25
private let serialPortPrefixes = [
    "cu.usbserial",
    "cu.wchusbserial",
    "cu.SLAB_USBtoUART",
    "cu.usbmodem",
]

private struct RGB {
    let r: UInt8
    let g: UInt8
    let b: UInt8
}

private func parseRGB(_ hex: String) -> RGB {
    let trimmed = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
    let value = UInt32(trimmed, radix: 16) ?? 0
    return RGB(
        r: UInt8((value >> 16) & 0xff),
        g: UInt8((value >> 8) & 0xff),
        b: UInt8(value & 0xff)
    )
}

private final class SerialPort {
    private var fd: Int32 = -1

    deinit {
        close()
    }

    func open(preferredPath: String?) throws {
        close()

        let candidates: [String]
        if let preferredPath, !preferredPath.isEmpty {
            candidates = [preferredPath]
        } else {
            candidates = Self.portCandidates()
        }

        if candidates.isEmpty {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(ENOENT), userInfo: [
                NSLocalizedDescriptionKey: "SkyDimo serial port was not found. Tried /dev/cu.usbserial*, /dev/cu.wchusbserial*, /dev/cu.SLAB_USBtoUART*, /dev/cu.usbmodem*."
            ])
        }

        var errors: [String] = []
        for candidate in candidates {
            let candidateFd = Darwin.open(candidate, O_RDWR | O_NOCTTY | O_NONBLOCK)
            if candidateFd < 0 {
                let error = errno
                errors.append("\(candidate): \(String(cString: strerror(error)))")
                continue
            }

            fd = candidateFd
            do {
                try configureOpenPort()
                return
            } catch {
                close()
                errors.append("\(candidate): \(error.localizedDescription)")
            }
        }

        throw NSError(domain: NSPOSIXErrorDomain, code: Int(EIO), userInfo: [
            NSLocalizedDescriptionKey: "Could not open SkyDimo serial port. Tried:\n\(errors.joined(separator: "\n"))"
        ])
    }

    private func configureOpenPort() throws {
        var options = termios()
        if tcgetattr(fd, &options) != 0 {
            let error = errno
            close()
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(error), userInfo: [
                NSLocalizedDescriptionKey: "Could not read serial options: \(String(cString: strerror(error)))"
            ])
        }

        cfmakeraw(&options)
        cfsetspeed(&options, speed_t(B115200))

        options.c_cflag |= tcflag_t(CLOCAL | CREAD)
        options.c_cflag &= ~tcflag_t(PARENB)
        options.c_cflag &= ~tcflag_t(CSTOPB)
        options.c_cflag &= ~tcflag_t(CSIZE)
        options.c_cflag |= tcflag_t(CS8)
        #if os(macOS)
        options.c_cflag &= ~tcflag_t(CRTSCTS)
        #endif
        options.c_cc.16 = 0
        options.c_cc.17 = 1

        if tcsetattr(fd, TCSANOW, &options) != 0 {
            let error = errno
            close()
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(error), userInfo: [
                NSLocalizedDescriptionKey: "Could not configure serial port: \(String(cString: strerror(error)))"
            ])
        }

        tcflush(fd, TCIOFLUSH)
    }

    fileprivate static func portCandidates() -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: "/dev")) ?? []
        return serialPortPrefixes.flatMap { prefix in
            names
                .filter { $0.hasPrefix(prefix) }
                .sorted()
                .map { "/dev/\($0)" }
        }
    }

    func write(_ bytes: [UInt8]) throws {
        var offset = 0
        while offset < bytes.count {
            let written = bytes.withUnsafeBytes { pointer in
                Darwin.write(fd, pointer.baseAddress!.advanced(by: offset), bytes.count - offset)
            }
            if written < 0 {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [
                    NSLocalizedDescriptionKey: "Serial write failed: \(String(cString: strerror(errno)))"
                ])
            }
            offset += written
        }
        tcdrain(fd)
    }

    func close() {
        if fd >= 0 {
            Darwin.close(fd)
            fd = -1
        }
    }
}

private enum Effect {
    case color(RGB)
    case rainbow(brightness: Double, speed: Double)
    case flame(brightness: Double, flicker: Double, speed: Double, intensity: Double)
}

final class SkyDimoController {
    private let serial = SerialPort()
    private let queue = DispatchQueue(label: "local.skydimo.serial")
    private var timer: DispatchSourceTimer?
    private var startedAt = Date()
    private var generation = 0
    private var frameRate = defaultFrameRate
    private var selectedSerialPort: String? = {
        let value = UserDefaults.standard.string(forKey: selectedSerialPortKey)
        return value == automaticSerialPortValue ? nil : value
    }()

    var currentFrameRate: Double {
        frameRate
    }

    var currentSerialPort: String? {
        selectedSerialPort
    }

    func setFrameRate(_ value: Double) {
        frameRate = max(minimumFrameRate, min(maximumFrameRate, value))
    }

    func setSerialPort(_ value: String?) {
        let normalized = value == automaticSerialPortValue ? nil : value
        selectedSerialPort = normalized
        if let normalized {
            UserDefaults.standard.set(normalized, forKey: selectedSerialPortKey)
        } else {
            UserDefaults.standard.removeObject(forKey: selectedSerialPortKey)
        }
    }

    fileprivate func runColor(_ color: RGB) {
        run(.color(color))
    }

    func runRainbow(brightness: Double, speed: Double) {
        run(.rainbow(brightness: brightness, speed: speed))
    }

    func runFlame(brightness: Double, flicker: Double, speed: Double, intensity: Double = 0.45) {
        run(.flame(brightness: brightness, flicker: flicker, speed: speed, intensity: intensity))
    }

    func off() {
        stop()
        let offFrameRate = frameRate
        let port = selectedSerialPort
        queue.async { [serial, offFrameRate, port] in
            do {
                try serial.open(preferredPath: port)
                try Self.sendOffFrames(using: serial, frames: Int(round(offFrameRate)), frameRate: offFrameRate)
                serial.close()
            } catch {
                serial.close()
            }
        }
    }

    func turnOffAndClose() {
        generation += 1
        timer?.cancel()
        timer = nil

        let offFrameRate = frameRate
        let port = selectedSerialPort
        queue.sync { [serial, offFrameRate, port] in
            do {
                try serial.open(preferredPath: port)
                try Self.sendOffFrames(using: serial, frames: Int(round(offFrameRate)), frameRate: offFrameRate)
                serial.close()
            } catch {
                serial.close()
            }
        }
    }

    func stop() {
        generation += 1
        timer?.cancel()
        timer = nil
        queue.async { [serial] in
            serial.close()
        }
    }

    private func run(_ effect: Effect) {
        stop()
        startedAt = Date()
        generation += 1
        let currentGeneration = generation
        let port = selectedSerialPort

        let didOpenPort = queue.sync { [serial, port] in
            do {
                try serial.open(preferredPath: port)
                return true
            } catch {
                serial.close()
                return false
            }
        }
        guard didOpenPort else { return }

        let currentFrameRate = max(minimumFrameRate, min(maximumFrameRate, frameRate))
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: 1.0 / currentFrameRate)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            guard self.generation == currentGeneration else { return }
            do {
                let elapsed = Date().timeIntervalSince(self.startedAt)
                try self.serial.write(Self.frame(for: effect, elapsed: elapsed))
            } catch {
                self.stop()
            }
        }

        self.timer = timer
        timer.resume()
    }

    private static func sendOffFrames(using serial: SerialPort, frames: Int, frameRate: Double) throws {
        let frame = Self.frame(repeating: RGB(r: 0, g: 0, b: 0))
        let delay = useconds_t(round(1_000_000 / max(minimumFrameRate, min(maximumFrameRate, frameRate))))
        for _ in 0..<frames {
            try serial.write(frame)
            usleep(delay)
        }
    }

    private static func frame(for effect: Effect, elapsed: TimeInterval) -> [UInt8] {
        switch effect {
        case .color(let color):
            return frame(repeating: color)
        case .rainbow(let brightness, let speed):
            let pixels = (0..<ledCount).map { index in
                hsvToRGB(
                    hue: Double(index) / Double(ledCount) + elapsed * speed,
                    saturation: 1.0,
                    value: brightness
                )
            }
            return frame(pixels: pixels)
        case .flame(let brightness, let flicker, let speed, let intensity):
            var pixels: [RGB] = []
            pixels.reserveCapacity(ledCount)
            for index in 0..<ledCount {
                let x = Double(index) / Double(max(ledCount - 1, 1))
                let wave1 = 0.55 * sin((x * 9.0 + elapsed * speed * 2.3) * .pi * 2)
                let wave2 = 0.30 * sin((x * 17.0 - elapsed * speed * 3.7) * .pi * 2)
                let wave3 = 0.15 * sin((x * 31.0 + elapsed * speed * 5.1) * .pi * 2)
                let wave = wave1 + wave2 + wave3
                let animated = 0.5 + 0.5 * wave
                let base = 0.24 + intensity * 0.26
                let edgeFade = 0.78 + 0.22 * sin((x + elapsed * speed * 0.35) * .pi * 2)
                let heat = clamp((base + animated * flicker) * edgeFade, 0, 1)
                pixels.append(flameRGB(heat: heat, brightness: brightness))
            }
            return frame(pixels: pixels, calibrated: false)
        }
    }

    private static func frame(repeating color: RGB) -> [UInt8] {
        frame(pixels: Array(repeating: color, count: ledCount))
    }

    private static func frame(pixels: [RGB], calibrated: Bool = true) -> [UInt8] {
        var bytes: [UInt8] = [0x41, 0x64, 0x61, 0x00, UInt8((ledCount >> 8) & 0xff), UInt8(ledCount & 0xff)]
        bytes.reserveCapacity(6 + pixels.count * 3)
        for pixel in pixels {
            let output = calibrated ? calibrate(pixel) : pixel
            bytes.append(output.r)
            bytes.append(output.g)
            bytes.append(output.b)
        }
        return bytes
    }

    private static func calibrate(_ color: RGB) -> RGB {
        RGB(
            r: UInt8(clamp(round(Double(color.r) * redCalibration), 0, 255)),
            g: UInt8(clamp(round(Double(color.g) * greenCalibration), 0, 255)),
            b: UInt8(clamp(round(Double(color.b) * blueCalibration), 0, 255))
        )
    }

    private static func hsvToRGB(hue: Double, saturation: Double, value: Double) -> RGB {
        let normalizedHue = hue - floor(hue)
        let chroma = value * saturation
        let segment = normalizedHue * 6
        let x = chroma * (1 - abs(segment.truncatingRemainder(dividingBy: 2) - 1))

        let rgb: (Double, Double, Double)
        if segment < 1 {
            rgb = (chroma, x, 0)
        } else if segment < 2 {
            rgb = (x, chroma, 0)
        } else if segment < 3 {
            rgb = (0, chroma, x)
        } else if segment < 4 {
            rgb = (0, x, chroma)
        } else if segment < 5 {
            rgb = (x, 0, chroma)
        } else {
            rgb = (chroma, 0, x)
        }

        let match = value - chroma
        return RGB(
            r: UInt8(clamp(round((rgb.0 + match) * 255), 0, 255)),
            g: UInt8(clamp(round((rgb.1 + match) * 255), 0, 255)),
            b: UInt8(clamp(round((rgb.2 + match) * 255), 0, 255))
        )
    }

    private static func flameRGB(heat: Double, brightness: Double) -> RGB {
        let palette = [
            RGB(r: 20, g: 2, b: 0),
            RGB(r: 110, g: 14, b: 0),
            RGB(r: 220, g: 48, b: 0),
            RGB(r: 255, g: 105, b: 0),
            RGB(r: 255, g: 165, b: 18),
        ]
        let position = clamp(heat, 0, 1) * Double(palette.count - 1)
        let index = min(Int(position), palette.count - 2)
        let amount = position - Double(index)
        let color = mix(palette[index], palette[index + 1], amount)
        return RGB(
            r: UInt8(clamp(round(Double(color.r) * brightness), 0, 255)),
            g: UInt8(clamp(round(Double(color.g) * brightness), 0, 255)),
            b: UInt8(clamp(round(Double(color.b) * brightness), 0, 255))
        )
    }

    private static func mix(_ a: RGB, _ b: RGB, _ amount: Double) -> RGB {
        RGB(
            r: UInt8(round(Double(a.r) + (Double(b.r) - Double(a.r)) * amount)),
            g: UInt8(round(Double(a.g) + (Double(b.g) - Double(a.g)) * amount)),
            b: UInt8(round(Double(a.b) + (Double(b.b) - Double(a.b)) * amount))
        )
    }

    private static func clamp(_ value: Double, _ minimum: Double, _ maximum: Double) -> Double {
        max(minimum, min(maximum, value))
    }

}

private final class ControlPanelWindowController: NSWindowController {
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

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let controller = SkyDimoController()
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let menu = NSMenu()
    private var modeItems: [NSMenuItem] = []
    private var turnOffOnDisplaySleepItem: NSMenuItem?
    private var displaySleepTurnedOffStrip = false
    private lazy var controlPanel = ControlPanelWindowController(controller: controller) { [weak self] mode in
        self?.markAppliedMode(mode)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        configureStatusItem()
        buildMenu()
        observeDisplayPower()
        restoreLastPreset()
    }

    func applicationWillTerminate(_ notification: Notification) {
        controller.turnOffAndClose()
    }

    private func configureStatusItem() {
        guard let button = statusItem.button else { return }
        button.toolTip = "SkyDimo"

        if let image = NSImage(systemSymbolName: "flame.fill", accessibilityDescription: "SkyDimo") {
            image.isTemplate = true
            button.image = image
        } else {
            button.title = "SkyDimo"
        }
    }

    private func buildMenu() {
        menu.autoenablesItems = false

        let controlPanelItem = NSMenuItem(title: "Open Control Panel...", action: #selector(openControlPanel), keyEquivalent: "")
        controlPanelItem.target = self
        menu.addItem(controlPanelItem)

        menu.addItem(.separator())

        addSectionTitle("Static Colors")
        addModeItem(title: "Custom Color", action: #selector(customColor))
        addModeItem(title: "Candle", action: #selector(candle))
        addModeItem(title: "Amber", action: #selector(amber))
        addModeItem(title: "Warm White", action: #selector(warmWhite))
        addModeItem(title: "Neutral White", action: #selector(neutralWhite))
        addModeItem(title: "Red", action: #selector(red))

        menu.addItem(.separator())

        addSectionTitle("Animations")
        addModeItem(title: "Soft Flame", action: #selector(softFlame))
        addModeItem(title: "Rainbow", action: #selector(rainbow))

        menu.addItem(.separator())

        let offItem = NSMenuItem(title: "Off", action: #selector(off), keyEquivalent: "")
        offItem.target = self
        menu.addItem(offItem)

        let stopItem = NSMenuItem(title: "Stop Current Mode", action: #selector(stopCurrentMode), keyEquivalent: "")
        stopItem.target = self
        menu.addItem(stopItem)

        menu.addItem(.separator())

        let sleepItem = NSMenuItem(title: "Turn Off When Display Sleeps", action: #selector(toggleTurnOffOnDisplaySleep), keyEquivalent: "")
        sleepItem.target = self
        menu.addItem(sleepItem)
        turnOffOnDisplaySleepItem = sleepItem
        updateTurnOffOnDisplaySleepItem()

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "Quit SkyDimo", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu
    }

    private func addSectionTitle(_ title: String) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        menu.addItem(item)
    }

    private func addModeItem(title: String, action: Selector) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        menu.addItem(item)
        modeItems.append(item)
    }

    private func select(_ selected: NSMenuItem?) {
        for item in modeItems {
            item.state = item === selected ? .on : .off
        }
    }

    private func activeModeTitle() -> String? {
        modeItems.first(where: { $0.state == .on })?.title
    }

    private func observeDisplayPower() {
        let notificationCenter = NSWorkspace.shared.notificationCenter
        notificationCenter.addObserver(
            self,
            selector: #selector(displayDidSleep),
            name: NSWorkspace.screensDidSleepNotification,
            object: nil
        )
        notificationCenter.addObserver(
            self,
            selector: #selector(displayDidWake),
            name: NSWorkspace.screensDidWakeNotification,
            object: nil
        )
    }

    private func turnOffOnDisplaySleepEnabled() -> Bool {
        if UserDefaults.standard.object(forKey: turnOffOnDisplaySleepKey) == nil {
            return true
        }
        return UserDefaults.standard.bool(forKey: turnOffOnDisplaySleepKey)
    }

    private func updateTurnOffOnDisplaySleepItem() {
        turnOffOnDisplaySleepItem?.state = turnOffOnDisplaySleepEnabled() ? .on : .off
    }

    private func markAppliedMode(_ mode: String?) {
        guard let mode else {
            select(nil)
            UserDefaults.standard.removeObject(forKey: lastPresetKey)
            return
        }

        if let item = modeItems.first(where: { $0.title == mode }) {
            select(item)
            if mode == "Custom Color" {
                UserDefaults.standard.removeObject(forKey: lastPresetKey)
            } else {
                savePreset(mode)
            }
        } else {
            select(nil)
            UserDefaults.standard.removeObject(forKey: lastPresetKey)
        }
    }

    private func runColor(_ sender: NSMenuItem, hex: String) {
        select(sender)
        savePreset(sender.title)
        controller.runColor(parseColor(hex))
    }

    private func savePreset(_ title: String) {
        UserDefaults.standard.set(title, forKey: lastPresetKey)
    }

    private func restoreLastPreset() {
        let preset = UserDefaults.standard.string(forKey: lastPresetKey) ?? "Amber"
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            self?.applyPreset(named: preset)
        }
    }

    private func applyPreset(named preset: String) {
        guard let item = modeItems.first(where: { $0.title == preset }) else {
            applyPreset(named: "Amber")
            return
        }

        select(item)
        switch preset {
        case "Candle":
            controller.runColor(parseColor("#ffb347"))
        case "Amber":
            controller.runColor(parseColor("#ff9f2e"))
        case "Warm White":
            controller.runColor(parseColor("#ffc15c"))
        case "Neutral White":
            controller.runColor(parseColor("#ffe0a3"))
        case "Red":
            controller.runColor(parseColor("#ff0000"))
        case "Soft Flame":
            controller.runFlame(brightness: 1.0, flicker: 0.18, speed: 0.45)
        case "Rainbow":
            controller.runRainbow(brightness: 1.0, speed: 0.2)
        default:
            controller.runColor(parseColor("#ff9f2e"))
        }
    }

    @objc private func openControlPanel(_ sender: NSMenuItem) {
        controlPanel.show(activeMode: activeModeTitle())
    }

    @objc private func customColor(_ sender: NSMenuItem) {
        select(sender)
        UserDefaults.standard.removeObject(forKey: lastPresetKey)
        let color = parseColor(UserDefaults.standard.string(forKey: customColorHexKey) ?? defaultCustomColorHex)
        let brightness = savedCustomBrightness()
        controller.runColor(RGB(
            r: UInt8(max(0, min(255, round(Double(color.r) * brightness)))),
            g: UInt8(max(0, min(255, round(Double(color.g) * brightness)))),
            b: UInt8(max(0, min(255, round(Double(color.b) * brightness))))
        ))
    }

    @objc private func candle(_ sender: NSMenuItem) {
        runColor(sender, hex: "#ffb347")
    }

    @objc private func amber(_ sender: NSMenuItem) {
        runColor(sender, hex: "#ff9f2e")
    }

    @objc private func warmWhite(_ sender: NSMenuItem) {
        runColor(sender, hex: "#ffc15c")
    }

    @objc private func neutralWhite(_ sender: NSMenuItem) {
        runColor(sender, hex: "#ffe0a3")
    }

    @objc private func red(_ sender: NSMenuItem) {
        runColor(sender, hex: "#ff0000")
    }

    @objc private func softFlame(_ sender: NSMenuItem) {
        select(sender)
        savePreset(sender.title)
        controller.runFlame(brightness: 1.0, flicker: 0.18, speed: 0.45)
    }

    @objc private func rainbow(_ sender: NSMenuItem) {
        select(sender)
        savePreset(sender.title)
        controller.runRainbow(brightness: 1.0, speed: 0.2)
    }

    @objc private func off(_ sender: NSMenuItem) {
        select(nil)
        UserDefaults.standard.removeObject(forKey: lastPresetKey)
        controller.off()
    }

    @objc private func stopCurrentMode(_ sender: NSMenuItem) {
        select(nil)
        controller.stop()
    }

    @objc private func toggleTurnOffOnDisplaySleep(_ sender: NSMenuItem) {
        let enabled = !turnOffOnDisplaySleepEnabled()
        UserDefaults.standard.set(enabled, forKey: turnOffOnDisplaySleepKey)
        updateTurnOffOnDisplaySleepItem()
    }

    @objc private func displayDidSleep(_ notification: Notification) {
        guard turnOffOnDisplaySleepEnabled() else { return }
        displaySleepTurnedOffStrip = UserDefaults.standard.string(forKey: lastPresetKey) != nil
        controller.off()
    }

    @objc private func displayDidWake(_ notification: Notification) {
        guard turnOffOnDisplaySleepEnabled(), displaySleepTurnedOffStrip else { return }
        displaySleepTurnedOffStrip = false
        restoreLastPreset()
    }

    @objc private func quit(_ sender: NSMenuItem) {
        controller.turnOffAndClose()
        NSApp.terminate(nil)
    }

    private func parseColor(_ hex: String) -> RGB {
        parseRGB(hex)
    }

    private func savedCustomBrightness() -> Double {
        if UserDefaults.standard.object(forKey: customColorBrightnessKey) == nil {
            return defaultCustomColorBrightness
        }
        return max(0.05, min(1.0, UserDefaults.standard.double(forKey: customColorBrightnessKey)))
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
