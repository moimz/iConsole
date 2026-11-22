import SwiftUI

/// 탭 줄 위 즐겨찾기 막대 (Safari 즐겨찾기 막대처럼). 지금 계정의 즐겨찾기만 보인다.
/// 누르면 지금 탭에서 열고, ⌘ 누르고 누르거나 가운데 버튼이면 새 탭. 끌어 순서 바꾸기
struct FavoritesBar: View {
	@Environment(AppModel.self) private var model
	let session: AccountSession
	@State private var reorder = TabReorder<Favorite.ID>()
	@State private var renaming: Favorite?
	@State private var newName = ""

	private var favorites: [Favorite] { model.store.account(session.accountID)?.favorites ?? [] }

	var body: some View {
		HStack(spacing: 0) {
			if favorites.isEmpty {
				Text("주소칸 ☆ · ⌘D · 탭 오른쪽 클릭으로 즐겨찾기를 여기에 추가합니다")
					.font(.caption).foregroundStyle(.tertiary)
					.padding(.horizontal, 12)
				Spacer(minLength: 0)
			} else {
				TabStrip(selected: Optional<Favorite.ID>.none) {
					ForEach(favorites) { f in
						FavoriteItem(favorite: f, open: { newTab in open(f, newTab: newTab) })
							.contextMenu {
								Button("열기") { open(f, newTab: false) }
								Button("새 탭에서 열기") { open(f, newTab: true) }
								Divider()
								Button("이름 바꾸기…") { newName = f.title; renaming = f }
								Button("주소 복사") {
									NSPasteboard.general.clearContents()
									NSPasteboard.general.setString(f.url, forType: .string)
								}
								Divider()
								Button("즐겨찾기에서 빼기", role: .destructive) { model.store.removeFavorite(f.id, from: session.accountID) }
							}
							.reorderable(f.id, order: favorites.map(\.id), state: $reorder) {
								model.store.moveFavorite($0, before: $1, in: session.accountID)
							}
							.id(f.id)
					}
				}
				.animation(.easeOut(duration: 0.18), value: favorites.map(\.id))
			}
		}
		.frame(height: 30)
		.background(Color(nsColor: .underPageBackgroundColor).opacity(0.3), ignoresSafeAreaEdges: [])
		.sheet(item: $renaming) { f in
			NameSheet(title: "즐겨찾기 이름 바꾸기", name: $newName, taken: { _ in false }) {
				model.store.renameFavorite(f.id, in: session.accountID, to: newName)
			}
		}
	}

	private func open(_ f: Favorite, newTab: Bool) {
		guard let u = URL(string: f.url) else { return }
		if !newTab, let t = session.active { t.load(u) } else { session.newTab(u, activate: !newTab || session.active == nil, afterActive: true) }
	}
}

/// 즐겨찾기 하나: [파비콘] 이름
struct FavoriteItem: View {
	let favorite: Favorite
	let open: (_ newTab: Bool) -> Void
	@State private var hover = false

	var body: some View {
		HStack(spacing: 5) {
			FaviconView(url: URL(string: favorite.url), size: 14, fallback: "star")
			Text(favorite.title).lineLimit(1).font(.system(size: 12))
		}
		.padding(.horizontal, 8)
		.frame(height: 22)
		.frame(maxWidth: 200)
		.background(RoundedRectangle(cornerRadius: 5).fill(hover ? Color.primary.opacity(0.08) : .clear))
		.padding(.horizontal, 2)
		.frame(height: 30)
		.contentShape(Rectangle())
		.onHover { hover = $0 }
		// 끌기와 헷갈리지 않게 뗄 때 연다 (TapGesture). ⌘ 누르고 누르면 새 탭
		.onTapGesture { open(NSEvent.modifierFlags.contains(.command)) }
		.background(MiddleClickCatcher { open(true) })
		.help(favorite.url)
	}
}
