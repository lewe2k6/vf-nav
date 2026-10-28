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
        // Giữ màn hình iPhone luôn sáng khi gắn trên giá đỡ xe máy
        UIApplication.shared.isIdleTimerDisabled = true

        // Cho phép phát giọng nói cảnh báo tiếng Việt đè lên nhạc / Google Maps khi chạy nền
        try? AVAudioSession.sharedInstance().setCategory(.playback, options: [.mixWithOthers, .duckOthers])
        try? AVAudioSession.sharedInstance().setActive(true)

        window = UIWindow(frame: UIScreen.main.bounds)
        window?.rootViewController = NavigatorViewController()
        window?.makeKeyAndVisible()
        return true
    }
}

class NavigatorViewController: UIViewController, WKUIDelegate, WKNavigationDelegate, CLLocationManagerDelegate {
    private var webView: WKWebView!
    private let locationManager = CLLocationManager()

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor(red: 0.04, green: 0.05, blue: 0.09, alpha: 1.0)

        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyBestForNavigation
        locationManager.allowsBackgroundLocationUpdates = true
        locationManager.pausesLocationUpdatesAutomatically = false
        locationManager.requestAlwaysAuthorization()
        locationManager.startUpdatingLocation()
        locationManager.startUpdatingHeading()

        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        // Bật quyền gọi trực tiếp API https://escooter-api.vinfast.vn từ file nội bộ trong .ipa mà không bị chặn CORS
        config.preferences.setValue(true, forKey: "allowFileAccessFromFileURLs")
        config.setValue(true, forKey: "allowUniversalAccessFromFileURLs")

        webView = WKWebView(frame: view.bounds, configuration: config)
        webView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        webView.uiDelegate = self
        webView.navigationDelegate = self
        webView.scrollView.bounces = false
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        view.addSubview(webView)

        if let indexURL = Bundle.main.url(forResource: "index", withExtension: "html", subdirectory: "www") {
            webView.loadFileURL(indexURL, allowingReadAccessTo: indexURL.deletingLastPathComponent())
        }
    }

    // Tự động xử lý mở URL scheme comgooglemaps:// sang thẳng App Google Maps thật trên iPhone
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
