import Foundation
import CryptoKit

// otpauth://totp?secret=…&algorithm=SHA1&digits=6&period=30 또는 비밀 값(base32)만
struct TOTP {
	let secret: Data
	let digits: Int
	let period: Int
	let algorithm: String

	init?(_ text: String) {
		let s = text.trimmingCharacters(in: .whitespacesAndNewlines)
		var q: [String: String] = [:]
		if s.lowercased().hasPrefix("otpauth://") {
			guard let c = URLComponents(string: s) else { return nil }
			for i in c.queryItems ?? [] { q[i.name.lowercased()] = i.value ?? "" }
		} else {
			q["secret"] = s
		}
		guard let sec = q["secret"].flatMap(Self.base32), !sec.isEmpty else { return nil }
		secret = sec
		digits = Int(q["digits"] ?? "") ?? 6
		period = max(1, Int(q["period"] ?? "") ?? 30)
		algorithm = (q["algorithm"] ?? "SHA1").uppercased()
	}

	func code(at date: Date = Date()) -> String {
		var counter = (UInt64(date.timeIntervalSince1970) / UInt64(period)).bigEndian
		let msg = withUnsafeBytes(of: &counter) { Data($0) }
		let key = SymmetricKey(data: secret)
		let mac: [UInt8]
		switch algorithm {
		case "SHA256": mac = Array(HMAC<SHA256>.authenticationCode(for: msg, using: key))
		case "SHA512": mac = Array(HMAC<SHA512>.authenticationCode(for: msg, using: key))
		default: mac = Array(HMAC<Insecure.SHA1>.authenticationCode(for: msg, using: key))
		}
		let o = Int(mac[mac.count - 1] & 0x0f)
		let v = (UInt32(mac[o] & 0x7f) << 24) | (UInt32(mac[o + 1]) << 16) | (UInt32(mac[o + 2]) << 8) | UInt32(mac[o + 3])
		var m: UInt32 = 1
		for _ in 0..<digits { m *= 10 }
		let n = String(v % m)
		return String(repeating: "0", count: max(0, digits - n.count)) + n
	}

	func remaining(at date: Date = Date()) -> Int { period - Int(date.timeIntervalSince1970) % period }

	static func base32(_ s: String) -> Data? {
		let alpha = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567")
		var bits = 0, value = 0
		var out = Data()
		for ch in s.uppercased() where ch != "=" && ch != " " && ch != "-" {
			guard let i = alpha.firstIndex(of: ch) else { return nil }
			value = (value << 5) | i
			bits += 5
			if bits >= 8 {
				out.append(UInt8((value >> (bits - 8)) & 0xff))
				bits -= 8
				value &= (1 << bits) - 1
			}
		}
		return out
	}
}
