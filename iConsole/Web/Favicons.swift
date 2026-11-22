import AppKit
import SwiftUI
import CryptoKit
import Observation

/// 사이트 아이콘(파비콘).
/// 호스트 하나에 아이콘 하나로 두면 AWS 콘솔처럼 한 호스트 안에 서비스마다 아이콘이 다른 곳(Lightsail·S3·결제)에서
/// 마지막에 본 아이콘이 모든 탭·즐겨찾기를 덮었다 (사용자 2026-11-23) →
/// 페이지 열쇠(호스트 + 첫 경로, 예: console.aws.amazon.com/s3) → 그 페이지가 알려 준 아이콘 주소 → 그림.
/// 그림은 이 맥 Caches/iConsole/Favicons/<아이콘 주소 SHA256>.png, 페이지 → 아이콘 주소 짝은 pages.json
@Observable @MainActor
final class Favicons {
	static let shared = Favicons()
	/// 아이콘 주소 → 그림
	private(set) var images: [String: NSImage] = [:]
	/// 페이지 열쇠 → 아이콘 주소
	private(set) var pages: [String: String] = [:]
	@ObservationIgnored private var loading: Set<String> = []
	@ObservationIgnored private var tried: Set<String> = []

	private static let dir: URL = {
		let d = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("iConsole/Favicons", isDirectory: true)
		try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
		return d
	}()
	private static var pagesFile: URL { dir.appendingPathComponent("pages.json") }

	init() {
		if let d = try? Data(contentsOf: Self.pagesFile), let p = try? JSONDecoder().decode([String: String].self, from: d) { pages = p }
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
				if let i = NSImage(contentsOf: Self.file(icon)) { images[icon] = i }
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
			try? JSONEncoder().encode(pages).write(to: Self.pagesFile, options: .atomic)
		}
		if images[s] == nil, !FileManager.default.fileExists(atPath: Self.file(s).path) { fetch(icon) }
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
				try? png.write(to: Self.file(s), options: .atomic)
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
