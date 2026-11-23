import Foundation
import AppKit
import AuthenticationServices
import Observation

/// Safari · Chrome 자동 완성 (iConsoleCredentials 확장) 을 켜고 끄기 — 부작용 시험용으로 설정에서 직접 켠다 (사용자 2026-11-23).
/// 켜면: 계정마다 로그인 도메인 · 아이디를 시스템 자동 완성 목록(ASCredentialIdentityStore)에 올리고, 확장이 읽을 목록을 키체인(이 맥만)에 쓴다.
/// 끄면: 둘 다 지운다 → 확장은 아무것도 내주지 않는다 (시스템 설정에서 iConsole 을 켜 둬도 그대로).
/// 시스템 설정의 "자동 완성 및 암호 > 자동 완성 제공 앱" 에서 iConsole 이 켜져 있어야 실제로 쓰인다 (그건 사용자가 켠다)
@Observable @MainActor
final class Autofill {
	static let shared = Autofill()
	@ObservationIgnored weak var model: AppModel?

	var enabled = UserDefaults.standard.bool(forKey: "autofill.enabled") {
		didSet {
			UserDefaults.standard.set(enabled, forKey: "autofill.enabled")
			Task { await sync() }
		}
	}
	/// 시스템 설정에서 iConsole 자동 완성 확장이 켜져 있는지
	private(set) var systemEnabled = false

	/// 확장이 읽는 목록의 한 줄 (확장의 Entry 와 같은 모양)
	struct Entry: Codable {
		let id: String
		let name: String
		let user: String
		let hosts: [String]
	}

	func refreshState() async {
		systemEnabled = await ASCredentialIdentityStore.shared.state().isEnabled
	}

	/// 계정 목록이 바뀌었거나 켜고 끌 때
	func sync() async {
		await refreshState()
		let store = ASCredentialIdentityStore.shared
		guard enabled, let accounts = model?.store.accounts else {
			try? await store.removeAllCredentialIdentities()
			Keychain.setLocal("autofill.index", nil)
			return
		}
		var entries: [Entry] = []
		var identities: [any ASCredentialIdentity] = []
		for a in accounts where Keychain.get(a.passwordKey) != nil {
			var hosts = a.loginHosts
			if let h = a.home.host()?.lowercased(), !hosts.contains(h) { hosts.append(h) }
			entries.append(Entry(id: a.id.uuidString, name: a.name, user: a.username, hosts: hosts))
			for h in hosts {
				identities.append(ASPasswordCredentialIdentity(serviceIdentifier: ASCredentialServiceIdentifier(identifier: h, type: .domain),
				                                                user: a.username, recordIdentifier: a.id.uuidString))
			}
		}
		Keychain.setLocal("autofill.index", try? JSONEncoder().encode(entries))
		if await store.state().isEnabled {
			try? await store.replaceCredentialIdentities(identities)
		}
		model?.log("자동 완성 목록: 계정 \(entries.count)개 · 도메인 \(identities.count)개")
	}

	/// 시스템 설정의 자동 완성 제공 앱 화면 열기
	func openSettings() {
		ASSettingsHelper.openCredentialProviderAppSettings { _ in }
	}
}

extension ASCredentialIdentityStore {
	/// async 로 상태 읽기
	func state() async -> ASCredentialIdentityStoreState {
		await withCheckedContinuation { c in getState { c.resume(returning: $0) } }
	}
}
