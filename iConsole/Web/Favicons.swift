import AppKit
import SwiftUI
import Observation

/// 사이트 아이콘(파비콘). 호스트마다 하나 (같은 사이트의 페이지는 거의 같은 아이콘).
/// 페이지를 다 읽으면 그 페이지의 <link rel="icon"> 주소를 받아 내려받고, 이 맥 Caches/iConsole/Favicons/<호스트>.png 에 둔다
@Observable @MainActor
final class Favicons {
	static let shared = Favicons()
	private(set) var images: [String: NSImage] = [:]
	@ObservationIgnored private var loading: Set<String> = []
	@ObservationIgnored private var tried: Set<String> = []

	private static let dir: URL = {
		let d = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("iConsole/Favicons", isDirectory: true)
		try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
		return d
	}()

	private static func file(_ host: String) -> URL { dir.appendingPathComponent(host + ".png") }

	/// 그 주소의 아이콘 (없으면 디스크에서 찾고, 그래도 없으면 /favicon.ico 를 한 번 받아 본다)
	func image(for url: URL?) -> NSImage? {
		guard let host = url?.host()?.lowercased() else { return nil }
		if let i = images[host] { return i }
		if !tried.contains(host) {
			tried.insert(host)
			Task { @MainActor in
				if let i = NSImage(contentsOf: Self.file(host)) { images[host] = i }
				else if let origin = URL(string: "https://\(host)/favicon.ico") { fetch(origin, host: host) }
			}
		}
		return nil
	}

	/// 페이지가 알려 준 아이콘 주소로 받는다 (이미 받아 둔 호스트도 새것으로 바꾼다)
	func fetch(_ icon: URL, host: String) {
		let host = host.lowercased()
		guard !loading.contains(host) else { return }
		loading.insert(host)
		Task { @MainActor in
			defer { loading.remove(host) }
			guard let (data, resp) = try? await URLSession.shared.data(from: icon),
			      (resp as? HTTPURLResponse)?.statusCode ?? 200 < 400,
			      let img = NSImage(data: data), img.isValid else { return }
			let small = Self.resize(img, to: 32)
			images[host] = small
			if let tiff = small.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff), let png = rep.representation(using: .png, properties: [:]) {
				try? png.write(to: Self.file(host), options: .atomic)
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

/// 사이트 아이콘 또는 대신 쓸 기호
struct FaviconView: View {
	let url: URL?
	var size: CGFloat = 14
	var fallback = "globe"

	var body: some View {
		if let img = Favicons.shared.image(for: url) {
			Image(nsImage: img).resizable().interpolation(.high).frame(width: size, height: size)
				.clipShape(RoundedRectangle(cornerRadius: 3))
		} else {
			Image(systemName: fallback).font(.system(size: size * 0.8)).foregroundStyle(.secondary).frame(width: size, height: size)
		}
	}
}
