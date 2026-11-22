import AppKit
import SwiftUI
import CryptoKit
import Observation

/// 사이트 아이콘(파비콘).
/// 호스트 하나에 아이콘 하나로 두면 AWS 콘솔처럼 한 호스트 안에 서비스마다 아이콘이 다른 곳(Lightsail·S3·결제)에서
/// 마지막에 본 아이콘이 모든 탭·즐겨찾기를 덮었다 (사용자 2026-11-23) →
/// 페이지 열쇠(호스트 + 첫 경로, 예: console.aws.amazon.com/s3) → 그 페이지가 알려 준 아이콘 주소 → 그림.
/// 그림은 iCloud Drive Data/Favicons/<아이콘 주소 SHA256>.png, 페이지 → 아이콘 주소 짝은 pages.json — 맥끼리 같이 쓴다
/// (iVNC 썸네일 iCloud 처럼, 사용자 2026-11-23). 한 맥에서 받은 아이콘을 다른 맥은 그 페이지에 안 가 봐도 보인다
@Observable @MainActor
final class Favicons {
	static let shared = Favicons()
	/// 아이콘 주소 → 그림
	private(set) var images: [String: NSImage] = [:]
	/// 페이지 열쇠 → 아이콘 주소
	private(set) var pages: [String: String] = [:]
	@ObservationIgnored private var loading: Set<String> = []
	@ObservationIgnored private var tried: Set<String> = []

	private static var dir: URL { StorageLocation.shared.favicons }
	private static var pagesFile: URL { dir.appendingPathComponent("pages.json") }

	init() {
		Self.moveOldCache()
		pages = Self.readPages()
	}

	private static func readPages() -> [String: String] {
		StorageLocation.downloadIfPlaceholder(pagesFile)
		guard let d = StorageLocation.read(pagesFile), let p = try? JSONDecoder().decode([String: String].self, from: d) else { return [:] }
		return p
	}

	/// 빌드 13 까지는 이 맥 Caches/iConsole/Favicons 에 뒀다 → iCloud 폴더로 옮긴다
	private static func moveOldCache() {
		let fm = FileManager.default
		let old = fm.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("iConsole/Favicons", isDirectory: true)
		guard old.path != dir.path, fm.fileExists(atPath: old.path) else { return }
		for f in (try? fm.contentsOfDirectory(at: old, includingPropertiesForKeys: nil)) ?? [] where f.pathExtension == "png" {
			let dst = dir.appendingPathComponent(f.lastPathComponent)
			if !fm.fileExists(atPath: dst.path), let d = try? Data(contentsOf: f) { StorageLocation.write(d, to: dst) }
		}
		if let d = try? Data(contentsOf: old.appendingPathComponent("pages.json")), let mine = try? JSONDecoder().decode([String: String].self, from: d) {
			var merged = readPages()
			for (k, v) in mine where merged[k] == nil { merged[k] = v }
			if let out = try? JSONEncoder().encode(merged) { StorageLocation.write(out, to: pagesFile) }
		}
		try? fm.removeItem(at: old)
	}

	/// 다른 맥에서 바뀌면: 짝을 합치고, 그림이 없던 아이콘을 다시 읽어 본다
	func reload() {
		let theirs = Self.readPages()
		if theirs != pages { pages.merge(theirs) { mine, _ in mine } }
		for icon in Set(pages.values) where images[icon] == nil {
			if let d = StorageLocation.read(Self.file(icon)), let i = NSImage(data: d) { images[icon] = i }
		}
	}

	private static func file(_ icon: String) -> URL {
		let h = SHA256.hash(data: Data(icon.utf8)).map { String(format: "%02x", $0) }.joined()
		return dir.appendingPathComponent(h + ".png")
	}

	/// 페이지 열쇠: 호스트 + 첫 경로 (검색어·# 은 뺀다)
	static func key(_ url: URL?) -> String? {
		guard let url, let host = url.host()?.lowercased() else { return nil }
		let first = url.pathComponents.dropFirst().first ?? ""
		return first.isEmpty ? host : host + "/" + first
	}

	/// 그 페이지의 아이콘 (아직 모르면 nil)
	func image(for url: URL?) -> NSImage? {
		guard let k = Self.key(url), let icon = pages[k] else { return nil }
		return image(icon: icon)
	}

	/// 탭이 알고 있는 아이콘 주소로 (페이지 열쇠를 거치지 않는다)
	func image(icon: String) -> NSImage? {
		if let i = images[icon] { return i }
		if !tried.contains(icon) {
			tried.insert(icon)
			Task { @MainActor in
				let f = Self.file(icon)
				if let d = StorageLocation.read(f), let i = NSImage(data: d) { images[icon] = i }
				// 다른 맥이 올린 그림이 아직 안 내려왔으면 받기를 시작 (오면 reload 가 넣는다), 아예 없으면 사이트에서 받는다
				else if StorageLocation.downloadIfPlaceholder(f) { tried.remove(icon) }
				else if let u = URL(string: icon) { fetch(u) }
			}
		}
		return nil
	}

	/// 페이지가 알려 준 아이콘 주소를 그 페이지에 짝지어 두고, 아직 없는 그림이면 받는다
	func record(page: URL, icon: URL) {
		guard let k = Self.key(page) else { return }
		let s = icon.absoluteString
		if pages[k] != s {
			pages[k] = s
			// 다른 맥이 그새 더한 짝을 잃지 않게 파일 것과 합쳐서 쓴다 (이 맥 것이 이긴다)
			var merged = Self.readPages()
			merged.merge(pages) { _, mine in mine }
			pages = merged
			if let d = try? JSONEncoder().encode(merged) { StorageLocation.write(d, to: Self.pagesFile) }
		}
		let f = Self.file(s)
		if images[s] == nil, !FileManager.default.fileExists(atPath: f.path), !StorageLocation.downloadIfPlaceholder(f) { fetch(icon) }
	}

	private func fetch(_ icon: URL) {
		let s = icon.absoluteString
		guard !loading.contains(s) else { return }
		loading.insert(s)
		Task { @MainActor in
			defer { loading.remove(s) }
			guard let (data, resp) = try? await URLSession.shared.data(from: icon),
			      (resp as? HTTPURLResponse)?.statusCode ?? 200 < 400,
			      let img = NSImage(data: data), img.isValid else { return }
			let small = Self.resize(img, to: 32)
			images[s] = small
			if let tiff = small.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff), let png = rep.representation(using: .png, properties: [:]) {
				StorageLocation.write(png, to: Self.file(s))
			}
		}
	}

	private static func resize(_ img: NSImage, to side: CGFloat) -> NSImage {
		let out = NSImage(size: NSSize(width: side, height: side))
		out.lockFocus()
		NSGraphicsContext.current?.imageInterpolation = .high
		img.draw(in: NSRect(x: 0, y: 0, width: side, height: side), from: .zero, operation: .copy, fraction: 1)
		out.unlockFocus()
		return out
	}

	/// 페이지에서 아이콘 주소를 찾는 스크립트 (없으면 /favicon.ico)
	static let finder = """
	(() => {
	  const links = [...document.querySelectorAll('link[rel~="icon"], link[rel="shortcut icon"]')];
	  const png = links.find(l => /png|svg|ico/i.test(l.type + l.href) && !/apple/i.test(l.rel));
	  const best = png || links[0];
	  return best ? best.href : location.origin + '/favicon.ico';
	})()
	"""
}

/// 사이트 아이콘 또는 대신 쓸 기호. icon 이 있으면(탭) 그 아이콘, 없으면 주소로 찾는다(즐겨찾기)
struct FaviconView: View {
	let url: URL?
	var icon: String? = nil
	var size: CGFloat = 14
	var fallback = "globe"

	var body: some View {
		if let img = icon.flatMap({ Favicons.shared.image(icon: $0) }) ?? Favicons.shared.image(for: url) {
			Image(nsImage: img).resizable().interpolation(.high).frame(width: size, height: size)
				.clipShape(RoundedRectangle(cornerRadius: 3))
		} else {
			Image(systemName: fallback).font(.system(size: size * 0.8)).foregroundStyle(.secondary).frame(width: size, height: size)
		}
	}
}
