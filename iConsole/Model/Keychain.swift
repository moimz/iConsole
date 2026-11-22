import Foundation
import Security

/// 암호·OTP 는 여기에만 둔다 (계정 파일에는 한 글자도 쓰지 않는다).
/// iCloud 키체인(동기화 항목, 접근 그룹 XSDBV8D2XL.com.moimz.iConsole)에 넣어 다른 맥에서도 다시 넣을 필요가 없게 한다.
/// iCloud 키체인을 못 쓰면(서명 없이 돌릴 때 등) 이 맥 로그인 키체인에 넣고 화면에 보여 준다 (iSQL Model/Keychain.swift 와 같음)
enum Keychain {
	static let service = "com.moimz.iConsole"

	enum Mode { case unknown, iCloud, localOnly }
	/// 마지막으로 쓴 방식 (화면 표시용)
	nonisolated(unsafe) static var mode: Mode = .unknown

	private static func base(_ key: String, cloud: Bool) -> [String: Any] {
		var q: [String: Any] = [
			kSecClass as String: kSecClassGenericPassword,
			kSecAttrService as String: service,
			kSecAttrAccount as String: key,
		]
		if cloud {
			q[kSecUseDataProtectionKeychain as String] = true
			q[kSecAttrSynchronizable as String] = true
		}
		return q
	}

	static func get(_ key: String) -> String? {
		for cloud in [true, false] {
			if let v = read(key, cloud: cloud) { return v }
		}
		return nil
	}

	private static func read(_ key: String, cloud: Bool) -> String? {
		var q = base(key, cloud: cloud)
		if cloud { q[kSecAttrSynchronizable as String] = kSecAttrSynchronizableAny }
		q[kSecReturnData as String] = true
		q[kSecMatchLimit as String] = kSecMatchLimitOne
		var out: CFTypeRef?
		guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
		return String(data: d, encoding: .utf8)
	}

	/// nil 이나 빈 문자열이면 지운다
	static func set(_ key: String, _ value: String?) {
		guard let value, !value.isEmpty else { delete(key); return }
		let data = Data(value.utf8)
		if write(data, key, cloud: true) {
			mode = .iCloud
			// 예전에 이 맥에만 넣어 둔 것이 있으면 지운다 (두 곳에 남지 않게)
			SecItemDelete(base(key, cloud: false) as CFDictionary)
			return
		}
		if write(data, key, cloud: false) { mode = .localOnly }
	}

	private static func write(_ data: Data, _ key: String, cloud: Bool) -> Bool {
		let q = base(key, cloud: cloud)
		let status = SecItemUpdate(q as CFDictionary, [kSecValueData as String: data] as CFDictionary)
		if status == errSecSuccess { return true }
		if status != errSecItemNotFound { return false }
		var add = q
		add[kSecValueData as String] = data
		add[kSecAttrLabel as String] = "iConsole"
		if cloud { add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock }
		return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
	}

	static func delete(_ key: String) {
		var q = base(key, cloud: true)
		q[kSecAttrSynchronizable as String] = kSecAttrSynchronizableAny
		SecItemDelete(q as CFDictionary)
		SecItemDelete(base(key, cloud: false) as CFDictionary)
	}

	/// 이 맥 로그인 키체인에만 있는 것을 iCloud 키체인으로 옮긴다 (빌드 7 까지는 로그인 키체인에 넣었다)
	static func moveToCloud(_ key: String) {
		guard mode == .iCloud, read(key, cloud: true) == nil, let v = read(key, cloud: false) else { return }
		set(key, v)
	}

	/// iCloud 키체인을 쓸 수 있는지 시험 삼아 한 번 써 본다 (앱 시작 때)
	static func probe() {
		let key = "probe"
		if write(Data("1".utf8), key, cloud: true) {
			mode = .iCloud
			var q = base(key, cloud: true)
			q[kSecAttrSynchronizable as String] = kSecAttrSynchronizableAny
			SecItemDelete(q as CFDictionary)
		} else {
			mode = .localOnly
		}
	}
}
