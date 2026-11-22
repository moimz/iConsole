import Foundation
import Observation

/// 계정 목록과 그룹. 계정마다 StorageLocation.accounts/<UUID>.json, 그룹은 groups.json (iCloud Drive, 못 쓰면 이 맥).
/// 그룹 다루기는 iSQL ServerStore 와 같다: 그룹 없음이 맨 위, 그다음 groups 순서, 빈 그룹도 보인다
@Observable @MainActor
final class AccountStore {
	private(set) var accounts: [Account] = []
	private(set) var groups: [String] = []

	var isCloud: Bool { StorageLocation.shared.isCloud }
	private var dir: URL { StorageLocation.shared.accounts }

	private static let encoder: JSONEncoder = {
		let e = JSONEncoder()
		e.outputFormatting = [.prettyPrinted, .sortedKeys]
		return e
	}()

	init() {
		migrateOld()
		load()
	}

	/// 파일에서 다시 읽는다 (앱 시작, 다른 맥에서 바뀌었을 때)
	func load() {
		StorageLocation.shared.downloadAll()
		let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
		var loaded: [Account] = []
		for f in files where f.pathExtension == "json" {
			guard let d = StorageLocation.read(f), let a = try? JSONDecoder().decode(Account.self, from: d) else { continue }
			loaded.append(a)
		}
		// 아직 안 받은 파일의 계정은 지우지 않고 그대로 둔다
		let waiting = StorageLocation.shared.placeholderIDs()
		for a in accounts where waiting.contains(a.id) && !loaded.contains(where: { $0.id == a.id }) { loaded.append(a) }
		if loaded != accounts { accounts = loaded }
		if let d = StorageLocation.read(StorageLocation.shared.groups), let g = try? JSONDecoder().decode([String].self, from: d), g != groups {
			groups = g
		}
	}

	/// 빌드 7 까지: Application Support/iConsole/accounts.json 한 파일 (그 전 시험 앱은 UserDefaults "accounts") → 계정마다 파일로
	private func migrateOld() {
		let fm = FileManager.default
		let oldFile = StorageLocation.local.appendingPathComponent("accounts.json")
		let oldGroups = StorageLocation.local.appendingPathComponent("groups.json")
		var old: [Account] = []
		if let d = try? Data(contentsOf: oldFile), let a = try? JSONDecoder().decode([Account].self, from: d) {
			old = a
		} else if let d = UserDefaults.standard.data(forKey: "accounts"), let a = try? JSONDecoder().decode([Account].self, from: d) {
			old = a
		}
		for a in old {
			let f = file(a.id)
			if !fm.fileExists(atPath: f.path), let d = try? Self.encoder.encode(a) { StorageLocation.write(d, to: f) }
		}
		if let d = try? Data(contentsOf: oldGroups), !fm.fileExists(atPath: StorageLocation.shared.groups.path) {
			StorageLocation.write(d, to: StorageLocation.shared.groups)
		}
		// 옮긴 옛 파일은 백업으로 이름만 바꿔 둔다 (oldGroups 가 iCloud 를 못 쓸 때의 새 groups.json 과 같은 경로일 수 있어 그건 그대로)
		if !old.isEmpty {
			try? fm.moveItem(at: oldFile, to: StorageLocation.local.appendingPathComponent("accounts-moved.json"))
			UserDefaults.standard.removeObject(forKey: "accounts")
		}
	}

	private func file(_ id: UUID) -> URL { dir.appendingPathComponent(id.uuidString + ".json") }

	private func write(_ a: Account) {
		guard let d = try? Self.encoder.encode(a) else { return }
		StorageLocation.write(d, to: file(a.id))
	}

	func account(_ id: UUID?) -> Account? { accounts.first { $0.id == id } }

	var grouped: [(group: String, accounts: [Account])] {
		let byGroup = Dictionary(grouping: accounts, by: \.group)
		var names = groups
		for g in byGroup.keys.sorted() where !g.isEmpty && !names.contains(g) { names.append(g) }
		var out: [(String, [Account])] = []
		if let ungrouped = byGroup[""], !ungrouped.isEmpty { out.append(("", Self.sorted(ungrouped))) }
		for g in names { out.append((g, Self.sorted(byGroup[g] ?? []))) }
		return out
	}

	static func sorted(_ list: [Account]) -> [Account] {
		list.sorted { a, b in
			switch (a.order, b.order) {
			case let (x?, y?) where x != y: return x < y
			case (_?, nil): return true
			case (nil, _?): return false
			default: return a.name.localizedStandardCompare(b.name) == .orderedAscending
			}
		}
	}

	// MARK: 계정

	func save(_ a: Account, password: String? = nil, otp: String? = nil) {
		var a = a
		if let i = accounts.firstIndex(where: { $0.id == a.id }) {
			accounts[i] = a
		} else {
			a.order = (accounts.filter { $0.group == a.group }.compactMap(\.order).max() ?? -1) + 1
			accounts.append(a)
		}
		if let password { Keychain.set(a.passwordKey, password) }
		if let otp { Keychain.set(a.otpKey, otp) }
		if !a.group.isEmpty { addGroup(a.group) }
		write(a)
	}

	func delete(_ a: Account) {
		accounts.removeAll { $0.id == a.id }
		Keychain.delete(a.passwordKey)
		Keychain.delete(a.otpKey)
		StorageLocation.remove(file(a.id))
	}

	func update(_ id: UUID, _ change: (inout Account) -> Void) {
		guard let i = accounts.firstIndex(where: { $0.id == id }) else { return }
		change(&accounts[i])
		write(accounts[i])
	}

	/// 계정을 그 그룹의 target 앞으로 (target 이 nil 이면 그룹 맨 뒤). 그룹 안 순서를 다시 매긴다
	func moveAccount(_ id: UUID, toGroup group: String, before target: UUID?) {
		guard id != target, var moving = account(id) else { return }
		var list = Self.sorted(accounts.filter { $0.group == group && $0.id != id })
		moving.group = group
		if let target, let i = list.firstIndex(where: { $0.id == target }) { list.insert(moving, at: i) } else { list.append(moving) }
		for (i, a) in list.enumerated() {
			guard let j = accounts.firstIndex(where: { $0.id == a.id }) else { continue }
			if accounts[j].group != group || accounts[j].order != Double(i) {
				accounts[j].group = group
				accounts[j].order = Double(i)
				write(accounts[j])
			}
		}
	}

	/// iCloud 키체인을 쓸 수 있게 되면 이 맥에만 있던 암호·OTP 를 옮긴다
	func moveSecretsToCloud() {
		for a in accounts { Keychain.moveToCloud(a.passwordKey); Keychain.moveToCloud(a.otpKey) }
	}

	// MARK: 즐겨찾기

	func addFavorite(_ f: Favorite, to id: UUID) {
		update(id) { a in if !a.favorites.contains(where: { $0.url == f.url }) { a.favorites.append(f) } }
	}

	func removeFavorite(_ fid: UUID, from id: UUID) {
		update(id) { $0.favorites.removeAll { $0.id == fid } }
	}

	/// 즐겨찾기 막대에서 끌어 순서 바꾸기 (target 앞으로, nil 이면 맨 뒤)
	func moveFavorite(_ fid: UUID, before target: UUID?, in id: UUID) {
		update(id) { a in
			guard let i = a.favorites.firstIndex(where: { $0.id == fid }) else { return }
			let f = a.favorites.remove(at: i)
			if let target, let j = a.favorites.firstIndex(where: { $0.id == target }) { a.favorites.insert(f, at: j) } else { a.favorites.append(f) }
		}
	}

	/// 이름·주소 고치기
	func updateFavorite(_ f: Favorite, in id: UUID) {
		update(id) { a in if let i = a.favorites.firstIndex(where: { $0.id == f.id }) { a.favorites[i] = f } }
	}

	func renameFavorite(_ fid: UUID, in id: UUID, to title: String) {
		update(id) { a in if let i = a.favorites.firstIndex(where: { $0.id == fid }) { a.favorites[i].title = title } }
	}

	// MARK: 그룹

	func addGroup(_ name: String) {
		let n = name.trimmingCharacters(in: .whitespaces)
		guard !n.isEmpty else { return }
		syncGroupNames()
		if !groups.contains(n) { groups.append(n); saveGroups() }
	}

	/// 그룹을 지우고 그 안 계정은 그룹 없음으로 옮긴다
	func deleteGroup(_ name: String) {
		for i in accounts.indices where accounts[i].group == name { accounts[i].group = ""; write(accounts[i]) }
		groups.removeAll { $0 == name }
		saveGroups()
	}

	func renameGroup(_ old: String, to new: String) {
		let n = new.trimmingCharacters(in: .whitespaces)
		guard !n.isEmpty, n != old, !groups.contains(n) else { return }
		syncGroupNames()
		if let i = groups.firstIndex(of: old) { groups[i] = n }
		for i in accounts.indices where accounts[i].group == old { accounts[i].group = n; write(accounts[i]) }
		saveGroups()
	}

	/// 그룹을 다른 그룹 앞으로 (before 가 nil 이면 맨 뒤로)
	func moveGroup(_ name: String, before target: String?) {
		syncGroupNames()
		guard name != target, groups.contains(name) else { return }
		groups.removeAll { $0 == name }
		if let target, let i = groups.firstIndex(of: target) { groups.insert(name, at: i) } else { groups.append(name) }
		saveGroups()
	}

	private func syncGroupNames() {
		for g in Set(accounts.map(\.group)).sorted() where !g.isEmpty && !groups.contains(g) { groups.append(g) }
	}

	private func saveGroups() {
		guard let d = try? Self.encoder.encode(groups) else { return }
		StorageLocation.write(d, to: StorageLocation.shared.groups)
	}
}
