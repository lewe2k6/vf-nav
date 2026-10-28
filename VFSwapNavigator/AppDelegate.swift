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
        win.rootViewController = NavigatorViewController()
        win.makeKeyAndVisible()
        self.window = win
        return true
    }
}

// Custom Scheme Handler (vfapp://) giúp gọi thẳng API VinFast bằng URLSession Native của iOS (0 bao giờ dính CORS hay KVC crash)
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

    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        guard let url = urlSchemeTask.request.url else {
            if !isStopped(urlSchemeTask) {
                urlSchemeTask.didFailWithError(URLError(.badURL))
            }
            return
        }

        if url.path == "/api/near" {
            let comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
            let lat = comps?.queryItems?.first(where: { $0.name == "lat" })?.value ?? "21.0362"
            let lng = comps?.queryItems?.first(where: { $0.name == "lng" })?.value ?? "105.7829"

            let vfUrlStr = "https://escooter-api.vinfast.vn/api-gateway/operation-support/v1.0/battery-swap-stations/near?lat=\(lat)&lng=\(lng)&distance=5000"
            guard let vfUrl = URL(string: vfUrlStr) else {
                if !isStopped(urlSchemeTask) {
                    urlSchemeTask.didFailWithError(URLError(.badURL))
                }
                return
            }

            var req = URLRequest(url: vfUrl, timeoutInterval: 10)
            req.httpMethod = "GET"
            req.setValue("okhttp/4.9.3", forHTTPHeaderField: "User-Agent")
            req.setValue("ANDROID000JLNINSJFU43VGQY76BGSN9", forHTTPHeaderField: "client_id")
            req.setValue("ANDROID00000JLNINSJFU43VGQY76BGSN945678901234567890123456789654", forHTTPHeaderField: "client_secret")
            req.setValue("2.38.3", forHTTPHeaderField: "app_version")
            req.setValue("Android", forHTTPHeaderField: "platform")
            req.setValue("vi-VN", forHTTPHeaderField: "Accept-Language")

            URLSession.shared.dataTask(with: req) { [weak self] data, _, error in
                guard let self = self, !self.isStopped(urlSchemeTask) else { return }
                defer { self.removeTask(urlSchemeTask) }

                if let error = error {
                    urlSchemeTask.didFailWithError(error)
                    return
                }
                let body = data ?? Data("{\"data\":[]}".utf8)
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
            }.resume()
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
    private var lastLat: Double = 21.0362
    private var lastLng: Double = 105.7829
    private var lastHeading: Double = 0.0

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor(red: 0.04, green: 0.05, blue: 0.09, alpha: 1.0)

        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        config.setURLSchemeHandler(VFSchemeHandler(), forURLScheme: "vfapp")
        config.userContentController.add(self, name: "nativeSpeak")

        webView = WKWebView(frame: view.bounds, configuration: config)
        webView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        webView.uiDelegate = self
        webView.navigationDelegate = self
        webView.scrollView.bounces = false
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        view.addSubview(webView)

        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyBestForNavigation
        locationManager.requestWhenInUseAuthorization()
        locationManager.startUpdatingLocation()
        locationManager.startUpdatingHeading()

        if let startUrl = URL(string: "vfapp://app/index.html") {
            webView.load(URLRequest(url: startUrl))
        }
    }

    // Nhận lệnh đọc giọng nói Tiếng Việt trực tiếp từ JS qua AVSpeechSynthesizer của iOS
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        if message.name == "nativeSpeak", let text = message.body as? String {
            if synthesizer.isSpeaking {
                synthesizer.stopSpeaking(at: .immediate)
            }
            let utter = AVSpeechUtterance(string: text)
            utter.voice = AVSpeechSynthesisVoice(language: "vi-VN")
            utter.rate = 0.52
            synthesizer.speak(utter)
        }
    }

    // Bơm trực tiếp tọa độ GPS + Góc La Bàn từ phần cứng iPhone vào bản đồ 3D
    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let loc = locations.last else { return }
        lastLat = loc.coordinate.latitude
        lastLng = loc.coordinate.longitude
        if loc.course >= 0 {
            lastHeading = loc.course
        }
        let speed = max(0.0, loc.speed)
        let js = "if(window.onNativeGps){window.onNativeGps(\(lastLat),\(lastLng),\(lastHeading),\(speed));}"
        webView.evaluateJavaScript(js, completionHandler: nil)
    }

    func locationManager(_ manager: CLLocationManager, didUpdateHeading newHeading: CLHeading) {
        let h = newHeading.trueHeading >= 0 ? newHeading.trueHeading : newHeading.magneticHeading
        if h >= 0 {
            lastHeading = h
            let js = "if(window.onNativeHeading){window.onNativeHeading(\(lastHeading));}"
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
