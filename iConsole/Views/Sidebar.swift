import SwiftUI

/// 사이드바에서 고르는 것
enum SidebarItem: Hashable {
	case account(UUID)
}

/// 계정 목록 (내가 만든 그룹별, iSQL 서버 목록과 같은 모양).
/// 계정을 누르면 그 계정의 탭들로 바뀐다. 즐겨찾기는 사이드바가 아니라 탭 줄 위 즐겨찾기 막대에 (사용자 2026-11-23: 사이드바에 주렁주렁 달리는 게 별로).
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
	@State private var newName = ""
	@State private var searchText = ""
	@FocusState private var searchFocused: Bool

	private var store: AccountStore { model.store }

	/// 검색어(띄어 쓴 낱말 모두)가 이름·아이디·그룹·서비스·시작 주소에 들어 있는 계정만. 찾는 동안 빈 그룹은 숨긴다 (iSQL)
	private var shown: [(group: String, accounts: [Account])] {
		let words = searchText.lowercased().split(separator: " ").map(String.init)
		guard !words.isEmpty else { return store.grouped }
		return store.grouped.compactMap { g in
			let list = g.accounts.filter { a in
				let hay = [a.name, a.username, a.group, a.kind.title, a.kind.rawValue, a.start ?? ""].joined(separator: " ").lowercased()
				return words.allSatisfy { hay.contains($0) }
			}
			return list.isEmpty ? nil : (g.group, list)
		}
	}

	var body: some View {
		VStack(spacing: 0) {
		SidebarSearchField(text: $searchText, prompt: "이름, 아이디, 그룹 검색", focused: $searchFocused)
		List(selection: $selection) {
			ForEach(shown, id: \.group) { g in
				Section {
					ForEach(g.accounts) { a in
						accountRow(a)
					}
					.onInsert(of: [.utf8PlainText, .plainText]) { index, providers in
						insert(providers, group: g.group, accounts: g.accounts, at: index)
					}
					if g.accounts.isEmpty && searchText.isEmpty {
						Text("계정을 여기로 끌어 놓으세요").font(.caption).foregroundStyle(.tertiary)
							.frame(maxWidth: .infinity, minHeight: 24, alignment: .leading)
							.dropDestination(for: String.self) { items, _ in
								guard case .account(let id)? = items.first.flatMap(DragItem.init) else { return false }
								store.moveAccount(id, toGroup: g.group, before: nil)
								return true
							}
					}
				} header: {
					GroupHeader(name: g.group)
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
			if !searchText.isEmpty && shown.isEmpty {
				ContentUnavailableView.search(text: searchText)
			} else if store.accounts.isEmpty {
				ContentUnavailableView {
					Label("계정 없음", systemImage: "person.crop.circle.badge.plus")
				} description: {
					Text("+ 로 아마존·구글·애플 계정을 추가하세요")
				}
			}
		}
		}
		// ⌥⌘F 로 검색칸 (⌘F 는 나중에 페이지 찾기에 남겨 둔다)
		.background { Button("") { searchFocused = true }.keyboardShortcut("f", modifiers: [.command, .option]).hidden() }
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
	}

	private func accountRow(_ a: Account) -> some View {
		AccountRow(account: a, openTabs: model.sessions[a.id]?.tabs.count ?? 0)
			.tag(SidebarItem.account(a.id))
			.draggable(DragItem.account(a.id)) { DragGhost { AccountRow(account: a) } }
			.contextMenu {
				Button("수정…") { edit(a) }
				Menu("그룹으로 옮기기") {
					Button("그룹 없음") { store.moveAccount(a.id, toGroup: "", before: nil) }.disabled(a.group.isEmpty)
					ForEach(store.grouped.map(\.group).filter { !$0.isEmpty }, id: \.self) { g in
						Button(g) { store.moveAccount(a.id, toGroup: g, before: nil) }.disabled(a.group == g)
					}
				}
				if let t = Keychain.get(a.otpKey).flatMap(TOTP.init) {
					Button("OTP 코드 복사") { copyToPasteboard(t.code()) }
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

/// 그룹 머리: 이름만 (개수 알약은 뺐다, 사용자 2026-11-23)
struct GroupHeader: View {
	let name: String
	var body: some View {
		Text(name.isEmpty ? "그룹 없음" : name)
			.frame(maxWidth: .infinity, alignment: .leading)
			.contentShape(Rectangle())
	}
}

/// 계정 줄: [서비스 아이콘] 이름 / 아이디 (iSQL 서버 줄 모양)
struct AccountRow: View {
	let account: Account
	/// 이 앱을 켠 뒤 열어 본 계정의 열린 탭 수 (0 이면 안 보인다)
	var openTabs = 0
	var body: some View {
		HStack(spacing: 9) {
			ServiceIcon(kind: account.kind, home: account.home, size: 30)
			VStack(alignment: .leading, spacing: 1) {
				Text(account.name).lineLimit(1)
				Text(account.username).font(.caption).foregroundStyle(.secondary).lineLimit(1)
			}
			// iSQL 서버 줄의 "접속 중" 자리·모양에 열린 탭 수만
			if openTabs > 0 {
				Spacer(minLength: 4)
				Text("\(openTabs)").font(.caption2).monospacedDigit()
					.padding(.horizontal, 6).padding(.vertical, 2)
					.background(Capsule().fill(Color.green.opacity(0.2))).foregroundStyle(.green)
					.help("열린 탭 \(openTabs)개")
			}
		}
		.padding(.vertical, 2)
	}
}

/// 서비스 아이콘: 서비스 대표색 둥근 정사각형 + 흰 단색 로고 (Simple Icons, CC0 — 사용자 2026-11-23).
/// 예전엔 파란 바탕에 글자 "G" 라 구글 같지 않았다. 아마존은 Simple Icons 에서 빠져 있어(아마존 요청) 대표색에 글자 "aws".
/// 사용자 정의는 메인 페이지의 사이트 아이콘(못 받았으면 지구본)
struct ServiceIcon: View {
	let kind: Account.Kind
	/// 사용자 정의 계정의 메인 페이지
	var home: URL? = nil
	var size: CGFloat = 30

	private var color: Color {
		switch kind {
		case .aws: Color(red: 1.0, green: 0.6, blue: 0.0)                // #FF9900
		case .google: Color(red: 0.259, green: 0.522, blue: 0.957)       // #4285F4
		case .apple: Color.black                                         // #000000
		case .cloudflare: Color(red: 0.953, green: 0.502, blue: 0.125)   // #F38020
		case .custom: Color(white: 0.45)
		}
	}

	private var logo: String? {
		switch kind {
		case .google: "ServiceGoogle"
		case .apple: "ServiceApple"
		case .cloudflare: "ServiceCloudflare"
		case .aws, .custom: nil
		}
	}

	var body: some View {
		if kind == .custom, let img = Favicons.shared.image(for: home) {
			RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
				.fill(Color.white)
				.frame(width: size, height: size)
				.overlay { Image(nsImage: img).resizable().interpolation(.high).scaledToFit().frame(width: size * 0.66, height: size * 0.66) }
		} else {
			RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
				.fill(color)
				.frame(width: size, height: size)
				// 검정(애플) 타일이 어두운 사이드바에 묻히지 않게 옅은 테두리
				.overlay { RoundedRectangle(cornerRadius: size * 0.24, style: .continuous).strokeBorder(Color.white.opacity(kind == .apple ? 0.18 : 0), lineWidth: 1) }
				.overlay {
					if let logo {
						Image(logo).renderingMode(.template).resizable().scaledToFit().frame(width: size * 0.56, height: size * 0.56)
					} else if kind == .aws {
						Text("aws").font(.system(size: size * 0.36, weight: .heavy, design: .rounded)).offset(y: -size * 0.02)
					} else {
						Image(systemName: "globe").font(.system(size: size * 0.5, weight: .semibold))
					}
				}
				.foregroundStyle(.white)
		}
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

/// 사이드바 위 검색칸 (iSQL Views/TableViews.swift 의 SidebarSearchField 그대로)
struct SidebarSearchField: View {
	@Binding var text: String
	let prompt: String
	var focused: FocusState<Bool>.Binding

	var body: some View {
		HStack(spacing: 6) {
			Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
			TextField(prompt, text: $text)
				.textFieldStyle(.plain)
				.focused(focused)
			if !text.isEmpty {
				Button { text = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
					.buttonStyle(.plain)
			}
		}
		.padding(.horizontal, 10)
		.frame(height: 32)
		.background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor)))
		.overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.secondary.opacity(0.2)))
		.padding(.horizontal, 10)
		.padding(.vertical, 8)
	}
}

func copyToPasteboard(_ s: String) {
	NSPasteboard.general.clearContents()
	NSPasteboard.general.setString(s, forType: .string)
}

/// OTP 코드: 애플 암호처럼 남은 시간 동그라미 + "137 530". 누르면 클립보드로 (잠깐 "복사됨")
struct OTPCodeView: View {
	let totp: TOTP
	@State private var copiedAt: Date?

	var body: some View {
		TimelineView(.periodic(from: .now, by: 1)) { ctx in
			let code = totp.code(at: ctx.date)
			let left = Double(totp.remaining(at: ctx.date))
			HStack(spacing: 8) {
				ZStack {
					Circle().stroke(Color.secondary.opacity(0.25), lineWidth: 2.5)
					Circle().trim(from: 0, to: left / Double(totp.period))
						.stroke(left <= 5 ? Color.orange : Color.green, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
						.rotationEffect(.degrees(-90))
						.animation(.linear(duration: 1), value: left)
				}
				.frame(width: 16, height: 16)
				if let c = copiedAt, ctx.date.timeIntervalSince(c) < 1.5 {
					Text("복사됨").foregroundStyle(.secondary)
				} else {
					Text(Self.spaced(code)).font(.system(.body, design: .monospaced).weight(.semibold))
				}
			}
			.contentShape(Rectangle())
			.onTapGesture {
				copyToPasteboard(totp.code())
				copiedAt = Date()
			}
			.help("눌러서 복사")
		}
	}

	/// 가운데를 띄운다 (6자리 → 3 3)
	static func spaced(_ code: String) -> String {
		guard code.count >= 6 else { return code }
		let mid = code.index(code.startIndex, offsetBy: code.count / 2)
		return code[..<mid] + " " + code[mid...]
	}
}
