import SwiftUI
import CoreImage.CIFilterBuiltins

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
	@State private var loginURL = ""
	@State private var userField = ""
	@State private var passField = ""
	@State private var otpField = ""
	@State private var showOTP = false
	@State private var showQR = false

	private var custom: Bool { kind == .custom }
	private var canSave: Bool {
		!username.trimmingCharacters(in: .whitespaces).isEmpty && (!custom || !start.trimmingCharacters(in: .whitespaces).isEmpty)
	}

	var body: some View {
		VStack(spacing: 0) {
			Form {
				Section {
					// 종류가 늘어 세그먼트 대신 고르기 (사용자 2026-11-23)
					Picker("종류", selection: $kind) {
						ForEach(Account.Kind.allCases, id: \.self) { Text($0.title).tag($0) }
					}
					TextField("이름", text: $name, prompt: Text(custom ? "예: 회사 그룹웨어" : "예: AWS 개인 루트"))
					Picker("그룹", selection: $group) {
						Text("그룹 없음").tag("")
						ForEach(model.store.grouped.map(\.group).filter { !$0.isEmpty }, id: \.self) { Text($0).tag($0) }
					}
				}
				Section {
					if custom {
						TextField("메인 페이지", text: $start, prompt: Text("https://… (필수)"))
						TextField("로그인 페이지", text: $loginURL, prompt: Text("비우면 메인 페이지 도메인에서 채움"))
					} else {
						TextField("시작 주소", text: $start, prompt: Text(kind.home.absoluteString))
					}
				} footer: {
					if custom {
						Text("아이디 · 암호 · 코드는 로그인 페이지(없으면 메인 페이지)와 같은 도메인의 https 페이지에서만 채웁니다.").font(.caption).foregroundStyle(.secondary)
					}
				}
				Section {
					TextField("아이디", text: $username, prompt: Text(kind == .aws ? "루트 계정 이메일" : "계정 이메일 · 아이디"))
					SecureField("암호", text: $password)
					if custom {
						TextField("아이디 칸", text: $userField, prompt: Text("비우면 자동으로 찾기"))
						TextField("암호 칸", text: $passField, prompt: Text("비우면 자동으로 찾기"))
						TextField("2단계 코드 칸", text: $otpField, prompt: Text("비우면 자동으로 찾기"))
					}
				} footer: {
					if custom {
						Text("칸은 name · id, 또는 # · . · [ 로 시작하는 CSS 선택자로 적습니다.").font(.caption).foregroundStyle(.secondary)
					}
				}
				Section {
					LabeledContent("OTP") {
						HStack(spacing: 6) {
							Group {
								if showOTP {
									TextField("", text: $otp, prompt: Text("otpauth://totp?secret=… 또는 비밀 값"))
								} else {
									SecureField("", text: $otp, prompt: Text("otpauth://totp?secret=… 또는 비밀 값"))
								}
							}
							.labelsHidden()
							.multilineTextAlignment(.trailing)
							Button { showOTP.toggle() } label: { Image(systemName: showOTP ? "eye.slash" : "eye") }
								.buttonStyle(.borderless)
								.help(showOTP ? "OTP 비밀 값 숨기기" : "OTP 비밀 값 보기")
						}
					}
					LabeledContent("지금 코드") {
						if otp.isEmpty {
							Text("없음").foregroundStyle(.secondary)
						} else if let t = TOTP(otp) {
							OTPCodeView(totp: t)
						} else {
							Text("형식 오류").foregroundStyle(.red)
						}
					}
					if let uri = TOTP.uri(otp, issuer: name.isEmpty ? kind.title : name, account: username) {
						LabeledContent("내보내기") {
							HStack(spacing: 8) {
								Button("otpauth 복사") { copyToPasteboard(uri) }
								Button("QR 보기") { showQR = true }
									.popover(isPresented: $showQR, arrowEdge: .bottom) { OTPQRView(uri: uri) }
							}
						}
					}
				} footer: {
					Text(kind == .apple ? "애플 계정 2단계 코드는 TOTP 가 아니라 채우지 않습니다 (문자로 받으면 macOS 가 채워 줍니다)."
					     : "암호와 OTP 는 iCloud 키체인에 저장합니다 (계정 파일에는 넣지 않습니다). QR 은 애플 암호 같은 인증 앱으로 옮길 때 씁니다.")
						.font(.caption).foregroundStyle(.secondary)
				}
				if let a = account {
					Section {
						LabeledContent("계정 ID") {
							HStack(spacing: 8) {
								Text(a.id.uuidString).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary).textSelection(.enabled)
								Button("복사") { copyToPasteboard(a.id.uuidString) }
							}
						}
					} footer: {
						Text("이 계정의 고유 값입니다. 웹 저장소 · 키체인 항목 · iCloud 파일 이름에 씁니다.").font(.caption).foregroundStyle(.secondary)
					}
				}
			}
			.formStyle(.grouped)
			HStack {
				Spacer()
				Button("취소", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
				Button("저장", action: save)
					.keyboardShortcut(.defaultAction)
					.buttonStyle(.borderedProminent)
					.disabled(!canSave)
			}
			.controlSize(.large)
			.padding(16)
		}
		.frame(width: 540, height: 660)
		.onAppear {
			guard let a = account else { return }
			kind = a.kind; name = a.name; username = a.username; start = a.start ?? ""; group = a.group
			loginURL = a.loginURL ?? ""; userField = a.userField ?? ""; passField = a.passField ?? ""; otpField = a.otpField ?? ""
			password = Keychain.get(a.passwordKey) ?? ""
			otp = Keychain.get(a.otpKey) ?? ""
		}
	}

	private func save() {
		var a = account ?? Account(kind: kind, name: "", username: "")
		let u = username.trimmingCharacters(in: .whitespaces)
		func opt(_ s: String) -> String? { let t = s.trimmingCharacters(in: .whitespaces); return t.isEmpty ? nil : t }
		a.kind = kind
		let fallback = custom ? (URL(string: start.contains("://") ? start : "https://" + start)?.host() ?? kind.title) : "\(kind.title) \(u)"
		a.name = name.trimmingCharacters(in: .whitespaces).isEmpty ? fallback : name
		a.username = u
		a.start = opt(start)
		a.loginURL = custom ? opt(loginURL) : nil
		a.userField = custom ? opt(userField) : nil
		a.passField = custom ? opt(passField) : nil
		a.otpField = custom ? opt(otpField) : nil
		if a.group != group { a.group = group; a.order = nil }
		onSave(a, password, otp)
		dismiss()
	}
}

/// OTP 를 다른 인증 앱(애플 암호 등)으로 옮길 때 쓰는 QR
struct OTPQRView: View {
	let uri: String
	var body: some View {
		VStack(spacing: 10) {
			if let img = Self.qr(uri) {
				Image(nsImage: img).interpolation(.none).resizable().frame(width: 220, height: 220)
			}
			Text("인증 앱으로 이 QR 을 읽으세요").font(.caption).foregroundStyle(.secondary)
		}
		.padding(16)
	}

	static func qr(_ text: String) -> NSImage? {
		let f = CIFilter.qrCodeGenerator()
		f.message = Data(text.utf8)
		f.correctionLevel = "M"
		guard let out = f.outputImage?.transformed(by: CGAffineTransform(scaleX: 8, y: 8)) else { return nil }
		let rep = NSCIImageRep(ciImage: out)
		let img = NSImage(size: rep.size)
		img.addRepresentation(rep)
		return img
	}
}
