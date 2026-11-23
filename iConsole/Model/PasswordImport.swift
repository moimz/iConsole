import Foundation
import AppKit
import AuthenticationServices
import Observation

/// 암호 앱 "선택한 항목을 앱으로 내보내기" → iConsole (자격 증명 교환, macOS 26).
/// 시스템이 iConsole 을 ASCredentialExchangeActivity 로 열고 userInfo[ASCredentialImportToken] 을 주면,
/// ASCredentialImportManager 로 받아 가져오기 시트(ImportSheet)에 항목마다 어느 계정에 넣을지 보인다.
/// 넣는 것: 아이디 · 암호 · OTP. 패스키는 받아 두기만 한다(키체인 "<계정>.passkey.<id>", 웹뷰에서 쓰는 건 나중)
@Observable @MainActor
final class PasswordImport {
	static let shared = PasswordImport()
	@ObservationIgnored weak var model: AppModel?

	/// 받은 항목 (시트가 보인다)
	var items: [Candidate] = []
	var error: String?

	/// 가져올 항목 하나
	struct Candidate: Identifiable {
		let id = UUID()
		var title: String
		var urls: [URL]
		var username: String
		var password: String?
		/// otpauth:// 주소
		var otp: String?
		var passkeys: [ASImportableCredential.Passkey]
		/// 넣을 곳: nil = 건너뛰기, .new = 새 계정, .account(id)
		var target: Target

		enum Target: Hashable {
			case skip
			case new
			case account(UUID)
		}

		var host: String? { urls.first?.host()?.lowercased() }
	}

	/// 시스템이 넘겨준 토큰으로 받아 온다
	func receive(token: UUID) async {
		do {
			let data = try await ASCredentialImportManager().importCredentials(token: token)
			let list = data.accounts.flatMap(\.items).compactMap(candidate)
			model?.log("암호 앱에서 \(list.count)개 받음 (\(data.exporterDisplayName))")
			items = list
			NSApp.activate(ignoringOtherApps: true)
		} catch {
			self.error = error.localizedDescription
			model?.log("암호 앱 가져오기 실패: \(error.localizedDescription)")
		}
	}

	private func candidate(_ item: ASImportableItem) -> Candidate? {
		var user = "", pass: String?, otp: String?, keys: [ASImportableCredential.Passkey] = []
		for c in item.credentials {
			switch c {
			case .basicAuthentication(let b):
				if let u = b.userName?.value, !u.isEmpty { user = u }
				if let p = b.password?.value, !p.isEmpty { pass = p }
			case .totp(let t):
				otp = Self.otpauth(t)
				if user.isEmpty, let u = t.userName { user = u }
			case .passkey(let p):
				keys.append(p)
				if user.isEmpty { user = p.userName }
			default:
				break
			}
		}
		guard pass != nil || otp != nil || !keys.isEmpty else { return nil }
		let urls = item.scope?.urls ?? []
		var c = Candidate(title: item.title, urls: urls, username: user, password: pass, otp: otp, passkeys: keys, target: .new)
		c.target = guess(c)
		return c
	}

	/// 같은 아이디 · 같은 도메인의 계정이 있으면 그 계정, 없으면 새 계정
	private func guess(_ c: Candidate) -> Candidate.Target {
		guard let accounts = model?.store.accounts, let h = c.host else { return .new }
		let same = accounts.first { a in
			a.username.caseInsensitiveCompare(c.username) == .orderedSame &&
			(a.loginHosts + [a.home.host()?.lowercased() ?? ""]).contains { !$0.isEmpty && (h == $0 || h.hasSuffix("." + $0) || $0.hasSuffix("." + h)) }
		}
		return same.map { .account($0.id) } ?? .new
	}

	/// 고른 대로 넣는다
	func apply() {
		guard let store = model?.store else { return }
		var done = 0
		for c in items {
			let id: UUID
			switch c.target {
			case .skip:
				continue
			case .account(let a):
				guard var acc = store.account(a) else { continue }
				if acc.username.isEmpty { acc.username = c.username }
				store.save(acc, password: c.password, otp: c.otp)
				id = a
			case .new:
				let kind = Self.kind(for: c.host)
				var acc = Account(kind: kind, name: c.title.isEmpty ? (c.host ?? kind.title) : c.title, username: c.username)
				if kind == .custom, let u = c.urls.first { acc.start = u.absoluteString }
				store.save(acc, password: c.password ?? "", otp: c.otp ?? "")
				id = acc.id
			}
			for p in c.passkeys {
				if let d = try? JSONEncoder().encode(p) { Keychain.set("\(id.uuidString).passkey.\(p.credentialID.base64EncodedString())", String(decoding: d, as: UTF8.self)) }
			}
			done += 1
		}
		model?.log("암호 앱에서 \(done)개 넣음")
		items = []
		Task { await Autofill.shared.sync() }
	}

	/// 도메인으로 계정 종류 짐작 (모르면 사용자 정의)
	static func kind(for host: String?) -> Account.Kind {
		guard let h = host else { return .custom }
		if h.hasSuffix("amazon.com") || h.hasSuffix("aws.amazon.com") { return .aws }
		if h.hasSuffix("google.com") { return .google }
		if h.hasSuffix("apple.com") { return .apple }
		if h.hasSuffix("cloudflare.com") { return .cloudflare }
		return .custom
	}

	/// 받은 TOTP → otpauth 주소
	static func otpauth(_ t: ASImportableCredential.TOTP) -> String {
		var c = URLComponents()
		c.scheme = "otpauth"
		c.host = "totp"
		let label = [t.issuer, t.userName].compactMap { $0 }.joined(separator: ":")
		c.path = "/" + label
		c.queryItems = [
			URLQueryItem(name: "secret", value: base32(t.secret)),
			URLQueryItem(name: "algorithm", value: t.algorithm.rawValue.uppercased()),
			URLQueryItem(name: "digits", value: String(t.digits)),
			URLQueryItem(name: "period", value: String(t.period)),
		] + (t.issuer.map { [URLQueryItem(name: "issuer", value: $0)] } ?? [])
		return c.url?.absoluteString ?? ""
	}

	static func base32(_ data: Data) -> String {
		let alpha = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567")
		var out = "", buffer = 0, bits = 0
		for b in data {
			buffer = (buffer << 8) | Int(b)
			bits += 8
			while bits >= 5 {
				out.append(alpha[(buffer >> (bits - 5)) & 31])
				bits -= 5
			}
			buffer &= (1 << bits) - 1
		}
		if bits > 0 { out.append(alpha[(buffer << (5 - bits)) & 31]) }
		return out
	}
}
