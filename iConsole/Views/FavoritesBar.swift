import SwiftUI

/// 탭 줄 위 즐겨찾기 막대 (Safari 즐겨찾기 막대처럼). 지금 계정의 즐겨찾기만 보인다.
/// 누르면 지금 탭에서 열고, ⌘ 누르고 누르거나 가운데 버튼이면 새 탭. 끌어 순서 바꾸기
struct FavoritesBar: View {
	@Environment(AppModel.self) private var model
	let session: AccountSession
	@State private var reorder = TabReorder<Favorite.ID>()

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
								Button("편집…") { model.favoriteDraft = FavoriteDraft(accountID: session.accountID, favorite: f, isNew: false) }
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
		// 바깥 4 + 안 8 = 12: 첫 즐겨찾기 아이콘이 아래 탭 아이콘(왼쪽 12)과 같은 줄에 선다
		.padding(.horizontal, 4)
		.frame(height: 30)
		.contentShape(Rectangle())
		.onHover { hover = $0 }
		// 끌기와 헷갈리지 않게 뗄 때 연다 (TapGesture). ⌘ 누르고 누르면 새 탭
		.onTapGesture { open(NSEvent.modifierFlags.contains(.command)) }
		.background(MiddleClickCatcher { open(true) })
		.help(favorite.url)
	}
}

/// 즐겨찾기 추가·편집 시트 (제목바 아래로 붙는다). 추가할 때는 사이트 제목·지금 주소를 채워 두고, 고친 뒤 추가
struct FavoriteSheet: View {
	@Environment(AppModel.self) private var model
	@Environment(\.dismiss) private var dismiss
	let draft: FavoriteDraft
	@State private var title = ""
	@State private var url = ""
	@FocusState private var focused: Bool

	private var trimmedURL: String { url.trimmingCharacters(in: .whitespaces) }
	private var valid: Bool {
		!title.trimmingCharacters(in: .whitespaces).isEmpty && URL(string: trimmedURL)?.scheme != nil
	}

	var body: some View {
		VStack(alignment: .leading, spacing: 14) {
			Text(draft.isNew ? "즐겨찾기에 추가" : "즐겨찾기 편집").font(.headline)
			Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 10) {
				GridRow {
					Text("이름:").gridColumnAlignment(.trailing)
					TextField("", text: $title).textFieldStyle(.roundedBorder).focused($focused).onSubmit(save)
				}
				GridRow {
					Text("주소:")
					TextField("", text: $url).textFieldStyle(.roundedBorder).onSubmit(save)
				}
			}
			HStack {
				if !draft.isNew {
					Button("즐겨찾기에서 빼기", role: .destructive) {
						model.store.removeFavorite(draft.favorite.id, from: draft.accountID)
						dismiss()
					}
				}
				Spacer()
				Button("취소", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
				Button(draft.isNew ? "추가" : "저장", action: save)
					.keyboardShortcut(.defaultAction)
					.buttonStyle(.borderedProminent)
					.disabled(!valid)
			}
			.controlSize(.large)
		}
		.padding(20)
		.frame(width: 520)
		.onAppear {
			title = draft.favorite.title
			url = draft.favorite.url
			focused = true
		}
	}

	private func save() {
		guard valid else { return }
		var f = draft.favorite
		f.title = title.trimmingCharacters(in: .whitespaces)
		f.url = trimmedURL
		if draft.isNew { model.store.addFavorite(f, to: draft.accountID) } else { model.store.updateFavorite(f, in: draft.accountID) }
		dismiss()
	}
}
