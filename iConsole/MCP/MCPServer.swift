import Foundation
import AppKit
import WebKit
import Network
import Observation

/// MCP 가 열어 줄 계정 범위 (설정 > MCP)
enum MCPScope: String, CaseIterable, Identifiable {
	/// 지금 보고 있는 계정 하나
	case current
	/// 설정에서 고른 계정만 (회사 루트처럼 열기 싫은 계정은 빼 둔다)
	case selected
	/// 모든 계정
	case all
	var id: String { rawValue }
	var label: String {
		switch self {
		case .current: "지금 보고 있는 계정만"
		case .selected: "고른 계정만"
		case .all: "모든 계정"
		}
	}
}

/// MCP 가 페이지에 할 수 있는 일 (설정 > MCP)
enum MCPPermission: String, CaseIterable, Identifiable {
	case readOnly
	/// 누르기·입력마다 iConsole 에 허용/거부 창
	case confirm
	case full
	var id: String { rawValue }
	var label: String {
		switch self {
		case .readOnly: "읽기 전용"
		case .confirm: "확인 후 실행"
		case .full: "모두 허용"
		}
	}
	var detail: String {
		switch self {
		case .readOnly: "탭 열기 · 페이지 읽기 · 화면 찍기만. 누르기 · 입력은 막는다"
		case .confirm: "누르기 · 입력 · 고르기마다 iConsole 에 허용 / 거부 창을 띄운다"
		case .full: "묻지 않고 누르고 입력한다 (루트 계정이면 조심)"
		}
	}
}

/// AI 도구(Claude Code 등)가 iConsole 의 계정별 웹뷰를 보고 다루게 하는 MCP 서버 (Streamable HTTP, POST /mcp).
/// 이 맥 안(127.0.0.1)에서만 받는다. 로그인은 이미 웹뷰에 되어 있어 AI 는 암호를 모른다.
/// 암호 · OTP 는 어떤 도구로도 넘기지 않고, 로그인 페이지에서는 읽기 · 입력을 막는다.
/// HTTP · JSON-RPC 틀은 iSQL Model/MCPServer.swift 그대로
@Observable @MainActor
final class MCPServer {
	static let shared = MCPServer()
	@ObservationIgnored weak var model: AppModel?

	enum Status: Equatable { case stopped, running(Int), failed(String) }
	private(set) var status: Status = .stopped

	// MARK: 설정 (UserDefaults, 이 맥에만)

	var enabled: Bool = UserDefaults.standard.bool(forKey: "mcp.enabled") {
		didSet { UserDefaults.standard.set(enabled, forKey: "mcp.enabled"); restart() }
	}
	/// iSQL(8766) · iVNC(8767) 과 겹치지 않게
	var port: Int = UserDefaults.standard.object(forKey: "mcp.port") as? Int ?? 8768 {
		didSet { UserDefaults.standard.set(port, forKey: "mcp.port"); if oldValue != port { restart() } }
	}
	var scope: MCPScope = MCPScope(rawValue: UserDefaults.standard.string(forKey: "mcp.scope") ?? "") ?? .current {
		didSet { UserDefaults.standard.set(scope.rawValue, forKey: "mcp.scope") }
	}
	var permission: MCPPermission = MCPPermission(rawValue: UserDefaults.standard.string(forKey: "mcp.permission") ?? "") ?? .confirm {
		didSet { UserDefaults.standard.set(permission.rawValue, forKey: "mcp.permission") }
	}
	/// 범위가 "고른 계정만" 일 때 열어 줄 계정
	var allowed: Set<UUID> = Set((UserDefaults.standard.stringArray(forKey: "mcp.allowed") ?? []).compactMap(UUID.init)) {
		didSet { UserDefaults.standard.set(allowed.map(\.uuidString), forKey: "mcp.allowed") }
	}

	var endpoint: String { "http://127.0.0.1:\(port)/mcp" }

	/// 최근 요청 (설정 화면에 보인다)
	struct LogEntry: Identifiable {
		let id = UUID()
		let time = Date()
		let text: String
		let ok: Bool
	}
	private(set) var log: [LogEntry] = []
	private func note(_ text: String, ok: Bool = true) {
		log.insert(LogEntry(text: text, ok: ok), at: 0)
		if log.count > 50 { log.removeLast(log.count - 50) }
		model?.log("[MCP] \(text)")
	}

	// MARK: 듣기

	@ObservationIgnored private var listener: NWListener?

	func startIfEnabled() { if enabled && listener == nil { start() } }

	private func restart() {
		stop()
		if enabled { start() }
	}

	private func stop() {
		listener?.cancel()
		listener = nil
		status = .stopped
	}

	private func start() {
		guard let p = NWEndpoint.Port(rawValue: UInt16(clamping: port)), port >= 1024 else {
			status = .failed("포트는 1024~65535")
			return
		}
		do {
			let params = NWParameters.tcp
			params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: p)
			params.allowLocalEndpointReuse = true
			let l = try NWListener(using: params)
			l.newConnectionHandler = { [weak self] c in
				Task { @MainActor in self?.accept(c) }
			}
			l.stateUpdateHandler = { [weak self] st in
				Task { @MainActor in
					guard let self else { return }
					switch st {
					case .ready: self.status = .running(self.port)
					case .failed(let e): self.status = .failed(e.localizedDescription); self.listener = nil
					default: break
					}
				}
			}
			l.start(queue: .main)
			listener = l
		} catch {
			status = .failed(error.localizedDescription)
		}
	}

	// MARK: HTTP (요청 하나 받고 답하고 닫는다)

	private func accept(_ c: NWConnection) {
		c.start(queue: .main)
		receive(c, buffer: Data())
	}

	private func receive(_ c: NWConnection, buffer: Data) {
		c.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, done, error in
			Task { @MainActor in
				guard let self else { return }
				var buf = buffer
				if let data { buf.append(data) }
				if let req = HTTPRequest(buf) {
					await self.respond(c, req)
				} else if done || error != nil || buf.count > 32 << 20 {
					c.cancel()
				} else {
					self.receive(c, buffer: buf)
				}
			}
		}
	}

	private func respond(_ c: NWConnection, _ req: HTTPRequest) async {
		// 브라우저가 이 포트로 몰래 요청하는 것(DNS 리바인딩) 막기: Origin 이 있으면 localhost 만
		if let origin = req.headers["origin"], !(origin.contains("://127.0.0.1") || origin.contains("://localhost")) {
			send(c, status: "403 Forbidden", body: Data())
			return
		}
		guard req.path.hasPrefix("/mcp") else { send(c, status: "404 Not Found", body: Data()); return }
		switch req.method {
		case "POST": break
		case "DELETE": send(c, status: "200 OK", body: Data()); return
		default: send(c, status: "405 Method Not Allowed", body: Data()); return
		}
		guard let json = try? JSONSerialization.jsonObject(with: req.body) else {
			send(c, status: "400 Bad Request", json: rpcError(nil, -32700, "JSON 을 읽지 못했습니다"))
			return
		}
		if let batch = json as? [[String: Any]] {
			var out: [[String: Any]] = []
			for m in batch { if let r = await handle(m) { out.append(r) } }
			if out.isEmpty { send(c, status: "202 Accepted", body: Data()) } else { send(c, status: "200 OK", json: out) }
		} else if let m = json as? [String: Any] {
			if let r = await handle(m) { send(c, status: "200 OK", json: r) } else { send(c, status: "202 Accepted", body: Data()) }
		} else {
			send(c, status: "400 Bad Request", json: rpcError(nil, -32600, "잘못된 요청"))
		}
	}

	private func send(_ c: NWConnection, status: String, json: Any) {
		let body = (try? JSONSerialization.data(withJSONObject: json, options: [.withoutEscapingSlashes])) ?? Data()
		send(c, status: status, body: body, type: "application/json")
	}

	private func send(_ c: NWConnection, status: String, body: Data, type: String? = nil) {
		var head = "HTTP/1.1 \(status)\r\nContent-Length: \(body.count)\r\nConnection: close\r\n"
		if let type { head += "Content-Type: \(type)\r\n" }
		head += "\r\n"
		var out = Data(head.utf8)
		out.append(body)
		c.send(content: out, completion: .contentProcessed { _ in c.cancel() })
	}

	// MARK: JSON-RPC

	private func rpcError(_ id: Any?, _ code: Int, _ message: String) -> [String: Any] {
		["jsonrpc": "2.0", "id": id ?? NSNull(), "error": ["code": code, "message": message]]
	}

	/// 알림(id 없음)은 nil
	private func handle(_ m: [String: Any]) async -> [String: Any]? {
		let id = m["id"]
		let method = m["method"] as? String ?? ""
		let params = m["params"] as? [String: Any] ?? [:]
		guard id != nil else { return nil }
		func ok(_ result: [String: Any]) -> [String: Any] { ["jsonrpc": "2.0", "id": id!, "result": result] }
		switch method {
		case "initialize":
			let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
			return ok([
				"protocolVersion": params["protocolVersion"] as? String ?? "2025-06-18",
				"capabilities": ["tools": [String: Any]()],
				"serverInfo": ["name": "iConsole", "version": version],
				"instructions": MCPTools.instructions,
			])
		case "ping":
			return ok([:])
		case "tools/list":
			return ok(["tools": MCPTools.list])
		case "tools/call":
			let name = params["name"] as? String ?? ""
			let args = params["arguments"] as? [String: Any] ?? [:]
			do {
				let content = try await call(name, args)
				return ok(["content": content, "isError": false])
			} catch {
				note("\(name): \(error.localizedDescription)", ok: false)
				return ok(["content": [["type": "text", "text": error.localizedDescription]], "isError": true])
			}
		default:
			return rpcError(id, -32601, "모르는 메서드: \(method)")
		}
	}

	// MARK: 도구 실행

	struct Failure: LocalizedError {
		let message: String
		init(_ m: String) { message = m }
		var errorDescription: String? { message }
	}

	@ObservationIgnored private let world = WKContentWorld.world(name: "iconsole-mcp")

	private func call(_ name: String, _ a: [String: Any]) async throws -> [[String: Any]] {
		guard let model else { throw Failure("앱이 준비되지 않았습니다") }
		func text(_ s: String) -> [[String: Any]] { [["type": "text", "text": s]] }

		switch name {
		case "list_accounts":
			let list = accessible().map { acc -> [String: Any] in
				let s = model.sessions[acc.id]
				return ["id": acc.id.uuidString, "name": acc.name, "service": acc.kind.title, "group": acc.group,
				        "current": acc.id == model.currentID, "open_tabs": s?.tabs.count ?? 0,
				        "favorites": acc.favorites.map { ["title": $0.title, "url": $0.url] }]
			}
			note("list_accounts (\(list.count))")
			return text(json(["accounts": list, "scope": scope.label, "permission": permission.label + " — " + permission.detail]))

		case "list_tabs":
			let acc = try account(a)
			let s = model.session(acc.id)
			let tabs = s.tabs.map { t -> [String: Any] in
				["tab": t.shortID, "title": t.displayTitle, "url": (t.url ?? t.pending)?.absoluteString ?? "", "active": t.id == s.activeID]
			}
			note("list_tabs \(acc.name)")
			return text(json(["account": acc.name, "tabs": tabs]))

		case "open_tab":
			let acc = try account(a)
			let urlText = try string(a, "url")
			guard let u = BrowserPane.url(from: urlText) else { throw Failure("주소가 아닙니다: \(urlText)") }
			let s = model.session(acc.id)
			model.select(acc.id)
			let t: WebTab
			if let tabID = a["tab"] as? String {
				t = try tab(s, tabID)
				s.select(t.id)
				t.load(u)
			} else {
				t = s.newTab(u)
			}
			await settle(t)
			note("open_tab \(acc.name) \(u.host() ?? "")")
			return text(json(["account": acc.name, "tab": t.shortID, "title": t.displayTitle, "url": t.url?.absoluteString ?? ""]))

		case "select_tab":
			let acc = try account(a)
			let s = model.session(acc.id)
			let t = try tab(s, try string(a, "tab"))
			model.select(acc.id)
			s.select(t.id)
			await settle(t)
			note("select_tab \(acc.name)")
			return text(json(["tab": t.shortID, "title": t.displayTitle, "url": t.url?.absoluteString ?? ""]))

		case "read_page":
			let (acc, t) = try target(a)
			try refuseLogin(t, acc)
			await settle(t)
			let max = min(max(1000, a["max_chars"] as? Int ?? 20000), 100_000)
			let r = try await t.webView.callAsyncJavaScript(MCPTools.snapshot, arguments: ["maxChars": max], in: nil, contentWorld: world)
			note("read_page \(acc.name) \(t.url?.host() ?? "")")
			return text("\(t.displayTitle)\n\(t.url?.absoluteString ?? "")\n\n\(r as? String ?? "")")

		case "screenshot":
			let (acc, t) = try target(a)
			try refuseLogin(t, acc)
			// 보이는 탭이어야 그림이 찍힌다 → 그 계정·탭을 앞으로
			model.select(acc.id)
			model.session(acc.id).select(t.id)
			await settle(t)
			try? await Task.sleep(for: .milliseconds(300))
			let img = try await t.webView.takeSnapshot(configuration: nil)
			guard let png = Self.png(img, maxWidth: 1600) else { throw Failure("화면을 찍지 못했습니다") }
			note("screenshot \(acc.name)")
			return [["type": "image", "data": png.base64EncodedString(), "mimeType": "image/png"]]

		case "click", "fill", "select_option":
			let (acc, t) = try target(a)
			try refuseLogin(t, acc)
			guard permission != .readOnly else { throw Failure("설정 > MCP 의 권한이 읽기 전용이라 누르기·입력을 할 수 없습니다") }
			let ref = try int(a, "ref")
			let value = a["value"] as? String
			if name != "click", value == nil { throw Failure("value 가 필요합니다") }
			// 그 요소가 무엇인지 먼저 본다 (확인 창에 보이고, 암호 칸이면 막는다)
			let info = try await t.webView.callAsyncJavaScript(MCPTools.describe, arguments: ["ref": ref], in: nil, contentWorld: world) as? String
			guard let info, !info.isEmpty else { throw Failure("[\(ref)] 요소가 없습니다. read_page 를 다시 하세요") }
			if name == "fill", info.hasPrefix("password") { throw Failure("암호 칸에는 MCP 로 입력하지 않습니다") }
			model.select(acc.id)
			model.session(acc.id).select(t.id)
			let action: String = switch name {
			case "click": "누르기: \(info)"
			case "fill": "입력: \(info)\n← \"\(value ?? "")\""
			default: "고르기: \(info)\n← \"\(value ?? "")\""
			}
			if permission == .confirm, !(await confirm(account: acc, page: t, action: action)) {
				note("\(name) 거부됨 \(acc.name)", ok: false)
				throw Failure("사용자가 거부했습니다")
			}
			let r = try await t.webView.callAsyncJavaScript(MCPTools.act, arguments: ["ref": ref, "op": name, "value": value ?? ""], in: nil, contentWorld: world)
			try? await Task.sleep(for: .milliseconds(600))
			await settle(t)
			note("\(name) \(acc.name): \(info.prefix(60))")
			return text("\(r as? String ?? "done")\n지금 페이지: \(t.displayTitle) \(t.url?.absoluteString ?? "")")

		case "wait":
			let (_, t) = try target(a)
			let seconds = min(max(0.2, (a["seconds"] as? Double) ?? Double(a["seconds"] as? Int ?? 2)), 15)
			let until = a["text"] as? String
			let end = Date().addingTimeInterval(seconds)
			while Date() < end {
				if let until, !until.isEmpty,
				   let body = try? await t.webView.callAsyncJavaScript("return document.body ? document.body.innerText : ''", arguments: [:], in: nil, contentWorld: world) as? String,
				   body.contains(until) {
					return text("찾음: \(until)")
				}
				try? await Task.sleep(for: .milliseconds(300))
			}
			await settle(t)
			return text(until.map { "\(Int(seconds))초 동안 '\($0)' 를 찾지 못했습니다" } ?? "기다림 끝")

		default:
			throw Failure("모르는 도구: \(name)")
		}
	}

	// MARK: 계정·탭 찾기

	/// 범위 안 계정
	private func accessible() -> [Account] {
		guard let model else { return [] }
		switch scope {
		case .current: return model.currentAccount.map { [$0] } ?? []
		case .selected: return model.store.accounts.filter { allowed.contains($0.id) }
		case .all: return model.store.accounts
		}
	}

	/// account 인자(이름 또는 id)로. 없으면 지금 계정 (범위 안이어야)
	private func account(_ a: [String: Any]) throws -> Account {
		let list = accessible()
		guard let key = (a["account"] as? String)?.trimmingCharacters(in: .whitespaces), !key.isEmpty else {
			if let cur = model?.currentAccount, list.contains(where: { $0.id == cur.id }) { return cur }
			throw Failure("account 를 주세요 (list_accounts). 지금 계정은 MCP 범위 밖입니다")
		}
		if let acc = list.first(where: { $0.id.uuidString.caseInsensitiveCompare(key) == .orderedSame || $0.name.caseInsensitiveCompare(key) == .orderedSame }) {
			return acc
		}
		throw Failure("'\(key)' 계정이 없거나 MCP 범위 밖입니다 (설정 > MCP > 접근 범위)")
	}

	private func tab(_ s: AccountSession, _ id: String) throws -> WebTab {
		guard let t = s.tabs.first(where: { $0.shortID == id.lowercased() }) else { throw Failure("'\(id)' 탭이 없습니다 (list_tabs)") }
		return t
	}

	/// 계정 + 탭 (tab 을 빼면 그 계정의 지금 탭)
	private func target(_ a: [String: Any]) throws -> (Account, WebTab) {
		let acc = try account(a)
		guard let model else { throw Failure("앱이 준비되지 않았습니다") }
		let s = model.session(acc.id)
		if let id = a["tab"] as? String { return (acc, try tab(s, id)) }
		guard let t = s.active else { throw Failure("\(acc.name) 에 열린 탭이 없습니다 (open_tab)") }
		return (acc, t)
	}

	/// 로그인 페이지는 읽기·입력 모두 막는다 (암호·OTP 가 AI 쪽으로 가지 않게)
	private func refuseLogin(_ t: WebTab, _ acc: Account) throws {
		let host = (t.url ?? t.pending)?.host()?.lowercased() ?? ""
		let login = Account.Kind.allCases.flatMap(\.loginHosts).contains { host == $0 || host.hasSuffix("." + $0) }
		if login { throw Failure("\(acc.name) 탭이 로그인 페이지라 MCP 로 읽거나 다룰 수 없습니다. iConsole 에서 직접 로그인한 뒤 다시 하세요") }
	}

	/// 되살린 탭이면 읽게 하고, 다 읽을 때까지 (최대 15초) 기다린다
	private func settle(_ t: WebTab) async {
		t.wake()
		try? await Task.sleep(for: .milliseconds(150))
		for _ in 0..<150 where t.isLoading { try? await Task.sleep(for: .milliseconds(100)) }
	}

	// MARK: 확인 창

	private func confirm(account acc: Account, page t: WebTab, action: String) async -> Bool {
		NSApp.activate(ignoringOtherApps: true)
		let alert = NSAlert()
		alert.messageText = "MCP 가 ‘\(acc.name)’ 계정에서 다음을 하려고 합니다"
		alert.informativeText = "\(action)\n\n페이지: \(t.displayTitle)\n\(t.url?.absoluteString ?? "")"
		alert.addButton(withTitle: "허용")
		alert.addButton(withTitle: "거부")
		alert.alertStyle = .warning
		let window = NSApp.windows.first { $0.identifier?.rawValue.hasPrefix("main") == true && $0.isVisible }
		if let window {
			return await withCheckedContinuation { c in
				alert.beginSheetModal(for: window) { c.resume(returning: $0 == .alertFirstButtonReturn) }
			}
		}
		return alert.runModal() == .alertFirstButtonReturn
	}

	// MARK: 작은 도움

	private func string(_ a: [String: Any], _ key: String) throws -> String {
		guard let s = a[key] as? String, !s.isEmpty else { throw Failure("\(key) 가 필요합니다") }
		return s
	}

	private func int(_ a: [String: Any], _ key: String) throws -> Int {
		if let i = a[key] as? Int { return i }
		if let s = a[key] as? String, let i = Int(s.trimmingCharacters(in: CharacterSet(charactersIn: "[] "))) { return i }
		throw Failure("\(key) (숫자) 가 필요합니다")
	}

	private func json(_ v: Any) -> String {
		guard let d = try? JSONSerialization.data(withJSONObject: v, options: [.prettyPrinted, .withoutEscapingSlashes, .sortedKeys]) else { return "{}" }
		return String(decoding: d, as: UTF8.self)
	}

	private static func png(_ img: NSImage, maxWidth: CGFloat) -> Data? {
		guard let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
		let scale = min(1, maxWidth / CGFloat(cg.width))
		let w = Int(CGFloat(cg.width) * scale), h = Int(CGFloat(cg.height) * scale)
		guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
		                          space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
		ctx.interpolationQuality = .high
		ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
		guard let out = ctx.makeImage() else { return nil }
		return NSBitmapImageRep(cgImage: out).representation(using: .png, properties: [:])
	}
}

/// HTTP 요청 하나 (다 받았을 때만 만들어진다, iSQL 그대로)
private struct HTTPRequest {
	let method: String
	let path: String
	let headers: [String: String]
	let body: Data

	init?(_ data: Data) {
		guard let end = data.range(of: Data("\r\n\r\n".utf8)) else { return nil }
		let head = String(decoding: data[..<end.lowerBound], as: UTF8.self)
		var lines = head.components(separatedBy: "\r\n")
		let first = lines.removeFirst().split(separator: " ")
		guard first.count >= 2 else { return nil }
		var h: [String: String] = [:]
		for l in lines {
			guard let i = l.firstIndex(of: ":") else { continue }
			h[l[..<i].lowercased()] = l[l.index(after: i)...].trimmingCharacters(in: .whitespaces)
		}
		let length = Int(h["content-length"] ?? "0") ?? 0
		let bodyStart = end.upperBound
		guard data.count - bodyStart >= length else { return nil }
		method = String(first[0])
		path = String(first[1])
		headers = h
		body = data.subdata(in: bodyStart..<(bodyStart + length))
	}
}
