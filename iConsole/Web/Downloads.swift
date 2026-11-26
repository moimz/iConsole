import AppKit
import WebKit
import Observation
import UniformTypeIdentifiers

/// 웹뷰에서 받는 파일 (모든 계정 탭 공용). 제목줄 오른쪽 다운로드 버튼과 목록(DownloadsButton)이 이걸 본다.
/// 받을 곳: 설정 > 일반 > 다운로드 — "매번 묻기"(기본, 사용자 2026-11-26) 또는 정해 둔 폴더
@Observable @MainActor
final class Downloads: NSObject, WKDownloadDelegate {
	static let shared = Downloads()
	@ObservationIgnored weak var model: AppModel?

	@Observable final class Item: Identifiable {
		let id = UUID()
		let download: WKDownload
		let account: String?
		let source: URL?
		var name: String
		var file: URL?
		var state: State = .preparing
		var received: Int64 = 0
		var total: Int64 = -1
		@ObservationIgnored var observers: [NSKeyValueObservation] = []

		enum State: Equatable { case preparing, running, finished, failed(String), cancelled }

		init(download: WKDownload, account: String?, source: URL?) {
			self.download = download
			self.account = account
			self.source = source
			name = source?.lastPathComponent ?? "다운로드"
		}

		var fraction: Double? { total > 0 ? min(1, Double(received) / Double(total)) : nil }
		var isActive: Bool { state == .preparing || state == .running }
	}

	/// 최근 것이 위
	private(set) var items: [Item] = []
	/// 방금 끝난 것이 있으면 버튼을 잠깐 튀게
	private(set) var bounce = 0
	/// 목록 팝오버 (받기 시작하면 Safari 처럼 연다)
	var showList = false

	/// 매번 묻기
	var askWhere = UserDefaults.standard.object(forKey: "download.ask") as? Bool ?? true {
		didSet { UserDefaults.standard.set(askWhere, forKey: "download.ask") }
	}
	/// 묻지 않을 때 받는 폴더 (기본 ~/Downloads)
	var folder: URL = UserDefaults.standard.url(forKey: "download.folder") ?? Downloads.defaultFolder {
		didSet { UserDefaults.standard.set(folder, forKey: "download.folder") }
	}
	static let defaultFolder = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
	/// 묻는 창에서 마지막으로 고른 폴더 (다음에 거기서 연다)
	private var lastAsked: URL? {
		get { UserDefaults.standard.url(forKey: "download.lastAsked") }
		set { UserDefaults.standard.set(newValue, forKey: "download.lastAsked") }
	}

	var active: [Item] { items.filter(\.isActive) }
	/// 버튼 둘레 진행 (받는 것들 합)
	var overallFraction: Double? {
		let a = active.filter { $0.total > 0 }
		guard !a.isEmpty else { return nil }
		return Double(a.map(\.received).reduce(0, +)) / Double(a.map(\.total).reduce(0, +))
	}

	@ObservationIgnored private var windows: [ObjectIdentifier: NSWindow] = [:]

	func start(_ d: WKDownload, from w: WKWebView, account: String?) {
		let item = Item(download: d, account: account, source: d.originalRequest?.url)
		d.delegate = self
		windows[ObjectIdentifier(d)] = w.window ?? NSApp.keyWindow
		items.insert(item, at: 0)
		item.observers = [
			d.progress.observe(\.completedUnitCount, options: [.initial, .new]) { [weak self, id = item.id] p, _ in
				let done = p.completedUnitCount, all = p.totalUnitCount
				Task { @MainActor in
					guard let item = self?.items.first(where: { $0.id == id }) else { return }
					item.received = done
					item.total = all
					self?.touch()
				}
			},
		]
	}

	private func item(_ d: WKDownload) -> Item? { items.first { $0.download === d } }
	/// Item 은 @Observable 이 아니라 목록 배열을 건드려 다시 그리게 한다
	private func touch() { items = items }

	// MARK: WKDownloadDelegate

	func download(_ d: WKDownload, decideDestinationUsing response: URLResponse, suggestedFilename name: String) async -> URL? {
		let name = name.isEmpty ? (response.url?.lastPathComponent ?? "다운로드") : name
		guard let item = item(d) else { return nil }
		item.name = name
		if response.expectedContentLength > 0 { item.total = response.expectedContentLength }
		touch()
		let url: URL?
		if askWhere {
			url = await ask(name, window: windows[ObjectIdentifier(d)])
		} else {
			url = Self.unique(folder.appendingPathComponent(name))
		}
		guard let url else {
			item.state = .cancelled
			touch()
			model?.log("받기 취소: \(name)")
			return nil
		}
		// 저장 창에서 같은 이름을 "대치"로 골랐으면 그 파일을 지워야 WebKit 이 쓴다
		if FileManager.default.fileExists(atPath: url.path) { try? FileManager.default.removeItem(at: url) }
		item.name = url.lastPathComponent
		item.file = url
		item.state = .running
		showList = true
		touch()
		model?.log("받는 중: \(url.path)")
		return url
	}

	func downloadDidFinish(_ d: WKDownload) {
		guard let item = item(d), let url = item.file else { return }
		item.state = .finished
		if item.total <= 0 { item.total = item.received }
		bounce += 1
		touch()
		windows[ObjectIdentifier(d)] = nil
		model?.log("받음: \(url.path)")
		// 어디서 받았는지 (Finder 정보 가져오기의 "다음에서 다운로드됨")
		if let s = item.source?.absoluteString, s.hasPrefix("http") { Self.setWhereFrom(url, [s]) }
		// Dock 의 다운로드 스택이 튀어 오르게 (Safari 처럼)
		DistributedNotificationCenter.default().post(name: .init("com.apple.DownloadFileFinished"), object: url.resolvingSymlinksInPath().path)
	}

	func download(_ d: WKDownload, didFailWithError e: Error, resumeData: Data?) {
		guard let item = item(d) else { return }
		windows[ObjectIdentifier(d)] = nil
		if (e as NSError).code == NSURLErrorCancelled, item.state == .cancelled { return }
		item.state = .failed(e.localizedDescription)
		touch()
		model?.log("받지 못함: \(item.name) — \(e.localizedDescription)")
	}

	// MARK: 목록에서

	func cancel(_ item: Item) {
		item.state = .cancelled
		touch()
		item.download.cancel { _ in }
		if let f = item.file { try? FileManager.default.removeItem(at: f) }
	}

	func reveal(_ item: Item) {
		guard let f = item.file, FileManager.default.fileExists(atPath: f.path) else { return }
		NSWorkspace.shared.activateFileViewerSelecting([f])
	}

	func open(_ item: Item) {
		guard item.state == .finished, let f = item.file else { return }
		NSWorkspace.shared.open(f)
	}

	func remove(_ item: Item) { items.removeAll { $0.id == item.id } }

	/// 받는 중이 아닌 것 모두 지우기 (파일은 그대로)
	func clear() { items.removeAll { !$0.isActive } }

	// MARK: 작은 도움

	private func ask(_ name: String, window: NSWindow?) async -> URL? {
		let p = NSSavePanel()
		p.nameFieldStringValue = name
		p.directoryURL = lastAsked ?? Self.defaultFolder
		p.canCreateDirectories = true
		p.isExtensionHidden = false
		if let t = UTType(filenameExtension: (name as NSString).pathExtension) { p.allowedContentTypes = [t]; p.allowsOtherFileTypes = true }
		let r: NSApplication.ModalResponse
		if let window {
			r = await withCheckedContinuation { c in p.beginSheetModal(for: window) { c.resume(returning: $0) } }
		} else {
			r = p.runModal()
		}
		guard r == .OK, let url = p.url else { return nil }
		lastAsked = url.deletingLastPathComponent()
		return url
	}

	/// 같은 이름이 있으면 "이름 2.확장자"
	static func unique(_ url: URL) -> URL {
		let dir = url.deletingLastPathComponent(), name = url.lastPathComponent
		let base = (name as NSString).deletingPathExtension, ext = (name as NSString).pathExtension
		var u = url, n = 2
		while FileManager.default.fileExists(atPath: u.path) {
			u = dir.appendingPathComponent(ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)")
			n += 1
		}
		return u
	}

	private static func setWhereFrom(_ url: URL, _ list: [String]) {
		guard let d = try? PropertyListSerialization.data(fromPropertyList: list, format: .binary, options: 0) else { return }
		_ = d.withUnsafeBytes { setxattr(url.path, "com.apple.metadata:kMDItemWhereFroms", $0.baseAddress, d.count, 0, 0) }
	}

	static func size(_ n: Int64) -> String { ByteCountFormatter.string(fromByteCount: n, countStyle: .file) }
}
