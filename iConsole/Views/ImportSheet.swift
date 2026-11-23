import SwiftUI

/// 암호 앱에서 받은 항목을 어느 계정에 넣을지 고르는 시트 (PasswordImport)
struct ImportSheet: View {
	@Environment(AppModel.self) private var model
	@Bindable private var importer = PasswordImport.shared

	var body: some View {
		VStack(alignment: .leading, spacing: 12) {
			Text("암호 앱에서 가져오기").font(.headline)
			Text("항목마다 넣을 계정을 고르세요. 같은 아이디 · 도메인의 계정이 있으면 미리 골라 두었습니다. 넣으면 그 계정의 암호 · OTP 를 바꿉니다.")
				.font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
			List {
				ForEach($importer.items) { $c in
					HStack(spacing: 10) {
						ServiceIcon(kind: PasswordImport.kind(for: c.host), home: c.urls.first, size: 26)
						VStack(alignment: .leading, spacing: 2) {
							// 이름 뒤에 들어 있는 것(암호 · OTP · 패스키) 알약을 붙여 두 줄로 (세 줄은 이상했다, 사용자 2026-11-23)
							HStack(spacing: 6) {
								Text(c.title.isEmpty ? (c.host ?? "이름 없음") : c.title).lineLimit(1)
								if c.password != nil { Badge("암호") }
								if c.otp != nil { Badge("OTP") }
								if !c.passkeys.isEmpty { Badge("패스키 \(c.passkeys.count)") }
							}
							Text([c.username, c.host].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
								.font(.caption).foregroundStyle(.secondary).lineLimit(1)
						}
						Spacer()
						Picker("", selection: $c.target) {
							Text("건너뛰기").tag(PasswordImport.Candidate.Target.skip)
							Text("새 계정 (\(PasswordImport.kind(for: c.host).title))").tag(PasswordImport.Candidate.Target.new)
							Divider()
							ForEach(model.store.accounts) { a in Text("\(a.name) · \(a.username)").tag(PasswordImport.Candidate.Target.account(a.id)) }
						}
						.labelsHidden()
						.frame(width: 220)
					}
					.padding(.vertical, 2)
				}
			}
			.frame(minHeight: 240)
			Text("패스키는 받아 두기만 합니다 (iConsole 안 웹뷰에서 패스키로 로그인하는 기능은 아직 없습니다).")
				.font(.caption).foregroundStyle(.tertiary)
			HStack {
				Spacer()
				Button("취소", role: .cancel) { importer.items = [] }.keyboardShortcut(.cancelAction)
				Button("가져오기") { importer.apply() }
					.keyboardShortcut(.defaultAction)
					.buttonStyle(.borderedProminent)
					.disabled(importer.items.allSatisfy { $0.target == .skip })
			}
			.controlSize(.large)
		}
		.padding(20)
		.frame(width: 640, height: 480)
	}
}

private struct Badge: View {
	let text: String
	init(_ t: String) { text = t }
	var body: some View {
		Text(text).font(.caption2)
			.padding(.horizontal, 6).padding(.vertical, 1)
			.background(Capsule().fill(Color.secondary.opacity(0.15)))
	}
}
