import SwiftUI

/// 탭 줄 아래 찾기 줄 (Safari 처럼): [🔍 찾을 글자  3/12] [‹ ›] [완료]
/// Return 다음 · ⇧Return 이전 · Esc 닫기
struct FindBar: View {
	@Bindable private var finder = PageFinder.shared
	@FocusState private var focused: Bool

	var body: some View {
		HStack(spacing: 8) {
			Spacer()
			HStack(spacing: 4) {
				Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
				TextField("페이지에서 찾기", text: $finder.text)
					.textFieldStyle(.plain)
					.focused($focused)
					.onKeyPress(.return, phases: .down) { k in finder.step(k.modifiers.contains(.shift) ? -1 : 1); return .handled }
					.onExitCommand { finder.hide() }
				if !finder.text.isEmpty {
					Text(finder.count == 0 ? "없음" : "\(finder.index)/\(finder.count)")
						.font(.caption).monospacedDigit()
						.foregroundStyle(finder.count == 0 ? .red : .secondary)
				}
			}
			.padding(.horizontal, 7)
			.frame(width: 300, height: 24)
			.background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
			.overlay(RoundedRectangle(cornerRadius: 6).stroke(focused ? Color.accentColor : Color.secondary.opacity(0.3), lineWidth: focused ? 2 : 1))
			ControlGroup {
				Button { finder.step(-1) } label: { Image(systemName: "chevron.left") }.help("이전 (⇧⌘G)")
				Button { finder.step(1) } label: { Image(systemName: "chevron.right") }.help("다음 (⌘G)")
			}
			.disabled(finder.count == 0)
			.frame(width: 64)
			Button("완료") { finder.hide() }
		}
		.controlSize(.small)
		.padding(.horizontal, 12)
		.frame(height: 34)
		.background(Color(nsColor: .underPageBackgroundColor).opacity(0.5), ignoresSafeAreaEdges: [])
		.onAppear { focusField() }
		.onChange(of: finder.focus) { focusField() }
	}

	/// ⌘F 를 다시 누르면 칸에 포커스 + 글자 모두 고르기 (Safari 처럼 바로 새로 칠 수 있게)
	private func focusField() {
		focused = true
		DispatchQueue.main.async { NSApp.keyWindow?.firstResponder.flatMap { $0 as? NSTextView }?.selectAll(nil) }
	}
}
