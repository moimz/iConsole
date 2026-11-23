import Foundation

/// 계정 하나 = 서비스 종류 + 이름 + 아이디 (+ 그룹·즐겨찾기).
/// 암호와 OTP 는 키체인에만 둔다 (Keychain). 계정마다 웹 저장소가 따로다 (WKWebsiteDataStore(forIdentifier: id))
struct Account: Codable, Identifiable, Hashable {
	enum Kind: String, Codable, CaseIterable {
		case aws, google, apple, cloudflare
		/// 사용자 정의: 메인 페이지 · 로그인 주소 · 칸 이름을 직접 정한다
		case custom

		var title: String {
			switch self { case .aws: "아마존"; case .google: "구글"; case .apple: "애플"; case .cloudflare: "Cloudflare"; case .custom: "사용자 정의" }
		}

		/// 비워 둔 시작 주소 대신 여는 곳 (사용자 정의는 시작 주소를 꼭 넣는다)
		var home: URL {
			switch self {
			case .aws: URL(string: "https://console.aws.amazon.com/")!
			case .google: URL(string: "https://console.cloud.google.com/")!
			case .apple: URL(string: "https://developer.apple.com/account")!
			case .cloudflare: URL(string: "https://dash.cloudflare.com/")!
			case .custom: URL(string: "about:blank")!
			}
		}

		/// 아이디·암호·코드를 넘겨줘도 되는 로그인 페이지 주소 (이 도메인이거나 그 하위 도메인). 사용자 정의는 계정의 로그인 주소에서
		var loginHosts: [String] {
			switch self {
			case .aws: ["signin.aws.amazon.com"]
			case .google: ["accounts.google.com"]
			case .apple: ["idmsa.apple.com"]
			case .cloudflare: ["dash.cloudflare.com"]
			case .custom: []
			}
		}

		/// 서비스 아이콘으로 쓰는 그 서비스의 사이트 아이콘 (사이드바 · 계정 폼). 사용자 정의는 시작 주소 페이지의 아이콘
		var iconURL: String? {
			switch self {
			case .aws: "https://a0.awsstatic.com/libra-css/images/site/fav/favicon.ico"
			case .google: "https://www.google.com/favicon.ico"
			case .cloudflare: "https://www.cloudflare.com/favicon.ico"
			case .apple, .custom: nil
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
	/// 사용자 정의: 로그인 페이지 주소 (그 호스트에서만 채운다. 비우면 시작 주소의 호스트)
	var loginURL: String?
	/// 사용자 정의: 칸 이름 (name · id, 또는 #·.·[ 로 시작하는 CSS 선택자). 비우면 자동으로 찾는다
	var userField: String?
	var passField: String?
	var otpField: String?

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
		loginURL = try c.decodeIfPresent(String.self, forKey: .loginURL)
		userField = try c.decodeIfPresent(String.self, forKey: .userField)
		passField = try c.decodeIfPresent(String.self, forKey: .passField)
		otpField = try c.decodeIfPresent(String.self, forKey: .otpField)
	}

	private static func url(_ s: String?) -> URL? {
		guard let s = s?.trimmingCharacters(in: .whitespaces), !s.isEmpty else { return nil }
		return URL(string: s.contains("://") ? s : "https://" + s)
	}

	/// 이 계정의 로그인 칸을 채워도 되는 호스트
	var loginHosts: [String] {
		guard kind == .custom else { return kind.loginHosts }
		return [(Self.url(loginURL) ?? Self.url(start))?.host()?.lowercased()].compactMap { $0 }
	}

	/// 사용자 정의의 칸 이름 (채우기 스크립트로 넘긴다)
	var fields: [String: String] {
		var f: [String: String] = [:]
		for (k, v) in [("user", userField), ("pass", passField), ("otp", otpField)] {
			if let v = v?.trimmingCharacters(in: .whitespaces), !v.isEmpty { f[k] = v }
		}
		return f
	}

	var home: URL { Self.url(start) ?? kind.home }

	var passwordKey: String { "\(id.uuidString).password" }
	var otpKey: String { "\(id.uuidString).otp" }
}

/// 즐겨찾기한 탭 (사이드바에서 계정 아래 펼쳐 보인다)
struct Favorite: Codable, Identifiable, Hashable {
	var id = UUID()
	var title: String
	var url: String
}
