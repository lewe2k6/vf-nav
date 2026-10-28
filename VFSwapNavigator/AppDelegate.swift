import UIKit
import WebKit
import CoreLocation
import AVFoundation

@main
class AppDelegate: UIResponder, UIApplicationDelegate {
    var window: UIWindow?

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool {
        // Giữ màn hình iPhone luôn sáng khi dẫn đường
        UIApplication.shared.isIdleTimerDisabled = true

        try? AVAudioSession.sharedInstance().setCategory(.playback, options: [.mixWithOthers, .duckOthers])
        try? AVAudioSession.sharedInstance().setActive(true)

        let win = UIWindow(frame: UIScreen.main.bounds)
        win.backgroundColor = UIColor(red: 0.04, green: 0.05, blue: 0.09, alpha: 1.0)
        win.rootViewController = NavigatorViewController()
        win.makeKeyAndVisible()
        self.window = win
        return true
    }
}

// Custom Scheme Handler (vfapp://) gọi thẳng API VinFast bằng URLSession Native của iOS (quét đồng thời 5 tâm để không sót tủ gần nhất)
class VFSchemeHandler: NSObject, WKURLSchemeHandler {
    private var stoppedTasks = Set<ObjectIdentifier>()
    private let lock = NSLock()

    private func isStopped(_ task: WKURLSchemeTask) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return stoppedTasks.contains(ObjectIdentifier(task as AnyObject))
    }

    private func removeTask(_ task: WKURLSchemeTask) {
        lock.lock()
        stoppedTasks.remove(ObjectIdentifier(task as AnyObject))
        lock.unlock()
    }

    private func makeVinFastRequest(lat: Double, lng: Double) -> URLRequest? {
        let vfUrlStr = String(
            format: "https://escooter-api.vinfast.vn/api-gateway/operation-support/v1.0/battery-swap-stations/near?lat=%.6f&lng=%.6f&distance=5000",
            lat, lng
        )
        guard let vfUrl = URL(string: vfUrlStr) else { return nil }
        var req = URLRequest(url: vfUrl, timeoutInterval: 8)
        req.httpMethod = "GET"
        req.setValue("okhttp/4.9.3", forHTTPHeaderField: "User-Agent")
        req.setValue("ANDROID000JLNINSJFU43VGQY76BGSN9", forHTTPHeaderField: "client_id")
        req.setValue("ANDROID00000JLNINSJFU43VGQY76BGSN945678901234567890123456789654", forHTTPHeaderField: "client_secret")
        req.setValue("2.38.3", forHTTPHeaderField: "app_version")
        req.setValue("Android", forHTTPHeaderField: "platform")
        req.setValue("vi-VN", forHTTPHeaderField: "Accept-Language")
        return req
    }

    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        guard let url = urlSchemeTask.request.url else {
            if !isStopped(urlSchemeTask) {
                urlSchemeTask.didFailWithError(URLError(.badURL))
            }
            return
        }

        if url.path == "/api/near" {
            let comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
            let latStr = comps?.queryItems?.first(where: { $0.name == "lat" })?.value ?? "21.0362"
            let lngStr = comps?.queryItems?.first(where: { $0.name == "lng" })?.value ?? "105.7829"
            let deep = comps?.queryItems?.first(where: { $0.name == "deep" })?.value == "1"
            let baseLat = Double(latStr) ?? 21.0362
            let baseLng = Double(lngStr) ?? 105.7829

            // Khi deep=1 (quét lần đầu hoặc khi đổi vị trí), quét 5 tâm (tâm chính + 4 hướng bán kính ~1.6km) để lấy 100% các tủ sát cạnh
            var points: [(Double, Double)] = [(baseLat, baseLng)]
            if deep {
                let d = 0.015
                points.append((baseLat + d, baseLng))
                points.append((baseLat - d, baseLng))
                points.append((baseLat, baseLng + d))
                points.append((baseLat, baseLng - d))
            }

            let group = DispatchGroup()
            let mergeLock = NSLock()
            var seenCodes = Set<String>()
            var mergedStations = [[String: Any]]()

            for pt in points {
                guard let req = makeVinFastRequest(lat: pt.0, lng: pt.1) else { continue }
                group.enter()
                URLSession.shared.dataTask(with: req) { data, _, _ in
                    defer { group.leave() }
                    guard let data = data,
                          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                          let arr = json["data"] as? [[String: Any]] else { return }
                    mergeLock.lock()
                    for item in arr {
                        let code = (item["code"] as? String) ?? UUID().uuidString
                        if !seenCodes.contains(code) {
                            seenCodes.insert(code)
                            mergedStations.append(item)
                        }
                    }
                    mergeLock.unlock()
                }.resume()
            }

            group.notify(queue: .global(qos: .userInitiated)) { [weak self] in
                guard let self = self, !self.isStopped(urlSchemeTask) else { return }
                defer { self.removeTask(urlSchemeTask) }

                let payload: [String: Any] = ["data": mergedStations]
                let body = (try? JSONSerialization.data(withJSONObject: payload)) ?? Data("{\"data\":[]}".utf8)
                let resp = HTTPURLResponse(
                    url: url,
                    statusCode: 200,
                    httpVersion: "HTTP/1.1",
                    headerFields: [
                        "Content-Type": "application/json; charset=utf-8",
                        "Access-Control-Allow-Origin": "*"
                    ]
                )!
                urlSchemeTask.didReceive(resp)
                urlSchemeTask.didReceive(body)
                urlSchemeTask.didFinish()
            }
            return
        }

        // Mặc định trả về giao diện HTML chính từ Bundle
        let htmlPath = Bundle.main.path(forResource: "index", ofType: "html", inDirectory: "www")
            ?? Bundle.main.path(forResource: "index", ofType: "html")
        let htmlData = (htmlPath != nil ? try? Data(contentsOf: URL(fileURLWithPath: htmlPath!)) : nil) ?? Data("<h1>Missing index.html</h1>".utf8)
        let resp = HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "text/html; charset=utf-8"]
        )!
        if !isStopped(urlSchemeTask) {
            urlSchemeTask.didReceive(resp)
            urlSchemeTask.didReceive(htmlData)
            urlSchemeTask.didFinish()
        }
        removeTask(urlSchemeTask)
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {
        lock.lock()
        stoppedTasks.insert(ObjectIdentifier(urlSchemeTask as AnyObject))
        lock.unlock()
    }
}

class NavigatorViewController: UIViewController, WKUIDelegate, WKNavigationDelegate, WKScriptMessageHandler, CLLocationManagerDelegate {
    private var webView: WKWebView!
    private let locationManager = CLLocationManager()
    private let synthesizer = AVSpeechSynthesizer()
    private var lastLat: Double = 0.0
    private var lastLng: Double = 0.0
    private var lastHeading: Double = 0.0
    private var lastSpeed: Double = 0.0
    private var lastAccuracy: Double = 9999.0
    private var hasRealGps: Bool = false

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor(red: 0.04, green: 0.05, blue: 0.09, alpha: 1.0)

        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        config.setURLSchemeHandler(VFSchemeHandler(), forURLScheme: "vfapp")
        config.userContentController.add(self, name: "nativeSpeak")
        config.userContentController.add(self, name: "requestGps")

        webView = WKWebView(frame: .zero, configuration: config)
        webView.translatesAutoresizingMaskIntoConstraints = false
        webView.uiDelegate = self
        webView.navigationDelegate = self
        webView.isOpaque = false
        webView.backgroundColor = UIColor(red: 0.04, green: 0.05, blue: 0.09, alpha: 1.0)
        webView.scrollView.backgroundColor = UIColor(red: 0.04, green: 0.05, blue: 0.09, alpha: 1.0)
        webView.scrollView.bounces = false
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        view.addSubview(webView)

        // Ghim chặt WebView tràn 100% toàn màn hình (từ mép trên cùng Dynamic Island xuống tận đáy màn hình)
        NSLayoutConstraint.activate([
            webView.topAnchor.constraint(equalTo: view.topAnchor),
            webView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            webView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: view.trailingAnchor)
        ])

        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyBestForNavigation
        locationManager.distanceFilter = kCLDistanceFilterNone
        locationManager.requestWhenInUseAuthorization()
        locationManager.startUpdatingLocation()
        locationManager.startUpdatingHeading()

        if let startUrl = URL(string: "vfapp://app/index.html") {
            webView.load(URLRequest(url: startUrl))
        }
    }

    private func pushGpsToWebView() {
        guard hasRealGps else { return }
        let js = String(
            format: "if(window.onNativeGps){window.onNativeGps(%.7f,%.7f,%.2f,%.2f,%.1f);}",
            lastLat, lastLng, lastHeading, lastSpeed, lastAccuracy
        )
        DispatchQueue.main.async { [weak self] in
            self?.webView?.evaluateJavaScript(js, completionHandler: nil)
        }
    }

    // Nhận lệnh từ JS: đọc giọng nói Tiếng Việt hoặc ép cập nhật lại GPS ngay lập tức
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        if message.name == "nativeSpeak", let text = message.body as? String {
            if synthesizer.isSpeaking {
                synthesizer.stopSpeaking(at: .immediate)
            }
            let utter = AVSpeechUtterance(string: text)
            utter.voice = AVSpeechSynthesisVoice(language: "vi-VN")
            utter.rate = 0.52
            synthesizer.speak(utter)
        } else if message.name == "requestGps" {
            locationManager.requestWhenInUseAuthorization()
            locationManager.startUpdatingLocation()
            locationManager.startUpdatingHeading()
            pushGpsToWebView()
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        // Ngay khi trang HTML vừa tải xong, bơm ngay tọa độ GPS thật vào bản đồ
        pushGpsToWebView()
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        manager.startUpdatingLocation()
        manager.startUpdatingHeading()
    }

    // Bơm trực tiếp tọa độ GPS chính xác từ phần cứng iPhone vào bản đồ 3D
    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let loc = locations.last else { return }
        // Bỏ qua các tọa độ rác không hợp lệ (horizontalAccuracy < 0)
        guard loc.horizontalAccuracy >= 0 else { return }

        lastLat = loc.coordinate.latitude
        lastLng = loc.coordinate.longitude
        lastAccuracy = loc.horizontalAccuracy
        if loc.course >= 0 {
            lastHeading = loc.course
        }
        lastSpeed = max(0.0, loc.speed)
        hasRealGps = true
        pushGpsToWebView()
    }

    func locationManager(_ manager: CLLocationManager, didUpdateHeading newHeading: CLHeading) {
        let h = newHeading.trueHeading >= 0 ? newHeading.trueHeading : newHeading.magneticHeading
        if h >= 0 {
            lastHeading = h
            let js = String(format: "if(window.onNativeHeading){window.onNativeHeading(%.2f);}", lastHeading)
            webView.evaluateJavaScript(js, completionHandler: nil)
        }
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        if let url = navigationAction.request.url,
           let scheme = url.scheme?.lowercased(),
           scheme == "comgooglemaps" {
            UIApplication.shared.open(url, options: [:], completionHandler: nil)
            decisionHandler(.cancel)
            return
        }
        decisionHandler(.allow)
    }

    override var preferredStatusBarStyle: UIStatusBarStyle {
        return .lightContent
    }
}
