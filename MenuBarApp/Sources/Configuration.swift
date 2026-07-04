import AppKit
import Darwin
import Foundation

let ledCount = 65
let defaultFrameRate = 80.0
let minimumFrameRate = 10.0
let maximumFrameRate = 120.0
let lastPresetKey = "lastPreset"
let selectedSerialPortKey = "selectedSerialPort"
let automaticSerialPortValue = "auto"
let customColorHexKey = "customColorHex"
let customColorBrightnessKey = "customColorBrightness"
let defaultCustomColorHex = "#ffb347"
let defaultCustomColorBrightness = 1.0
let turnOffOnDisplaySleepKey = "turnOffOnDisplaySleep"
let redCalibration = 1.0
let greenCalibration = 0.72
let blueCalibration = 0.25
let serialPortPrefixes = [
    "cu.usbserial",
    "cu.wchusbserial",
    "cu.SLAB_USBtoUART",
    "cu.usbmodem",
]

struct RGB {
    let r: UInt8
    let g: UInt8
    let b: UInt8
}

func parseRGB(_ hex: String) -> RGB {
    let trimmed = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
    let value = UInt32(trimmed, radix: 16) ?? 0
    return RGB(
        r: UInt8((value >> 16) & 0xff),
        g: UInt8((value >> 8) & 0xff),
        b: UInt8(value & 0xff)
    )
}
