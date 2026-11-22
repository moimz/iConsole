import Foundation
import Observation

/// 계정 목록과 그룹. ~/Library/Application Support/iConsole/accounts.json · groups.json (iCloud 동기화는 나중)
/// 그룹 다루기는 iSQL ServerStore 와 같다: 그룹 없음이 맨 위, 그다음 groups 순서, 빈 그룹도 보인다
@Observable @MainActor
final class AccountStore {
	private(set) var accounts: [Account] = []
	private(set) var groups: [String] = []

	private static let dir: URL = {
		let d = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("iConsole", isDirectory: true)
		try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
		return d
	}()
	private static var accountsFile: URL { dir.appendingPathComponent("accounts.json") }
	private static var groupsFile: URL { dir.appendingPathComponent("groups.json") }

	init() {
		if let d = try? Data(contentsOf: Self.accountsFile), let a = try? JSONDecoder().decode([Account].self, from: d) {
			accounts = a
		} else if let d = UserDefaults.standard.data(forKey: "accounts"), let a = try? JSONDecoder().decode([Account].self, from: d) {
			// 시험 앱이 UserDefaults 에 둔 계정을 옮겨 온다 (키체인·웹 저장소는 같은 계정 id 그대로)
			accounts = a
			saveAccounts()
		}
		if let d = try? Data(contentsOf: Self.groupsFile), let g = try? JSONDecoder().decode([String].self, from: d) { groups = g }
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
		saveAccounts()
	}

	func delete(_ a: Account) {
		accounts.removeAll { $0.id == a.id }
		Keychain.set(a.passwordKey, nil)
		Keychain.set(a.otpKey, nil)
		saveAccounts()
	}

	func update(_ id: UUID, _ change: (inout Account) -> Void) {
		guard let i = accounts.firstIndex(where: { $0.id == id }) else { return }
		change(&accounts[i])
		saveAccounts()
	}

	/// 계정을 그 그룹의 target 앞으로 (target 이 nil 이면 그룹 맨 뒤). 그룹 안 순서를 다시 매긴다
	func moveAccount(_ id: UUID, toGroup group: String, before target: UUID?) {
		guard id != target, var moving = account(id) else { return }
		var list = Self.sorted(accounts.filter { $0.group == group && $0.id != id })
		moving.group = group
		if let target, let i = list.firstIndex(where: { $0.id == target }) { list.insert(moving, at: i) } else { list.append(moving) }
		for (i, a) in list.enumerated() {
			guard let j = accounts.firstIndex(where: { $0.id == a.id }) else { continue }
			accounts[j].group = group
			accounts[j].order = Double(i)
		}
		saveAccounts()
	}

	// MARK: 즐겨찾기

	func addFavorite(_ f: Favorite, to id: UUID) {
		update(id) { a in if !a.favorites.contains(where: { $0.url == f.url }) { a.favorites.append(f) } }
	}

	func removeFavorite(_ fid: UUID, from id: UUID) {
		update(id) { $0.favorites.removeAll { $0.id == fid } }
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
		for i in accounts.indices where accounts[i].group == name { accounts[i].group = "" }
		groups.removeAll { $0 == name }
		saveAccounts()
		saveGroups()
	}

	func renameGroup(_ old: String, to new: String) {
		let n = new.trimmingCharacters(in: .whitespaces)
		guard !n.isEmpty, n != old, !groups.contains(n) else { return }
		syncGroupNames()
		if let i = groups.firstIndex(of: old) { groups[i] = n }
		for i in accounts.indices where accounts[i].group == old { accounts[i].group = n }
		saveAccounts()
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

	// MARK: 저장

	private func saveAccounts() {
		let e = JSONEncoder()
		e.outputFormatting = [.prettyPrinted, .sortedKeys]
		try? e.encode(accounts).write(to: Self.accountsFile, options: .atomic)
	}

	private func saveGroups() {
		try? JSONEncoder().encode(groups).write(to: Self.groupsFile, options: .atomic)
	}
}
