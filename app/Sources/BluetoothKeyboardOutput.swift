import Darwin
import Foundation

struct BluetoothKeyboardDelivery {
    let port: String
    let byteCount: Int
    let completion: String
}

enum BluetoothKeyboardError: Error, CustomStringConvertible {
    case message(String)

    var description: String {
        switch self {
        case let .message(message):
            return message
        }
    }
}

final class BluetoothKeyboardOutput: @unchecked Sendable {
    private let config: BluetoothKeyboardConfig
    private let queue = DispatchQueue(label: "fluid-push-to-talk.bluetooth-keyboard", qos: .userInitiated)
    private var serialPort: ESP32KeyboardSerialPort?

    init(config: BluetoothKeyboardConfig) {
        self.config = config
    }

    func send(_ text: String) async throws -> BluetoothKeyboardDelivery {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    let port = try self.serialPort ?? ESP32KeyboardSerialPort.open(configuredPath: self.config.resolvedPort)
                    self.serialPort = port
                    let completion = try port.sendText(text, chunkSize: self.config.chunkSize)
                    continuation.resume(
                        returning: BluetoothKeyboardDelivery(
                            port: port.path,
                            byteCount: text.utf8.count,
                            completion: completion
                        )
                    )
                } catch {
                    self.serialPort?.close()
                    self.serialPort = nil
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}

private final class ESP32KeyboardSerialPort {
    private static let protocolName = "KBD1"
    private static let baudRate = speed_t(B115200)
    private static let crc32Table: [UInt32] = (0..<256).map { value in
        var crc = UInt32(value)
        for _ in 0..<8 {
            crc = (crc & 1) == 1 ? (crc >> 1) ^ 0xEDB88320 : crc >> 1
        }
        return crc
    }

    let path: String
    private var fileDescriptor: Int32
    private var readBuffer = Data()

    private init(path: String, fileDescriptor: Int32) {
        self.path = path
        self.fileDescriptor = fileDescriptor
    }

    deinit {
        close()
    }

    static func open(configuredPath: String?) throws -> ESP32KeyboardSerialPort {
        let path = try configuredPath ?? findPort()
        let fileDescriptor = path.withCString {
            Darwin.open($0, O_RDWR | O_NOCTTY | O_NONBLOCK)
        }
        guard fileDescriptor >= 0 else {
            throw failure("failed to open serial port \(path)")
        }

        guard flock(fileDescriptor, LOCK_EX | LOCK_NB) == 0 else {
            Darwin.close(fileDescriptor)
            throw BluetoothKeyboardError.message("serial port is already in use: \(path)")
        }

        do {
            try configure(fileDescriptor: fileDescriptor, path: path)
            return ESP32KeyboardSerialPort(path: path, fileDescriptor: fileDescriptor)
        } catch {
            flock(fileDescriptor, LOCK_UN)
            Darwin.close(fileDescriptor)
            throw error
        }
    }

    func close() {
        guard fileDescriptor >= 0 else {
            return
        }
        flock(fileDescriptor, LOCK_UN)
        Darwin.close(fileDescriptor)
        fileDescriptor = -1
    }

    func sendText(_ text: String, chunkSize: Int) throws -> String {
        guard fileDescriptor >= 0 else {
            throw BluetoothKeyboardError.message("serial port is closed")
        }
        guard (1...256).contains(chunkSize) else {
            throw BluetoothKeyboardError.message("bluetooth_keyboard.chunk_size must be between 1 and 256")
        }

        let payload = Data(text.utf8)
        guard !payload.isEmpty else {
            throw BluetoothKeyboardError.message("cannot send empty text through the Bluetooth keyboard")
        }

        let status = try parseFields(command("STATUS"), prefix: "STATUS")
        guard status["connected"] == "1" else {
            throw BluetoothKeyboardError.message(
                "ESP32 Bluetooth keyboard is not connected (bonded=\(status["bonded"] ?? "unknown"), pairing=\(status["pairing"] ?? "unknown"))"
            )
        }
        guard status["busy"] != "1" else {
            throw BluetoothKeyboardError.message("ESP32 Bluetooth keyboard is already typing")
        }
        if let maximumText = status["max_bytes"].flatMap(Int.init), payload.count > maximumText {
            throw BluetoothKeyboardError.message(
                "Bluetooth keyboard payload has \(payload.count) bytes; firmware maximum is \(maximumText)"
            )
        }

        let checksum = Self.crc32(payload)
        try writeASCII(
            "\(Self.protocolName) TYPE_CHUNKED \(payload.count) \(String(format: "%08x", checksum)) \(chunkSize)\n"
        )
        try requireResponse(protocolLine(timeout: 5), prefix: "READY ")

        for offset in stride(from: 0, to: payload.count, by: chunkSize) {
            let end = min(offset + chunkSize, payload.count)
            try writeData(payload.subdata(in: offset..<end))
            try requireResponse(protocolLine(timeout: 5), prefix: "RECEIVED ")
        }

        try requireResponse(protocolLine(timeout: 5), prefix: "QUEUED ")
        let completionTimeout = max(15, Double(text.count) * 0.08)
        let completion = try protocolLine(timeout: completionTimeout)
        try requireResponse(completion, prefix: "DONE ")
        return completion
    }

    private func command(_ command: String, timeout: TimeInterval = 3) throws -> String {
        try writeASCII("\(Self.protocolName) \(command)\n")
        return try protocolLine(timeout: timeout)
    }

    private func protocolLine(timeout: TimeInterval) throws -> String {
        let deadline = DispatchTime.now().uptimeNanoseconds + UInt64(timeout * 1_000_000_000)
        while true {
            let now = DispatchTime.now().uptimeNanoseconds
            guard now < deadline else {
                break
            }
            if let newline = readBuffer.firstIndex(of: 10) {
                var lineData = readBuffer[..<newline]
                readBuffer.removeSubrange(...newline)
                if lineData.last == 13 {
                    lineData = lineData.dropLast()
                }
                let line = String(decoding: lineData, as: UTF8.self)
                let prefix = Self.protocolName + " "
                if line.hasPrefix(prefix) {
                    return String(line.dropFirst(prefix.count))
                }
                continue
            }

            let remaining = deadline - now
            guard try waitFor(events: Int16(POLLIN), timeoutNanoseconds: min(remaining, 250_000_000)) else {
                continue
            }

            var bytes = [UInt8](repeating: 0, count: 4096)
            let count = bytes.withUnsafeMutableBytes {
                Darwin.read(fileDescriptor, $0.baseAddress, $0.count)
            }
            if count > 0 {
                readBuffer.append(bytes, count: count)
            } else if count < 0, errno != EAGAIN, errno != EINTR {
                throw Self.failure("failed reading from \(path)")
            }
        }
        throw BluetoothKeyboardError.message("timed out waiting for an ESP32 firmware response")
    }

    private func writeASCII(_ text: String) throws {
        guard let data = text.data(using: .ascii) else {
            throw BluetoothKeyboardError.message("failed to encode ESP32 protocol command")
        }
        try writeData(data)
    }

    private func writeData(_ data: Data) throws {
        try data.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else {
                return
            }
            var offset = 0
            while offset < rawBuffer.count {
                guard try waitFor(events: Int16(POLLOUT), timeoutNanoseconds: 2_000_000_000) else {
                    throw BluetoothKeyboardError.message("timed out writing to the ESP32")
                }
                let count = Darwin.write(
                    fileDescriptor,
                    baseAddress.advanced(by: offset),
                    rawBuffer.count - offset
                )
                if count > 0 {
                    offset += count
                } else if count < 0, errno != EAGAIN, errno != EINTR {
                    throw Self.failure("failed writing to \(path)")
                }
            }
        }
    }

    private func waitFor(events: Int16, timeoutNanoseconds: UInt64) throws -> Bool {
        var descriptor = pollfd(fd: fileDescriptor, events: events, revents: 0)
        let timeoutMilliseconds = Int32(max(1, min(timeoutNanoseconds / 1_000_000, UInt64(Int32.max))))
        while true {
            let result = Darwin.poll(&descriptor, 1, timeoutMilliseconds)
            if result > 0 {
                if descriptor.revents & Int16(POLLERR | POLLHUP | POLLNVAL) != 0 {
                    throw BluetoothKeyboardError.message("serial port disconnected: \(path)")
                }
                return descriptor.revents & events != 0
            }
            if result == 0 {
                return false
            }
            if errno != EINTR {
                throw Self.failure("failed polling \(path)")
            }
        }
    }

    private static func configure(fileDescriptor: Int32, path: String) throws {
        var attributes = termios()
        guard tcgetattr(fileDescriptor, &attributes) == 0 else {
            throw failure("failed to read serial settings for \(path)")
        }
        cfmakeraw(&attributes)
        attributes.c_cflag &= ~tcflag_t(CSIZE | PARENB | CSTOPB)
        attributes.c_cflag |= tcflag_t(CLOCAL | CREAD | CS8)
        guard cfsetspeed(&attributes, baudRate) == 0 else {
            throw failure("failed to set serial speed for \(path)")
        }
        withUnsafeMutableBytes(of: &attributes.c_cc) { controlCharacters in
            controlCharacters[Int(VMIN)] = 0
            controlCharacters[Int(VTIME)] = 1
        }
        guard tcsetattr(fileDescriptor, TCSANOW, &attributes) == 0 else {
            throw failure("failed to configure serial port \(path)")
        }
        guard tcflush(fileDescriptor, TCIFLUSH) == 0 else {
            throw failure("failed to flush serial port \(path)")
        }
    }

    private static func findPort() throws -> String {
        let names = try FileManager.default.contentsOfDirectory(atPath: "/dev")
        let paths = names
            .filter { $0.hasPrefix("cu.usbmodem") || $0.hasPrefix("cu.usbserial") }
            .map { "/dev/\($0)" }
            .sorted()
        guard !paths.isEmpty else {
            throw BluetoothKeyboardError.message(
                "no USB serial port found; set bluetooth_keyboard.port explicitly"
            )
        }
        guard paths.count == 1 else {
            throw BluetoothKeyboardError.message(
                "multiple USB serial ports found; set bluetooth_keyboard.port explicitly: \(paths.joined(separator: ", "))"
            )
        }
        return paths[0]
    }

    private static func crc32(_ data: Data) -> UInt32 {
        var crc = UInt32.max
        for byte in data {
            crc = (crc >> 8) ^ crc32Table[Int((crc ^ UInt32(byte)) & 0xFF)]
        }
        return crc ^ UInt32.max
    }

    private func parseFields(_ line: String, prefix: String) throws -> [String: String] {
        guard line.hasPrefix(prefix + " ") else {
            throw BluetoothKeyboardError.message("unexpected ESP32 firmware response: \(line)")
        }
        return line.split(separator: " ").dropFirst().reduce(into: [:]) { fields, field in
            let parts = field.split(separator: "=", maxSplits: 1)
            if parts.count == 2 {
                fields[String(parts[0])] = String(parts[1])
            }
        }
    }

    private func requireResponse(_ line: String, prefix: String) throws {
        if line.hasPrefix("ERROR ") {
            throw BluetoothKeyboardError.message("ESP32 firmware error: \(line)")
        }
        guard line.hasPrefix(prefix) else {
            throw BluetoothKeyboardError.message("unexpected ESP32 firmware response: \(line)")
        }
    }

    private static func failure(_ message: String) -> BluetoothKeyboardError {
        BluetoothKeyboardError.message("\(message): \(String(cString: strerror(errno)))")
    }
}
