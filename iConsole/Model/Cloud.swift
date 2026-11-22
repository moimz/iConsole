import Foundation

/// 계정 목록 파일을 둘 곳 (iSQL Model/Cloud.swift 와 같은 방식).
/// iCloud 를 쓸 수 있으면 iCloud Drive 의 앱 전용 폴더(iCloud.com.moimz.iConsole/Data, Finder 에는 안 보임), 아니면 이 맥 Application Support/iConsole.
/// 계정마다 Accounts/<UUID>.json 하나씩 둬서 두 맥에서 서로 다른 계정을 고쳐도 부딪히지 않는다.
final class StorageLocation: @unchecked Sendable {
	static let containerID = "iCloud.com.moimz.iConsole"
	static let shared = StorageLocation()

	let accounts: URL
	/// 그룹 이름과 순서 (계정이 없는 그룹도 있다)
	let groups: URL
	let isCloud: Bool

	static let local: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
		.appendingPathComponent("iConsole", isDirectory: true)

	private init() {
		let fm = FileManager.default
		var cloud: URL?
		if fm.ubiquityIdentityToken != nil, let c = fm.url(forUbiquityContainerIdentifier: Self.containerID) {
			cloud = c.appendingPathComponent("Data", isDirectory: true)
		}
		let root = cloud ?? Self.local
		accounts = root.appendingPathComponent("Accounts", isDirectory: true)
		groups = root.appendingPathComponent("groups.json")
		isCloud = cloud != nil
		try? fm.createDirectory(at: accounts, withIntermediateDirectories: true)
	}

	/// 아직 내려받지 않은 파일(.이름.json.icloud)의 id. 다시 읽을 때 지워진 것으로 보지 않는다
	func placeholderIDs() -> Set<UUID> {
		guard isCloud else { return [] }
		let names = (try? FileManager.default.contentsOfDirectory(atPath: accounts.path)) ?? []
		return Set(names.compactMap { n in
			guard n.hasPrefix("."), n.hasSuffix(".json.icloud") else { return nil }
			return UUID(uuidString: String(n.dropFirst().dropLast(".json.icloud".count)))
		})
	}

	func downloadAll() {
		for id in placeholderIDs() {
			try? FileManager.default.startDownloadingUbiquitousItem(at: accounts.appendingPathComponent(id.uuidString + ".json"))
		}
		try? FileManager.default.startDownloadingUbiquitousItem(at: groups)
	}

	/// iCloud 가 함께 쓰는 파일이라 조율해서 쓴다
	static func write(_ data: Data, to target: URL) {
		var error: NSError?
		NSFileCoordinator().coordinate(writingItemAt: target, options: .forReplacing, error: &error) { u in
			try? data.write(to: u, options: .atomic)
		}
	}

	static func read(_ target: URL) -> Data? {
		var out: Data?
		var error: NSError?
		NSFileCoordinator().coordinate(readingItemAt: target, options: [], error: &error) { u in
			out = try? Data(contentsOf: u)
		}
		return out
	}

	static func remove(_ target: URL) {
		var error: NSError?
		NSFileCoordinator().coordinate(writingItemAt: target, options: .forDeleting, error: &error) { u in
			try? FileManager.default.removeItem(at: u)
		}
	}
}

/// 다른 맥에서 바뀐 iCloud 파일을 지켜본다: 안 받은 파일은 받고, 충돌은 최근 것으로 정리하고, 바뀌면 알려 준다
final class CloudWatcher: NSObject, @unchecked Sendable {
	static let shared = CloudWatcher()
	private let query = NSMetadataQuery()
	private var onChange: (() -> Void)?
	private var pending: DispatchWorkItem?

	func start(onChange: @escaping () -> Void) {
		guard StorageLocation.shared.isCloud else { return }
		self.onChange = onChange
		query.searchScopes = [NSMetadataQueryUbiquitousDataScope]
		query.predicate = NSPredicate(format: "%K LIKE '*.json'", NSMetadataItemFSNameKey)
		NotificationCenter.default.addObserver(self, selector: #selector(changed), name: .NSMetadataQueryDidFinishGathering, object: query)
		NotificationCenter.default.addObserver(self, selector: #selector(changed), name: .NSMetadataQueryDidUpdate, object: query)
		query.start()
	}

	@objc private func changed() {
		query.disableUpdates()
		for i in 0..<query.resultCount {
			guard let item = query.result(at: i) as? NSMetadataItem, let url = item.value(forAttribute: NSMetadataItemURLKey) as? URL else { continue }
			let status = item.value(forAttribute: NSMetadataUbiquitousItemDownloadingStatusKey) as? String
			if status != NSMetadataUbiquitousItemDownloadingStatusCurrent {
				try? FileManager.default.startDownloadingUbiquitousItem(at: url)
			}
			if (item.value(forAttribute: NSMetadataUbiquitousItemHasUnresolvedConflictsKey) as? Bool) == true {
				Self.resolveConflicts(url)
			}
		}
		query.enableUpdates()
		pending?.cancel()
		let work = DispatchWorkItem { [weak self] in self?.onChange?() }
		pending = work
		DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
	}

	/// 두 맥에서 같은 파일을 고쳤으면 가장 최근에 고친 것을 남긴다
	static func resolveConflicts(_ url: URL) {
		guard let others = NSFileVersion.unresolvedConflictVersionsOfItem(at: url), !others.isEmpty,
		      let current = NSFileVersion.currentVersionOfItem(at: url) else { return }
		let newest = (others + [current]).max { ($0.modificationDate ?? .distantPast) < ($1.modificationDate ?? .distantPast) }!
		if newest != current { _ = try? newest.replaceItem(at: url) }
		for v in others { v.isResolved = true }
		try? NSFileVersion.removeOtherVersionsOfItem(at: url)
	}
}
