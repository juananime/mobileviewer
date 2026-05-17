import Darwin
import Foundation

final class CommandServer {
    let port: UInt16
    let onDone: () -> Void
    private var serverFd: Int32 = -1

    init(port: UInt16, onDone: @escaping () -> Void) {
        self.port = port
        self.onDone = onDone
    }

    func start() throws {
        serverFd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard serverFd >= 0 else { throw Err("socket: \(errno)") }

        var yes: Int32 = 1
        Darwin.setsockopt(serverFd, SOL_SOCKET, SO_REUSEADDR, &yes,
                          socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        memset(&addr, 0, MemoryLayout.size(ofValue: addr))
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = INADDR_ANY

        let bindOk = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(serverFd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindOk == 0 else { throw Err("bind port \(port): \(errno)") }
        guard Darwin.listen(serverFd, 5) == 0 else { throw Err("listen: \(errno)") }

        DispatchQueue.global(qos: .userInitiated).async { self.acceptLoop() }
    }

    private func acceptLoop() {
        while true {
            var ca = sockaddr_in()
            var caLen = socklen_t(MemoryLayout<sockaddr_in>.size)
            let clientFd = withUnsafeMutablePointer(to: &ca) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.accept(serverFd, $0, &caLen)
                }
            }
            guard clientFd >= 0 else { return }
            DispatchQueue.global(qos: .userInitiated).async {
                self.handleClient(fd: clientFd)
            }
        }
    }

    private func handleClient(fd: Int32) {
        defer { Darwin.close(fd) }
        while true {
            guard let line = recvLine(fd), !line.isEmpty else { return }
            let response = Handlers.handle(line: line)
            guard sendLine(fd, response) else { return }
            // Check for quit after responding so the client gets the ack
            if isQuit(line) { onDone(); return }
        }
    }

    private func recvLine(_ fd: Int32) -> String? {
        var result = ""
        var byte: UInt8 = 0
        while true {
            let n = Darwin.recv(fd, &byte, 1, 0)
            if n <= 0 { return n == 0 ? result : nil }
            if byte == UInt8(ascii: "\n") { return result }
            result.append(Character(UnicodeScalar(byte)))
        }
    }

    private func sendLine(_ fd: Int32, _ line: String) -> Bool {
        let data = Data((line + "\n").utf8)
        return data.withUnsafeBytes { ptr in
            Darwin.send(fd, ptr.baseAddress!, data.count, 0) == data.count
        }
    }

    private func isQuit(_ line: String) -> Bool {
        guard let data = line.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return false }
        return (json["type"] as? String) == "quit"
    }
}

struct Err: Error, LocalizedError {
    let msg: String
    init(_ msg: String) { self.msg = msg }
    var errorDescription: String? { msg }
}
