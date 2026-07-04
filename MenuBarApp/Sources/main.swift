import AppKit
import Foundation

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
