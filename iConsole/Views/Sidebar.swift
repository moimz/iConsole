import SwiftUI

/// 사이드바에서 고르는 것
enum SidebarItem: Hashable {
	case account(UUID)
	case favorite(UUID, UUID)
}

/// 계정 목록 (내가 만든 그룹별, iSQL 서버 목록과 같은 모양).
/// 계정을 누르면 그 계정의 탭들로 바뀌고, 즐겨찾기가 있으면 꺾쇠로 펼쳐 즐겨찾기를 본다.
/// 계정을 끌어 그룹을 옮기거나 순서를 바꾸고, 그룹 머리를 끌어 그룹 순서를 바꾼다
struct Sidebar: View {
	@Environment(AppModel.self) private var model
	let edit: (Account) -> Void
	let addAccount: () -> Void
	let addGroup: () -> Void
	@State private var selection: SidebarItem?
	@State private var deleting: Account?
	@State private var deletingGroup: String?
	@State private var renamingGroup: String?
	@State private var renamingFavorite: (account: UUID, favorite: Favorite)?
	@State private var newName = ""

	private var store: AccountStore { model.store }

	var body: some View {
		List(selection: $selection) {
			ForEach(store.grouped, id: \.group) { g in
				Section {
					ForEach(g.accounts) { a in
						accountTree(a)
					}
					.onInsert(of: [.utf8PlainText, .plainText]) { index, providers in
						insert(providers, group: g.group, accounts: g.accounts, at: index)
					}
					if g.accounts.isEmpty {
						Text("계정을 여기로 끌어 놓으세요").font(.caption).foregroundStyle(.tertiary)
							.frame(maxWidth: .infinity, minHeight: 24, alignment: .leading)
							.dropDestination(for: String.self) { items, _ in
								guard case .account(let id)? = items.first.flatMap(DragItem.init) else { return false }
								store.moveAccount(id, toGroup: g.group, before: nil)
								return true
							}
					}
				} header: {
					GroupHeader(name: g.group, count: g.accounts.count)
						.draggable(DragItem.group(g.group)) {
							DragGhost { Label(g.group.isEmpty ? "그룹 없음" : g.group, systemImage: "folder").fontWeight(.semibold) }
						}
						.contextMenu {
							if !g.group.isEmpty {
								Button("그룹 이름 바꾸기…") { newName = g.group; renamingGroup = g.group }
								Button("그룹 삭제…", role: .destructive) { deletingGroup = g.group }
							}
						}
				}
			}
		}
		.overlay {
			if store.accounts.isEmpty {
				ContentUnavailableView {
					Label("계정 없음", systemImage: "person.crop.circle.badge.plus")
				} description: {
					Text("+ 로 아마존·구글·애플 계정을 추가하세요")
				}
			}
		}
		// 목록 끝을 흐리게 가리는 막대 + 유리 알약 (iSQL)
		.safeAreaBar(edge: .bottom) {
			HStack {
				SyncStatus(isCloud: store.isCloud)
					.padding(.horizontal, 10).padding(.vertical, 6)
					.glassEffect(.regular, in: Capsule())
				Spacer(minLength: 0)
			}
			.padding(10)
		}
		.onAppear { selection = model.currentID.map(SidebarItem.account) }
		.onChange(of: model.currentID) { _, id in
			if let id, selection != .account(id) { selection = .account(id) }
		}
		.onChange(of: selection) { _, item in
			switch item {
			case .account(let id)?:
				model.select(id)
			case .favorite(let a, let f)?:
				if let fav = store.account(a)?.favorites.first(where: { $0.id == f }) { model.open(fav, of: a) }
				// 즐겨찾기는 누르는 단추처럼: 고른 표시는 계정 줄로 돌린다 (같은 즐겨찾기를 다시 눌러도 열리게)
				selection = .account(a)
			case nil:
				break
			}
		}
		.toolbar {
			ToolbarItem {
				Menu {
					Button("계정 추가…", action: addAccount)
					Button("그룹 추가…", action: addGroup)
				} label: {
					Label("추가", systemImage: "plus")
				}
				.menuIndicator(.hidden)
				.help("계정 추가 / 그룹 추가")
			}
		}
		.confirmationDialog("‘\(deleting?.name ?? "")’ 계정을 삭제할까요?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
			Button("삭제", role: .destructive) {
				if let d = deleting { model.delete(d) }
				deleting = nil
			}
		} message: {
			Text("저장한 암호·OTP 와 이 계정의 로그인(웹 데이터), 열린 탭, 즐겨찾기도 지웁니다.")
		}
		.confirmationDialog("‘\(deletingGroup ?? "")’ 그룹을 삭제할까요?", isPresented: Binding(get: { deletingGroup != nil }, set: { if !$0 { deletingGroup = nil } })) {
			Button("삭제", role: .destructive) {
				if let g = deletingGroup { store.deleteGroup(g) }
				deletingGroup = nil
			}
		} message: {
			Text("그룹 안 계정은 삭제하지 않고 그룹 없음으로 옮깁니다.")
		}
		.sheet(isPresented: Binding(get: { renamingGroup != nil }, set: { if !$0 { renamingGroup = nil } })) {
			NameSheet(title: "그룹 이름 바꾸기", name: $newName, taken: { n in n != renamingGroup && store.groups.contains(n) }) {
				if let g = renamingGroup { store.renameGroup(g, to: newName) }
			}
		}
		.sheet(isPresented: Binding(get: { renamingFavorite != nil }, set: { if !$0 { renamingFavorite = nil } })) {
			NameSheet(title: "즐겨찾기 이름 바꾸기", name: $newName, taken: { _ in false }) {
				if let r = renamingFavorite { store.renameFavorite(r.favorite.id, in: r.account, to: newName) }
			}
		}
	}

	/// 계정 줄. 즐겨찾기가 있으면 꺾쇠로 펼친다
	@ViewBuilder
	private func accountTree(_ a: Account) -> some View {
		Group {
			if a.favorites.isEmpty {
				accountRow(a)
			} else {
				DisclosureGroup(isExpanded: Binding(get: { model.expanded.contains(a.id) },
				                                    set: { if $0 { model.expanded.insert(a.id) } else { model.expanded.remove(a.id) } })) {
					ForEach(a.favorites) { f in
						FavoriteRow(favorite: f)
							.tag(SidebarItem.favorite(a.id, f.id))
							.contextMenu {
								Button("이름 바꾸기…") { newName = f.title; renamingFavorite = (a.id, f) }
								Button("주소 복사") {
									NSPasteboard.general.clearContents()
									NSPasteboard.general.setString(f.url, forType: .string)
								}
								Divider()
								Button("즐겨찾기에서 빼기", role: .destructive) { store.removeFavorite(f.id, from: a.id) }
							}
					}
				} label: {
					accountRow(a)
				}
			}
		}
	}

	private func accountRow(_ a: Account) -> some View {
		AccountRow(account: a, open: model.sessions[a.id] != nil)
			.tag(SidebarItem.account(a.id))
			.draggable(DragItem.account(a.id)) { DragGhost { AccountRow(account: a, open: false) } }
			.contextMenu {
				Button("수정…") { edit(a) }
				Menu("그룹으로 옮기기") {
					Button("그룹 없음") { store.moveAccount(a.id, toGroup: "", before: nil) }.disabled(a.group.isEmpty)
					ForEach(store.grouped.map(\.group).filter { !$0.isEmpty }, id: \.self) { g in
						Button(g) { store.moveAccount(a.id, toGroup: g, before: nil) }.disabled(a.group == g)
					}
				}
				Button("로그인 지우기 (웹 데이터)") { Task { await model.clearWebData(a) } }
				Divider()
				Button("삭제…", role: .destructive) { deleting = a }
			}
	}

	/// 삽입선 자리에 놓았을 때 (iSQL 서버 목록과 같다)
	private func insert(_ providers: [NSItemProvider], group: String, accounts: [Account], at index: Int) {
		guard let p = providers.first else { return }
		_ = p.loadTransferable(type: String.self) { result in
			guard case .success(let text) = result else { return }
			DispatchQueue.main.async {
				guard let item = DragItem(text) else { return }
				switch item {
				case .account(let id):
					store.moveAccount(id, toGroup: group, before: index < accounts.count ? accounts[index].id : nil)
				case .group(let name):
					guard !name.isEmpty else { return }
					if index == 0 && !group.isEmpty {
						store.moveGroup(name, before: group)
					} else {
						let order = store.grouped.map(\.group).filter { !$0.isEmpty && $0 != name }
						let next = group.isEmpty ? order.first : order.firstIndex(of: group).flatMap { $0 + 1 < order.count ? order[$0 + 1] : nil }
						store.moveGroup(name, before: next)
					}
				}
			}
		}
	}
}

/// 사이드바에서 끄는 것 (문자열로 주고받는다)
enum DragItem {
	case account(UUID)
	case group(String)

	init?(_ s: String) {
		if s.hasPrefix("iconsole-account:"), let id = UUID(uuidString: String(s.dropFirst(17))) { self = .account(id) }
		else if s.hasPrefix("iconsole-group:") { self = .group(String(s.dropFirst(15))) }
		else { return nil }
	}

	static func account(_ id: UUID) -> String { "iconsole-account:" + id.uuidString }
	static func group(_ name: String) -> String { "iconsole-group:" + name }
}

/// 끌 때 커서에 붙는 그림: 창 바탕색 둥근 상자 + 테두리 (iSQL)
struct DragGhost<Content: View>: View {
	@ViewBuilder var content: Content
	var body: some View {
		content
			.padding(.horizontal, 10).padding(.vertical, 6)
			.frame(width: 240, alignment: .leading)
			.background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
			.overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.accentColor.opacity(0.6)))
	}
}

struct GroupHeader: View {
	let name: String
	let count: Int
	var body: some View {
		HStack {
			Text(name.isEmpty ? "그룹 없음" : name)
			Spacer()
			Text("\(count)")
				.font(.system(size: 11, weight: .medium))
				.monospacedDigit()
				.foregroundStyle(.secondary)
				.padding(.horizontal, 6).padding(.vertical, 1)
				.background(Capsule().fill(Color.secondary.opacity(0.15)))
				.padding(.trailing, 8)
		}
		.contentShape(Rectangle())
	}
}

/// 계정 줄: [서비스 아이콘] 이름 / 아이디 (iSQL 서버 줄 모양)
struct AccountRow: View {
	let account: Account
	/// 이 앱을 켠 뒤 열어 본 계정 (탭이 살아 있음)
	var open = false
	var body: some View {
		HStack(spacing: 9) {
			ServiceIcon(kind: account.kind, size: 30)
			VStack(alignment: .leading, spacing: 1) {
				Text(account.name).lineLimit(1)
				Text(account.username).font(.caption).foregroundStyle(.secondary).lineLimit(1)
			}
			if open {
				Spacer(minLength: 4)
				Circle().fill(Color.green).frame(width: 6, height: 6).help("열려 있는 계정")
			}
		}
		.padding(.vertical, 2)
	}
}

struct FavoriteRow: View {
	let favorite: Favorite
	var body: some View {
		Label {
			VStack(alignment: .leading, spacing: 0) {
				Text(favorite.title).lineLimit(1)
				Text(URL(string: favorite.url)?.host() ?? favorite.url).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
			}
		} icon: {
			Image(systemName: "star.fill").foregroundStyle(.yellow).font(.system(size: 11))
		}
		.help(favorite.url)
	}
}

/// 서비스 아이콘: 둥근 정사각형을 서비스 색으로 칠하고 흰 기호
struct ServiceIcon: View {
	let kind: Account.Kind
	var size: CGFloat = 30

	private var color: Color {
		switch kind {
		case .aws: Color(red: 0.95, green: 0.55, blue: 0.10)
		case .google: Color(red: 0.26, green: 0.52, blue: 0.96)
		case .apple: Color(white: 0.35)
		}
	}

	var body: some View {
		RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
			.fill(color)
			.frame(width: size, height: size)
			.overlay {
				switch kind {
				case .aws: Image(systemName: "cloud.fill").font(.system(size: size * 0.46, weight: .semibold))
				case .google: Text("G").font(.system(size: size * 0.55, weight: .bold, design: .rounded))
				case .apple: Image(systemName: "apple.logo").font(.system(size: size * 0.5, weight: .semibold))
				}
			}
			.foregroundStyle(.white)
	}
}

/// 사이드바 아래: iCloud 동기화 여부 한 줄 (계정 목록과 키체인 둘 다 iCloud 여야 동기화)
struct SyncStatus: View {
	let isCloud: Bool
	var body: some View {
		let synced = isCloud && Keychain.mode != .localOnly
		Label(synced ? "iCloud 동기화" : "이 맥에만 저장", systemImage: synced ? "checkmark.icloud" : "icloud.slash")
			.font(.caption)
			.foregroundStyle(synced ? Color.secondary : Color.orange)
			.help(synced ? "계정 목록·그룹·즐겨찾기와 암호·OTP(키체인)가 iCloud 로 다른 맥과 동기화됩니다. 로그인(쿠키)·열린 탭은 맥마다 따로입니다."
			             : (isCloud ? "암호·OTP 가 이 맥 키체인에만 저장됩니다" : "계정 목록이 이 맥에만 저장됩니다 (iCloud Drive 를 켜 주세요)"))
	}
}

/// 이름 하나만 받는 시트 (그룹 추가·이름 바꾸기, 즐겨찾기 이름 바꾸기)
struct NameSheet: View {
	let title: String
	@Binding var name: String
	let taken: (String) -> Bool
	let done: () -> Void
	@Environment(\.dismiss) private var dismiss
	@FocusState private var focused: Bool

	private var trimmed: String { name.trimmingCharacters(in: .whitespaces) }

	var body: some View {
		VStack(alignment: .leading, spacing: 14) {
			Text(title).font(.headline)
			TextField("이름", text: $name, prompt: Text("개인, 회사 같은 이름"))
				.textFieldStyle(.roundedBorder)
				.focused($focused)
				.onSubmit(ok)
			if taken(trimmed) { Text("이미 있는 이름입니다.").font(.caption).foregroundStyle(.orange) }
			HStack {
				Spacer()
				Button("취소", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
				Button("확인", action: ok)
					.keyboardShortcut(.defaultAction)
					.buttonStyle(.borderedProminent)
					.disabled(trimmed.isEmpty || taken(trimmed))
			}
			.controlSize(.large)
		}
		.padding(20)
		.frame(width: 340)
		.onAppear { focused = true }
	}

	private func ok() {
		guard !trimmed.isEmpty, !taken(trimmed) else { return }
		name = trimmed
		done()
		dismiss()
	}
}
