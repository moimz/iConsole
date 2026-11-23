import SwiftUI

/// iConsole: AWS·구글·애플 콘솔 계정마다 따로 된 웹 저장소(로그인)와 탭을 갖는 브라우저.
/// 로그인 페이지에서는 저장한 아이디·암호·OTP 를 채운다
@main
struct iConsoleApp: App {
	@State private var model = AppModel()

	init() {
		// 자동 업데이트는 앱이 뜰 때 한 번 만들어 둔다 (하루 한 번 확인)
		_ = Updater.shared
	}

	var body: some Scene {
		// 계정마다 탭 묶음이 하나라 창도 하나
		Window("iConsole", id: "main") {
			ContentView()
				.environment(model)
				.frame(minWidth: 900, minHeight: 560)
		}
		.defaultSize(width: 1440, height: 900)
		.commands { AppCommands(model: model) }

		Window("기록", id: "log") {
			LogView().environment(model)
		}
		.defaultSize(width: 760, height: 420)

		Settings {
			SettingsView().environment(model)
		}
	}
}

struct AppCommands: Commands {
	let model: AppModel
	@Environment(\.openWindow) private var openWindow

	private var session: AccountSession? { model.current }
	private var tab: WebTab? { session?.active }
	/// 본 창이 앞에 있을 때만 탭 단축키 (기록·설정 창에서 ⌘W 는 그 창 닫기)
	private var mainKey: Bool { NSApp.keyWindow?.identifier?.rawValue.hasPrefix("main") ?? false }

	var body: some Commands {
		CommandGroup(after: .appInfo) { UpdateMenuButton() }
		CommandGroup(replacing: .newItem) {
			Button("새 탭") { session?.newTab() }
				.keyboardShortcut("t")
				.disabled(session == nil)
			Button("닫은 탭 다시 열기") { session?.reopenClosed() }
				.keyboardShortcut("t", modifiers: [.command, .shift])
				.disabled(session == nil)
			Divider()
			Button("계정 추가…") { NotificationCenter.default.post(name: .addAccount, object: nil) }
				.keyboardShortcut("n", modifiers: [.command, .shift])
		}
		CommandGroup(replacing: .saveItem) {
			Button("탭 닫기") {
				if mainKey, let s = session, let id = s.activeID { s.close(id) } else { NSApp.keyWindow?.performClose(nil) }
			}
			.keyboardShortcut("w")
			Button("창 닫기") { NSApp.keyWindow?.performClose(nil) }
				.keyboardShortcut("w", modifiers: [.command, .shift])
		}
		CommandMenu("탐색") {
			Button("주소칸") { model.address.focus() }.keyboardShortcut("l")
			Button("새로고침") { tab?.webView.reload() }.keyboardShortcut("r").disabled(tab == nil)
			Button(tab?.translated == true ? "원문 보기" : "이 페이지 번역") { if let tab { PageTranslator.shared.toggle(tab) } }
				.keyboardShortcut("t", modifiers: [.command, .option])
				.disabled(tab?.url == nil)
			Button("뒤로") { tab?.webView.goBack() }.keyboardShortcut("[").disabled(tab?.canGoBack != true)
			Button("앞으로") { tab?.webView.goForward() }.keyboardShortcut("]").disabled(tab?.canGoForward != true)
			Divider()
			Button("다음 탭") { session?.cycle(1) }.keyboardShortcut(.tab, modifiers: .control)
			Button("이전 탭") { session?.cycle(-1) }.keyboardShortcut(.tab, modifiers: [.control, .shift])
			Button("다음 탭 ") { session?.cycle(1) }.keyboardShortcut("]", modifiers: [.command, .shift])
			Button("이전 탭 ") { session?.cycle(-1) }.keyboardShortcut("[", modifiers: [.command, .shift])
			Divider()
			Button(model.favorite(for: tab?.url, in: model.currentID) != nil ? "즐겨찾기 편집…" : "즐겨찾기에 추가…") { model.editFavorite() }
				.keyboardShortcut("d")
				.disabled(tab?.url == nil)
			Divider()
			Button("확대") { tab.map { $0.webView.pageZoom = min(3, $0.webView.pageZoom + 0.1) } }.keyboardShortcut("+")
			Button("축소") { tab.map { $0.webView.pageZoom = max(0.5, $0.webView.pageZoom - 0.1) } }.keyboardShortcut("-")
			Button("실제 크기") { tab?.webView.pageZoom = 1 }.keyboardShortcut("0")
		}
		CommandGroup(after: .windowArrangement) {
			Button("기록") { openWindow(id: "log") }
		}
	}
}

/// 채우기·페이지 오류 기록 (아이디·암호·코드 값은 남기지 않는다)
struct LogView: View {
	@Environment(AppModel.self) private var model

	var body: some View {
		VStack(spacing: 0) {
			ScrollViewReader { proxy in
				List(Array(model.logs.enumerated()), id: \.offset) { i, line in
					Text(line).font(.system(size: 11, design: .monospaced)).textSelection(.enabled).id(i)
				}
				.onChange(of: model.logs.count) { _, n in if n > 0 { proxy.scrollTo(n - 1) } }
			}
			HStack {
				Spacer()
				Button("복사") {
					NSPasteboard.general.clearContents()
					NSPasteboard.general.setString(model.logs.joined(separator: "\n"), forType: .string)
				}
				Button("지우기") { model.clearLogs() }
			}
			.padding(8)
		}
	}
}

/// 앱 설정 (⌘,). iSQL 앱 설정처럼 폭은 탭마다 같고 높이만 바뀐다
struct SettingsView: View {
	static let width: CGFloat = 620
	@AppStorage("settingsTab") private var tab = "general"

	var body: some View {
		TabView(selection: $tab) {
			Tab("일반", systemImage: "gearshape", value: "general") {
				GeneralSettingsPage().frame(width: Self.width, height: 640)
			}
			Tab("MCP", systemImage: "point.3.connected.trianglepath.dotted", value: "mcp") {
				MCPSettingsPage().frame(width: Self.width, height: 680)
			}
		}
		.background(SettingsWindowStyler())
	}
}

private struct GeneralSettingsPage: View {
	@Environment(AppModel.self) private var model
	private var version: String {
		let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
		let b = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
		return "\(v) (\(b))"
	}

	var body: some View {
		@Bindable var model = model
		Form {
			Section {
				Picker("웹 페이지 모드", selection: $model.webAppearance) {
					Text("시스템 설정에 따름").tag("system")
					Text("라이트 모드").tag("light")
					Text("다크 모드").tag("dark")
				}
			} footer: {
				Text("웹 페이지(다크 모드를 지원하는 사이트)만 이 모드로 보입니다. 앱은 늘 시스템 설정을 따릅니다.").foregroundStyle(.tertiary)
			}
			Section {
				Toggle("채운 뒤 다음 버튼까지 누르기", isOn: $model.autoSubmit)
			} header: {
				Text("로그인 채우기")
			} footer: {
				Text("끄면 칸만 채우고 엔터는 직접 누릅니다. CAPTCHA 가 보이면 켜 두어도 누르지 않습니다.").foregroundStyle(.tertiary)
			}
			Section {
				Picker("번역할 언어", selection: Binding(get: { PageTranslator.shared.target }, set: { PageTranslator.shared.target = $0 })) {
					ForEach(PageTranslator.targets, id: \.id) { Text($0.label).tag($0.id) }
				}
			} header: {
				Text("번역")
			} footer: {
				Text("주소칸의 번역 버튼(⌥⌘T)은 애플 번역으로 이 맥 안에서 번역합니다. 처음 쓰는 언어는 언어 파일을 내려받을지 묻습니다.").foregroundStyle(.tertiary)
			}
			Section {
				Toggle("Safari 로 보이기 (User-Agent)", isOn: $model.safariUA)
			} header: {
				Text("웹")
			} footer: {
				Text("사이트가 앱 안 웹뷰를 막을 때 켭니다.").foregroundStyle(.tertiary)
			}
			UpdateSection(version: version)
		}
		.formStyle(.grouped)
	}
}

/// 설정 > MCP (AI 도구가 앱을 쓰게 하는 로컬 서버). 첫 칸은 Ai.md 11번 모양 (iVNC MCPSettingsPage 기준)
private struct MCPSettingsPage: View {
	@Environment(AppModel.self) private var model
	@Bindable private var mcp = MCPServer.shared
	@State private var portText = ""

	var body: some View {
		Form {
			Section {
				Toggle("MCP 서버 켜기", isOn: $mcp.enabled)
				LabeledContent("포트") {
					TextField("포트", text: $portText)
						.labelsHidden().frame(width: 80).multilineTextAlignment(.trailing)
						.onSubmit { if let p = Int(portText), (1024...65535).contains(p) { mcp.port = p } else { portText = String(mcp.port) } }
				}
				LabeledContent("상태") {
					switch mcp.status {
					case .stopped: Text("꺼짐").foregroundStyle(.secondary)
					case .running(let p): Label("듣는 중 (127.0.0.1:\(String(p)))", systemImage: "circle.fill").foregroundStyle(.green)
					case .failed(let e): Text(e).foregroundStyle(.red)
					}
				}
				LabeledContent("주소") {
					// 오른쪽 끝을 아래 "연결 명령 복사" 버튼과 맞춘다
					HStack(spacing: 8) {
						Text(mcp.endpoint).textSelection(.enabled).foregroundStyle(.secondary).lineLimit(1).fixedSize()
						Button("복사") { copyToPasteboard(mcp.endpoint) }
					}
					.frame(maxWidth: .infinity, alignment: .trailing)
				}
				LabeledContent("Claude Code") {
					Button("연결 명령 복사") { copyToPasteboard("claude mcp add --transport http iconsole \(mcp.endpoint)") }
				}
			} footer: {
				Text("이 맥 안(127.0.0.1)에서만 받습니다. 암호 · OTP 는 MCP 로 넘기지 않고, 로그인 페이지는 읽거나 다룰 수 없습니다.")
			}
			Section("접근 범위") {
				Picker("접근 범위", selection: $mcp.scope) {
					ForEach(MCPScope.allCases) { Text($0.label).tag($0) }
				}
				.pickerStyle(.radioGroup)
				.labelsHidden()
				if mcp.scope == .selected {
					ForEach(model.store.grouped, id: \.group) { g in
						ForEach(g.accounts) { a in
							Toggle(isOn: Binding(get: { mcp.allowed.contains(a.id) },
							                     set: { if $0 { mcp.allowed.insert(a.id) } else { mcp.allowed.remove(a.id) } })) {
								HStack(spacing: 8) {
									ServiceIcon(kind: a.kind, home: a.home, size: 18)
									Text(a.name)
									if !g.group.isEmpty { Text(g.group).foregroundStyle(.secondary) }
								}
							}
							.toggleStyle(.checkbox)
						}
					}
				}
			}
			Section("권한") {
				Picker("권한", selection: $mcp.permission) {
					ForEach(MCPPermission.allCases) { p in
						VStack(alignment: .leading, spacing: 2) {
							Text(p.label)
							Text(p.detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
						}
						.tag(p)
					}
				}
				.pickerStyle(.radioGroup)
				.labelsHidden()
			}
			Section("최근 요청") {
				if mcp.log.isEmpty {
					Text("아직 없습니다").foregroundStyle(.secondary)
				} else {
					ForEach(mcp.log.prefix(8)) { e in
						HStack(alignment: .firstTextBaseline) {
							Text(e.time.formatted(date: .omitted, time: .standard)).foregroundStyle(.secondary).monospacedDigit()
							Text(e.text).foregroundStyle(e.ok ? Color.primary : Color.red).lineLimit(2)
						}
						.font(.caption)
					}
				}
			}
		}
		.formStyle(.grouped)
		.onAppear { portText = String(mcp.port) }
	}
}

/// 설정 창을 맥 설정창 모양으로 (iSQL ServerSettingsView.swift 의 SettingsWindowStyler 그대로)
struct SettingsWindowStyler: NSViewRepresentable {
	final class Probe: NSView {
		override func viewDidMoveToWindow() {
			super.viewDidMoveToWindow()
			guard let w = window else { return }
			DispatchQueue.main.async {
				w.styleMask.remove(.fullSizeContentView)
				w.titlebarAppearsTransparent = false
				w.titlebarSeparatorStyle = .line
				w.toolbarStyle = .preference
			}
		}
	}
	func makeNSView(context: Context) -> Probe { Probe() }
	func updateNSView(_ v: Probe, context: Context) {}
}

/// 메뉴 iConsole > 업데이트 확인…
private struct UpdateMenuButton: View {
	private var updater = Updater.shared
	var body: some View {
		Button("업데이트 확인…") { updater.checkForUpdates() }
			.disabled(!updater.canCheck)
	}
}

/// 설정 > 일반 > 업데이트: 지금 버전, 지금 확인, 자동 확인 켜기/끄기 (iSQL UpdateSection)
private struct UpdateSection: View {
	let version: String
	@Bindable private var updater = Updater.shared

	var body: some View {
		Section {
			LabeledContent("버전") {
				HStack(spacing: 8) {
					Text(version).foregroundStyle(.secondary).monospacedDigit()
					Button("업데이트 확인…") { updater.checkForUpdates() }.disabled(!updater.canCheck)
				}
			}
			Toggle("자동으로 업데이트 확인", isOn: $updater.automaticallyChecks)
		} header: {
			Text("업데이트")
		} footer: {
			Text("하루에 한 번 새 버전이 있는지 확인하고, 있으면 설치할지 묻습니다.").foregroundStyle(.tertiary)
		}
	}
}
