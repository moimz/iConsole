import SwiftUI

struct ContentView: View {
	@Environment(AppModel.self) private var model
	@State private var editing: Account?
	@State private var adding = false
	@State private var addingGroup = false
	@State private var groupName = ""

	var body: some View {
		NavigationSplitView {
			Sidebar(edit: { editing = $0 }, addAccount: { adding = true },
			        addGroup: { groupName = ""; addingGroup = true })
				.navigationSplitViewColumnWidth(min: 200, ideal: 250, max: 360)
		} detail: {
			if let s = model.current {
				BrowserPane(session: s)
					.id(s.accountID)
			} else {
				ContentUnavailableView {
					Label("iConsole", systemImage: "rectangle.stack.badge.person.crop")
				} description: {
					Text(model.store.accounts.isEmpty ? "+ 로 계정을 추가하세요" : "왼쪽에서 계정을 고르세요")
				} actions: {
					if model.store.accounts.isEmpty { Button("계정 추가…") { adding = true }.buttonStyle(.borderedProminent) }
				}
			}
		}
		.toolbar(removing: .title)
		.sheet(isPresented: $adding) {
			AccountForm(account: nil) { a, p, o in
				model.store.save(a, password: p, otp: o)
				model.select(a.id)
			}
		}
		.sheet(item: $editing) { a in
			AccountForm(account: a) { a, p, o in model.store.save(a, password: p, otp: o) }
		}
		.sheet(isPresented: $addingGroup) {
			NameSheet(title: "그룹 추가", name: $groupName, taken: { model.store.groups.contains($0) }) {
				model.store.addGroup(groupName)
			}
		}
		.sheet(item: Binding(get: { model.favoriteDraft }, set: { model.favoriteDraft = $0 })) { d in
			FavoriteSheet(draft: d)
		}
		.onReceive(NotificationCenter.default.publisher(for: .addAccount)) { _ in adding = true }
	}
}

extension Notification.Name {
	static let addAccount = Notification.Name("iConsole.addAccount")
}

/// 계정 추가·수정. 암호와 OTP 는 저장할 때 키체인으로 간다
struct AccountForm: View {
	@Environment(AppModel.self) private var model
	let account: Account?
	let onSave: (Account, String, String) -> Void
	@Environment(\.dismiss) private var dismiss
	@State private var kind = Account.Kind.aws
	@State private var name = ""
	@State private var username = ""
	@State private var password = ""
	@State private var otp = ""
	@State private var start = ""
	@State private var group = ""

	var body: some View {
		VStack(spacing: 0) {
			Form {
				Picker("종류", selection: $kind) {
					ForEach(Account.Kind.allCases, id: \.self) { Text($0.title).tag($0) }
				}
				.pickerStyle(.segmented)
				TextField("이름", text: $name, prompt: Text("예: AWS 개인 루트"))
				Picker("그룹", selection: $group) {
					Text("그룹 없음").tag("")
					ForEach(model.store.grouped.map(\.group).filter { !$0.isEmpty }, id: \.self) { Text($0).tag($0) }
				}
				Section {
					TextField("아이디", text: $username, prompt: Text(kind == .aws ? "루트 계정 이메일" : "계정 이메일"))
					SecureField("암호", text: $password)
					SecureField("OTP", text: $otp, prompt: Text("otpauth://totp?secret=… 또는 비밀 값"))
					LabeledContent("지금 코드") {
						if otp.isEmpty {
							Text("없음").foregroundStyle(.secondary)
						} else if let t = TOTP(otp) {
							OTPCodeView(totp: t)
						} else {
							Text("형식 오류").foregroundStyle(.red)
						}
					}
				} footer: {
					Text(kind == .apple ? "애플 계정 2단계 코드는 TOTP 가 아니라 채우지 않습니다 (문자로 받으면 macOS 가 채워 줍니다)."
					     : "암호와 OTP 는 iCloud 키체인에 저장합니다 (계정 파일에는 넣지 않습니다).")
						.font(.caption).foregroundStyle(.secondary)
				}
				TextField("시작 주소", text: $start, prompt: Text(kind.home.absoluteString))
			}
			.formStyle(.grouped)
			HStack {
				Spacer()
				Button("취소", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
				Button("저장", action: save)
					.keyboardShortcut(.defaultAction)
					.buttonStyle(.borderedProminent)
					.disabled(username.trimmingCharacters(in: .whitespaces).isEmpty)
			}
			.controlSize(.large)
			.padding(16)
		}
		.frame(width: 480)
		.onAppear {
			guard let a = account else { return }
			kind = a.kind; name = a.name; username = a.username; start = a.start ?? ""; group = a.group
			password = Keychain.get(a.passwordKey) ?? ""
			otp = Keychain.get(a.otpKey) ?? ""
		}
	}

	private func save() {
		var a = account ?? Account(kind: kind, name: "", username: "")
		let u = username.trimmingCharacters(in: .whitespaces)
		a.kind = kind
		a.name = name.trimmingCharacters(in: .whitespaces).isEmpty ? "\(kind.title) \(u)" : name
		a.username = u
		a.start = start.trimmingCharacters(in: .whitespaces).isEmpty ? nil : start
		if a.group != group { a.group = group; a.order = nil }
		onSave(a, password, otp)
		dismiss()
	}
}
