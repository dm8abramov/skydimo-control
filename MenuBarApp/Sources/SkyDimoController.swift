import Darwin
import Foundation

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

    func runColor(_ color: RGB) {
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
