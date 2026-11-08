import Foundation

/// BSD 소켓으로 UDP 브로드캐스트를 보내고 응답을 모은다 (Network.framework는 브로드캐스트 수신이 번거롭다).
/// iOS 에서는 `com.apple.developer.networking.multicast` 권한이 필요하다.
public enum UDPBroadcaster {
    /// 로컬 인터페이스의 서브넷 브로드캐스트 주소 (공유기가 255.255.255.255 를 막는 경우 대비).
    public static func localBroadcastAddresses() -> [String] {
        var out: [String] = []
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return out }
        defer { freeifaddrs(ifaddr) }
        var p: UnsafeMutablePointer<ifaddrs>? = first
        while let cur = p {
            let flags = Int32(cur.pointee.ifa_flags)
            if let sa = cur.pointee.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET), (flags & IFF_UP) != 0, (flags & IFF_LOOPBACK) == 0, (flags & IFF_BROADCAST) != 0,
               let bsa = cur.pointee.ifa_dstaddr {
                var b = bsa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee }
                let str = String(cString: inet_ntoa(b.sin_addr))
                if str != "0.0.0.0", !out.contains(str) { out.append(str) }
                _ = b.sin_port
            }
            p = cur.pointee.ifa_next
        }
        return out
    }

    public static func broadcastAndCollect(payload: [UInt8], port: Int, timeoutSeconds: Double, broadcastAddress: String = "255.255.255.255") -> [(host: String, bytes: [UInt8])] {
        var results: [(String, [UInt8])] = []
        let fd = socket(AF_INET, SOCK_DGRAM, 0)
        guard fd >= 0 else { return results }
        defer { close(fd) }
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_BROADCAST, &yes, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        var tv = timeval(tv_sec: Int(timeoutSeconds), tv_usec: Int32((timeoutSeconds - Double(Int(timeoutSeconds))) * 1_000_000))
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        var dest = sockaddr_in()
        dest.sin_family = sa_family_t(AF_INET)
        dest.sin_port = in_port_t(UInt16(port).bigEndian)
        dest.sin_addr.s_addr = inet_addr(broadcastAddress)
        let sent = payload.withUnsafeBufferPointer { buf in
            withUnsafePointer(to: &dest) { p in
                p.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    sendto(fd, buf.baseAddress, buf.count, 0, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
        guard sent >= 0 else { return results }

        let deadline = Date().addingTimeInterval(timeoutSeconds)
        var buffer = [UInt8](repeating: 0, count: 4096)
        while Date() < deadline {
            var from = sockaddr_in()
            var fromLen = socklen_t(MemoryLayout<sockaddr_in>.size)
            let n = buffer.withUnsafeMutableBufferPointer { buf in
                withUnsafeMutablePointer(to: &from) { p in
                    p.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                        recvfrom(fd, buf.baseAddress, buf.count, 0, sa, &fromLen)
                    }
                }
            }
            if n <= 0 { break }
            let host = String(cString: inet_ntoa(from.sin_addr))
            results.append((host, Array(buffer[0..<Int(n)])))
        }
        return results
    }
}
