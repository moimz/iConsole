import AppKit
import WebKit
import UniformTypeIdentifiers

/// 인쇄 (⌘P) · PDF로 내보내기. 둘 다 WebKit 인쇄로 쪽을 나눈다
/// (createPDF 는 페이지 전체가 한 장짜리 긴 PDF 가 되어 Safari "PDF로 내보내기" 와 다르다)
@MainActor
enum PagePrinter {
	static func print(_ tab: WebTab) {
		run(tab, info: info())
	}

	static func exportPDF(_ tab: WebTab) {
		let w = tab.webView
		let p = NSSavePanel()
		p.nameFieldStringValue = fileName(tab) + ".pdf"
		p.allowedContentTypes = [.pdf]
		p.canCreateDirectories = true
		p.directoryURL = UserDefaults.standard.url(forKey: "pdf.lastFolder") ?? FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
		let done: (NSApplication.ModalResponse) -> Void = { r in
			guard r == .OK, let url = p.url else { return }
			UserDefaults.standard.set(url.deletingLastPathComponent(), forKey: "pdf.lastFolder")
			// 저장 창 시트가 닫힌 뒤에 (시트 위에 인쇄 진행 시트를 겹치지 않게)
			DispatchQueue.main.async {
				let i = info()
				i.jobDisposition = .save
				i.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] = url
				run(tab, info: i, silent: true)
			}
		}
		if let win = w.window { p.beginSheetModal(for: win, completionHandler: done) } else { done(p.runModal()) }
	}

	private static func info() -> NSPrintInfo {
		let i = NSPrintInfo.shared.copy() as! NSPrintInfo
		// 웹 페이지는 폭에 맞추고 길이로 쪽을 나눈다 (Safari 처럼)
		i.horizontalPagination = .fit
		i.verticalPagination = .automatic
		i.isHorizontallyCentered = false
		i.isVerticallyCentered = false
		i.topMargin = 36; i.bottomMargin = 36; i.leftMargin = 36; i.rightMargin = 36
		return i
	}

	private static func run(_ tab: WebTab, info: NSPrintInfo, silent: Bool = false) {
		let w = tab.webView
		let op = w.printOperation(with: info)
		op.jobTitle = fileName(tab)
		op.showsPrintPanel = !silent
		op.showsProgressPanel = !silent
		if !silent { op.printPanel.options.formUnion([.showsPaperSize, .showsOrientation, .showsScaling, .showsPreview]) }
		// WebKit 인쇄 뷰는 크기가 0 이면 빈 쪽이 나온다
		op.view?.frame = w.bounds
		if let win = w.window {
			op.runModal(for: win, delegate: nil, didRun: nil, contextInfo: nil)
		} else {
			op.run()
		}
	}

	/// 파일 · 작업 이름: 페이지 제목 (파일 이름에 못 쓰는 글자는 바꿈)
	private static func fileName(_ tab: WebTab) -> String {
		let t = tab.title.isEmpty ? (tab.url?.host() ?? "페이지") : tab.title
		return t.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
	}
}
