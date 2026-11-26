import SwiftUI
import UniformTypeIdentifiers

/// 제목줄 오른쪽 다운로드 버튼 (Safari 처럼 받은 것이 있을 때만 보이고, 받는 동안 둘레에 진행이 돈다)
struct DownloadsButton: View {
	@Bindable private var downloads = Downloads.shared

	var body: some View {
		Button { downloads.showList.toggle() } label: {
			// 받는 동안은 원 없는 화살표 + 직접 그린 원 (흐린 바탕 원 위에 두꺼운 파란 진행, 사용자 2026-11-26: 얇아서 잘 안 보였다)
			if let f = downloads.overallFraction {
				ZStack {
					Circle().stroke(Color.secondary.opacity(0.35), lineWidth: 2.5)
					Circle().trim(from: 0, to: f)
						.stroke(Color.accentColor, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
						.rotationEffect(.degrees(-90))
						.animation(.linear(duration: 0.2), value: f)
					Image(systemName: "arrow.down").font(.system(size: 9, weight: .bold))
				}
				.frame(width: 17, height: 17)
			} else {
				Image(systemName: "arrow.down.circle")
					.symbolEffect(.bounce, value: downloads.bounce)
			}
		}
		.help("다운로드")
		.popover(isPresented: $downloads.showList, arrowEdge: .bottom) { DownloadsList() }
	}
}

/// 받은 것 목록 (팝오버)
struct DownloadsList: View {
	@Bindable private var downloads = Downloads.shared
	@State private var listHeight: CGFloat = 0

	var body: some View {
		VStack(alignment: .leading, spacing: 0) {
			HStack {
				Text("다운로드").font(.headline)
				Spacer()
				Button("지우기") { downloads.clear() }
					.disabled(downloads.items.allSatisfy(\.isActive))
			}
			.padding(.horizontal, 14).padding(.vertical, 10)
			Divider()
			if downloads.items.isEmpty {
				Text("받은 파일이 없습니다").foregroundStyle(.secondary)
					.frame(maxWidth: .infinity, minHeight: 80)
			} else {
				// 팝오버 안 ScrollView 는 한 줄 높이로 줄어든다 → 내용 높이를 재서 그만큼, 최대 420 에서 멈추고 스크롤 (사용자 2026-11-26)
				ScrollView {
					VStack(spacing: 0) {
						ForEach(downloads.items) { DownloadRow(item: $0) }
					}
					.padding(.vertical, 4)
					.onGeometryChange(for: CGFloat.self) { $0.size.height } action: { listHeight = $0 }
				}
				.scrollBounceBehavior(.basedOnSize)
				.frame(height: min(max(listHeight, 50), 420))
			}
		}
		.frame(width: 360)
	}
}

private struct DownloadRow: View {
	let item: Downloads.Item
	@State private var hover = false

	var body: some View {
		HStack(spacing: 10) {
			Image(nsImage: icon).resizable().frame(width: 32, height: 32)
				.opacity(item.state == .finished ? 1 : 0.6)
			VStack(alignment: .leading, spacing: 3) {
				Text(item.name).lineLimit(1).truncationMode(.middle)
				if item.state == .running {
					if let f = item.fraction { ProgressView(value: f).controlSize(.small) } else { ProgressView().progressViewStyle(.linear).controlSize(.small) }
				}
				Text(detail).font(.caption).foregroundStyle(failed ? .red : .secondary).lineLimit(1)
			}
			Spacer(minLength: 4)
			if item.isActive {
				Button { Downloads.shared.cancel(item) } label: { Image(systemName: "xmark.circle.fill") }
					.buttonStyle(.plain).foregroundStyle(.secondary).help("받기 멈춤")
			} else if item.state == .finished {
				Button { Downloads.shared.reveal(item) } label: { Image(systemName: "magnifyingglass.circle.fill") }
					.buttonStyle(.plain).foregroundStyle(.secondary).help("Finder 에서 보기")
			}
		}
		.font(.callout)
		.padding(.horizontal, 14).padding(.vertical, 6)
		.background(hover ? Color.secondary.opacity(0.1) : .clear)
		.contentShape(Rectangle())
		.onHover { hover = $0 }
		.onTapGesture(count: 2) { Downloads.shared.open(item) }
		.contextMenu {
			Button("열기") { Downloads.shared.open(item) }.disabled(item.state != .finished)
			Button("Finder 에서 보기") { Downloads.shared.reveal(item) }.disabled(item.state != .finished)
			if let s = item.source { Button("주소 복사") { copyToPasteboard(s.absoluteString) } }
			Divider()
			Button("목록에서 지우기") { Downloads.shared.remove(item) }.disabled(item.isActive)
		}
		.help(item.file?.path ?? item.name)
	}

	private var failed: Bool { if case .failed = item.state { true } else { false } }

	private var icon: NSImage {
		if item.state == .finished, let f = item.file, FileManager.default.fileExists(atPath: f.path) {
			return NSWorkspace.shared.icon(forFile: f.path)
		}
		return NSWorkspace.shared.icon(for: UTType(filenameExtension: (item.name as NSString).pathExtension) ?? .data)
	}

	private var detail: String {
		let size = Downloads.size
		var s: String
		switch item.state {
		case .preparing: s = "저장할 곳을 고르는 중"
		case .running: s = item.total > 0 ? "\(size(item.received)) / \(size(item.total))" : size(item.received)
		case .finished: s = size(max(item.total, item.received))
		case .failed(let e): s = "받지 못함 — \(e)"
		case .cancelled: s = "취소됨"
		}
		if let a = item.account, item.state != .running { s += " · \(a)" }
		return s
	}
}
