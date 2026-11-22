import Foundation

/// 계정 하나 = 서비스 종류 + 이름 + 아이디 (+ 그룹·즐겨찾기).
/// 암호와 OTP 는 키체인에만 둔다 (Keychain). 계정마다 웹 저장소가 따로다 (WKWebsiteDataStore(forIdentifier: id))
struct Account: Codable, Identifiable, Hashable {
	enum Kind: String, Codable, CaseIterable {
		case aws, google, apple

		var title: String {
			switch self { case .aws: "아마존"; case .google: "구글"; case .apple: "애플" }
		}

		/// 비워 둔 시작 주소 대신 여는 곳
		var home: URL {
			switch self {
			case .aws: URL(string: "https://console.aws.amazon.com/")!
			case .google: URL(string: "https://console.cloud.google.com/")!
			case .apple: URL(string: "https://developer.apple.com/account")!
			}
		}

		/// 아이디·암호·코드를 넘겨줘도 되는 로그인 페이지 주소 (이 도메인이거나 그 하위 도메인)
		var loginHosts: [String] {
			switch self {
			case .aws: ["signin.aws.amazon.com"]
			case .google: ["accounts.google.com"]
			case .apple: ["idmsa.apple.com"]
			}
		}
	}

	var id = UUID()
	var kind: Kind
	var name: String
	var username: String
	/// 콘솔 시작 주소 (비우면 종류별 기본)
	var start: String?
	/// 사이드바 그룹 이름 ("" = 그룹 없음)
	var group = ""
	/// 그룹 안 순서
	var order: Double?
	var favorites: [Favorite] = []

	init(kind: Kind, name: String, username: String) {
		self.kind = kind
		self.name = name
		self.username = username
	}

	/// 시험 앱(빌드 1~5) 때 저장한 계정에는 group·favorites 가 없다
	init(from d: Decoder) throws {
		let c = try d.container(keyedBy: CodingKeys.self)
		id = try c.decode(UUID.self, forKey: .id)
		kind = try c.decode(Kind.self, forKey: .kind)
		name = try c.decode(String.self, forKey: .name)
		username = try c.decode(String.self, forKey: .username)
		start = try c.decodeIfPresent(String.self, forKey: .start)
		group = try c.decodeIfPresent(String.self, forKey: .group) ?? ""
		order = try c.decodeIfPresent(Double.self, forKey: .order)
		favorites = try c.decodeIfPresent([Favorite].self, forKey: .favorites) ?? []
	}

	var home: URL {
		if let s = start?.trimmingCharacters(in: .whitespaces), !s.isEmpty,
		   let u = URL(string: s.contains("://") ? s : "https://" + s) { return u }
		return kind.home
	}

	var passwordKey: String { "\(id.uuidString).password" }
	var otpKey: String { "\(id.uuidString).otp" }
}

/// 즐겨찾기한 탭 (사이드바에서 계정 아래 펼쳐 보인다)
struct Favorite: Codable, Identifiable, Hashable {
	var id = UUID()
	var title: String
	var url: String
}
