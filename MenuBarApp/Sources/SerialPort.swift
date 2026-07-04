import Darwin
import Foundation

final class SerialPort {
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

    static func portCandidates() -> [String] {
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
