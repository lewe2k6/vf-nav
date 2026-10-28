import UIKit
import CoreLocation
import AVFoundation
import UserNotifications

struct SwapStation {
    let code: String
    let name: String
    let address: String
    let commune: String
    let lat: Double
    let lng: Double
    let avail: Int
    let total: Int
    let status: String
    var straightKm: Double
    var distanceKm: Double
    var durationMin: Int?
    var score: Double

    var googleMapsAppUrl: URL? {
        URL(string: String(format: "comgooglemaps://?daddr=%.6f,%.6f&directionsmode=two-wheeler", lat, lng))
    }

    var googleMapsWebUrl: URL? {
        URL(string: String(format: "https://www.google.com/maps/dir/?api=1&destination=%.6f,%.6f&travelmode=two-wheeler", lat, lng))
    }
}

@main
class AppDelegate: UIResponder, UIApplicationDelegate {
    var window: UIWindow?

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool {
        UIApplication.shared.isIdleTimerDisabled = true

        let win = UIWindow(frame: UIScreen.main.bounds)
        win.backgroundColor = UIColor(red: 0.04, green: 0.06, blue: 0.10, alpha: 1.0)
        let navVC = RadarViewController()
        win.rootViewController = navVC
        win.makeKeyAndVisible()
        self.window = win
        return true
    }
}

class RadarViewController: UIViewController, CLLocationManagerDelegate, UNUserNotificationCenterDelegate {
    private let locationManager = CLLocationManager()
    private let synthesizer = AVSpeechSynthesizer()
    private var silentPlayer: AVAudioPlayer?
    private var cronTimer: Timer?
    private var bgTask: UIBackgroundTaskIdentifier = .invalid

    // Trạng thái GPS & Trạm
    private var userLat: Double = 0.0
    private var userLng: Double = 0.0
    private var userAccuracy: Double = 9999.0
    private var hasRealGps: Bool = false
    private var lastLockedLat: Double = 0.0
    private var lastLockedLng: Double = 0.0
    private var bestAccuracyAtLock: Double = 9999.0

    private var minPinsRequired: Int = 2
    private var lockedStation: SwapStation?
    private var topStations: [SwapStation] = []
    private var blacklistedCodes = Set<String>()
    private var simulatedEmptyCodes = Set<String>()
    private var isChecking: Bool = false
    private var cronCount: Int = 0
    private var pendingAutoOpenGoogleMaps: Bool = false

    // Giao diện Native UIKit
    private let statusBadge = UILabel()
    private let gpsLabel = UILabel()
    private let targetTitleLabel = UILabel()
    private let targetNameLabel = UILabel()
    private let targetAddrLabel = UILabel()
    private let targetPinBadge = UILabel()
    private let targetDistLabel = UILabel()
    private let btnFilterPins = UIButton(type: .system)
    private let btnOpenGMaps = UIButton(type: .system)
    private let btnTestBgReroute = UIButton(type: .system)
    private let btnSkipStation = UIButton(type: .system)
    private let top5Stack = UIStackView()

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor(red: 0.04, green: 0.06, blue: 0.10, alpha: 1.0)

        setupAudioKeepAlive()
        setupNotifications()
        setupUI()
        setupLocation()
        startCronTimer()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appDidEnterBackground),
            name: UIApplication.didEnterBackgroundNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appDidBecomeActive),
            name: UIApplication.didBecomeActiveNotification,
            object: nil
        )
    }

    // MARK: - 1. SILENT AUDIO KEEP-ALIVE (Giữ Cron 3s sống 100% khi đang mở Google Maps)
    private func setupAudioKeepAlive() {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try session.setActive(true)

            let wavData = makeSilentWavData()
            let player = try AVAudioPlayer(data: wavData)
            player.numberOfLoops = -1
            player.volume = 0.01
            player.prepareToPlay()
            player.play()
            self.silentPlayer = player
        } catch {}
    }

    private func makeSilentWavData() -> Data {
        let sampleRate: UInt32 = 8000
        let numSamples: UInt32 = 8000
        let dataSize: UInt32 = numSamples * 2
        let fileSize: UInt32 = 36 + dataSize

        var data = Data()
        data.append(contentsOf: [0x52, 0x49, 0x46, 0x46]) // "RIFF"
        var leFileSize = fileSize.littleEndian
        data.append(Data(bytes: &leFileSize, count: 4))
        data.append(contentsOf: [0x57, 0x41, 0x56, 0x45]) // "WAVE"
        data.append(contentsOf: [0x66, 0x6D, 0x74, 0x20]) // "fmt "

        var fmtChunkSize: UInt32 = 16.littleEndian
        var audioFormat: UInt16 = 1.littleEndian
        var numChannels: UInt16 = 1.littleEndian
        var leSampleRate = sampleRate.littleEndian
        var byteRate: UInt32 = (sampleRate * 2).littleEndian
        var blockAlign: UInt16 = 2.littleEndian
        var bitsPerSample: UInt16 = 16.littleEndian

        data.append(Data(bytes: &fmtChunkSize, count: 4))
        data.append(Data(bytes: &audioFormat, count: 2))
        data.append(Data(bytes: &numChannels, count: 2))
        data.append(Data(bytes: &leSampleRate, count: 4))
        data.append(Data(bytes: &byteRate, count: 4))
        data.append(Data(bytes: &blockAlign, count: 2))
        data.append(Data(bytes: &bitsPerSample, count: 2))

        data.append(contentsOf: [0x64, 0x61, 0x74, 0x61]) // "data"
        var leDataSize = dataSize.littleEndian
        data.append(Data(bytes: &leDataSize, count: 4))
        data.append(Data(count: Int(dataSize)))
        return data
    }

    @objc private func appDidEnterBackground() {
        if silentPlayer?.isPlaying != true {
            silentPlayer?.play()
        }
        bgTask = UIApplication.shared.beginBackgroundTask(withName: "VFSwapCron") { [weak self] in
            if let task = self?.bgTask, task != .invalid {
                UIApplication.shared.endBackgroundTask(task)
                self?.bgTask = .invalid
            }
        }
    }

    @objc private func appDidBecomeActive() {
        if bgTask != .invalid {
            UIApplication.shared.endBackgroundTask(bgTask)
            bgTask = .invalid
        }
        // Nếu vừa có thông báo đổi tủ khi đang xem Google Maps và người dùng chạm vào thông báo/quay lại app -> Nhảy thẳng sang Google Maps tủ mới!
        if pendingAutoOpenGoogleMaps, let st = lockedStation {
            pendingAutoOpenGoogleMaps = false
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
                self?.openInGoogleMaps(station: st)
            }
        }
    }

    // MARK: - 2. THÔNG BÁO BÁO ĐỘNG ĐÈ LÊN GOOGLE MAPS
    private func setupNotifications() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    private func sendRerouteNotification(oldName: String, newStation: SwapStation) {
        let content = UNMutableNotificationContent()
        content.title = "⚠️ TỦ ĐANG ĐI ĐÃ HẾT PIN! CHẠM ĐỂ ĐỔI HƯỚNG"
        let durText = newStation.durationMin != nil ? " (~\(newStation.durationMin!)p)" : ""
        content.body = "Đã khóa tủ mới: \(newStation.name) [\(newStation.avail)/\(newStation.total) PIN • \(newStation.distanceKm)km\(durText)]. Chạm vào đây để cập nhật Google Maps ngay!"
        content.sound = .default
        content.userInfo = ["code": newStation.code]

        let req = UNNotificationRequest(identifier: "VF_REROUTE_\(UUID().uuidString)", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req, withCompletionHandler: nil)
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        if #available(iOS 14.0, *) {
            completionHandler([.banner, .sound, .list])
        } else {
            completionHandler([.alert, .sound])
        }
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        pendingAutoOpenGoogleMaps = false
        if let st = lockedStation {
            DispatchQueue.main.async { [weak self] in
                self?.openInGoogleMaps(station: st)
            }
        }
        completionHandler()
    }

    private func speakVietnamese(_ text: String) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, options: [.mixWithOthers, .duckOthers])
            try? AVAudioSession.sharedInstance().setActive(true)
            if self.synthesizer.isSpeaking {
                self.synthesizer.stopSpeaking(at: .immediate)
            }
            let utter = AVSpeechUtterance(string: text)
            utter.voice = AVSpeechSynthesisVoice(language: "vi-VN")
            utter.rate = 0.52
            self.synthesizer.speak(utter)
        }
    }

    // MARK: - 3. GIAO DIỆN NATIVE UIKIT 100% TOÀN MÀN HÌNH
    private func setupUI() {
        let scroll = UIScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.alwaysBounceVertical = true
        view.addSubview(scroll)

        let content = UIStackView()
        content.axis = .vertical
        content.spacing = 12
        content.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(content)

        let safe = view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: safe.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: safe.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: safe.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: safe.trailingAnchor),

            content.topAnchor.constraint(equalTo: scroll.topAnchor, constant: 12),
            content.bottomAnchor.constraint(equalTo: scroll.bottomAnchor, constant: -24),
            content.leadingAnchor.constraint(equalTo: scroll.leadingAnchor, constant: 14),
            content.trailingAnchor.constraint(equalTo: scroll.trailingAnchor, constant: -14),
            content.widthAnchor.constraint(equalTo: scroll.widthAnchor, constant: -28)
        ])

        // Header Row
        let headerRow = UIStackView()
        headerRow.axis = .horizontal
        headerRow.alignment = .center
        headerRow.distribution = .equalSpacing

        statusBadge.text = "🟢 CANH PIN NGẦM 3s (#0)"
        statusBadge.font = UIFont.systemFont(ofSize: 13, weight: .heavy)
        statusBadge.textColor = UIColor(red: 0.20, green: 0.90, blue: 0.60, alpha: 1.0)

        let rightBtns = UIStackView()
        rightBtns.axis = .horizontal
        rightBtns.spacing = 8

        btnFilterPins.setTitle(">= 2 PIN", for: .normal)
        btnFilterPins.titleLabel?.font = UIFont.systemFont(ofSize: 12, weight: .bold)
        btnFilterPins.backgroundColor = UIColor(red: 0.12, green: 0.18, blue: 0.28, alpha: 1.0)
        btnFilterPins.setTitleColor(.white, for: .normal)
        btnFilterPins.layer.cornerRadius = 8
        btnFilterPins.contentEdgeInsets = UIEdgeInsets(top: 7, left: 10, bottom: 7, right: 10)
        btnFilterPins.addTarget(self, action: #selector(onTapFilterPins), for: .touchUpInside)

        let btnRefreshGps = UIButton(type: .system)
        btnRefreshGps.setTitle("↻ GPS Mới", for: .normal)
        btnRefreshGps.titleLabel?.font = UIFont.systemFont(ofSize: 12, weight: .heavy)
        btnRefreshGps.backgroundColor = UIColor(red: 0.06, green: 0.72, blue: 0.50, alpha: 1.0)
        btnRefreshGps.setTitleColor(UIColor(red: 0.02, green: 0.18, blue: 0.10, alpha: 1.0), for: .normal)
        btnRefreshGps.layer.cornerRadius = 8
        btnRefreshGps.contentEdgeInsets = UIEdgeInsets(top: 7, left: 11, bottom: 7, right: 11)
        btnRefreshGps.addTarget(self, action: #selector(onTapRefreshGps), for: .touchUpInside)

        rightBtns.addArrangedSubview(btnFilterPins)
        rightBtns.addArrangedSubview(btnRefreshGps)

        headerRow.addArrangedSubview(statusBadge)
        headerRow.addArrangedSubview(rightBtns)
        content.addArrangedSubview(headerRow)

        // GPS Label
        gpsLabel.text = "📍 Đang lấy tọa độ GPS vệ tinh chính xác từ iPhone..."
        gpsLabel.font = UIFont.systemFont(ofSize: 12, weight: .medium)
        gpsLabel.textColor = UIColor(red: 0.58, green: 0.64, blue: 0.72, alpha: 1.0)
        gpsLabel.numberOfLines = 2
        content.addArrangedSubview(gpsLabel)

        // Target Station Card
        let targetCard = UIView()
        targetCard.backgroundColor = UIColor(red: 0.08, green: 0.13, blue: 0.22, alpha: 1.0)
        targetCard.layer.cornerRadius = 16
        targetCard.layer.borderWidth = 2
        targetCard.layer.borderColor = UIColor(red: 0.06, green: 0.72, blue: 0.50, alpha: 1.0).cgColor

        let targetStack = UIStackView()
        targetStack.axis = .vertical
        targetStack.spacing = 8
        targetStack.translatesAutoresizingMaskIntoConstraints = false
        targetCard.addSubview(targetStack)

        NSLayoutConstraint.activate([
            targetStack.topAnchor.constraint(equalTo: targetCard.topAnchor, constant: 14),
            targetStack.bottomAnchor.constraint(equalTo: targetCard.bottomAnchor, constant: -14),
            targetStack.leadingAnchor.constraint(equalTo: targetCard.leadingAnchor, constant: 14),
            targetStack.trailingAnchor.constraint(equalTo: targetCard.trailingAnchor, constant: -14)
        ])

        let topTargetRow = UIStackView()
        topTargetRow.axis = .horizontal
        topTargetRow.alignment = .center
        topTargetRow.distribution = .equalSpacing

        targetTitleLabel.text = "🎯 TỦ ĐANG KHÓA MỤC TIÊU"
        targetTitleLabel.font = UIFont.systemFont(ofSize: 12, weight: .heavy)
        targetTitleLabel.textColor = UIColor(red: 0.38, green: 0.65, blue: 0.98, alpha: 1.0)

        targetPinBadge.text = "--/-- PIN"
        targetPinBadge.font = UIFont.systemFont(ofSize: 14, weight: .black)
        targetPinBadge.textColor = UIColor(red: 0.02, green: 0.18, blue: 0.10, alpha: 1.0)
        targetPinBadge.backgroundColor = UIColor(red: 0.06, green: 0.72, blue: 0.50, alpha: 1.0)
        targetPinBadge.layer.cornerRadius = 8
        targetPinBadge.clipsToBounds = true
        targetPinBadge.textAlignment = .center

        topTargetRow.addArrangedSubview(targetTitleLabel)
        topTargetRow.addArrangedSubview(targetPinBadge)

        targetNameLabel.text = "Đang chờ tọa độ GPS..."
        targetNameLabel.font = UIFont.systemFont(ofSize: 18, weight: .black)
        targetNameLabel.textColor = .white
        targetNameLabel.numberOfLines = 2

        targetAddrLabel.text = "Hãy chọn 'Cho phép khi dùng ứng dụng' nếu iPhone hỏi quyền Vị Trí."
        targetAddrLabel.font = UIFont.systemFont(ofSize: 13, weight: .medium)
        targetAddrLabel.textColor = UIColor(red: 0.75, green: 0.80, blue: 0.88, alpha: 1.0)
        targetAddrLabel.numberOfLines = 2

        targetDistLabel.text = "Lộ trình thực tế: -- km"
        targetDistLabel.font = UIFont.systemFont(ofSize: 15, weight: .heavy)
        targetDistLabel.textColor = UIColor(red: 0.20, green: 0.90, blue: 0.60, alpha: 1.0)

        targetStack.addArrangedSubview(topTargetRow)
        targetStack.addArrangedSubview(targetNameLabel)
        targetStack.addArrangedSubview(targetAddrLabel)
        targetStack.addArrangedSubview(targetDistLabel)
        content.addArrangedSubview(targetCard)

        // Action Buttons (100% Google Maps)
        btnOpenGMaps.setTitle("🗺️ MỞ GOOGLE MAPS DẪN ĐƯỜNG NGAY", for: .normal)
        btnOpenGMaps.titleLabel?.font = UIFont.systemFont(ofSize: 15, weight: .black)
        btnOpenGMaps.backgroundColor = UIColor(red: 0.15, green: 0.39, blue: 0.92, alpha: 1.0)
        btnOpenGMaps.setTitleColor(.white, for: .normal)
        btnOpenGMaps.layer.cornerRadius = 14
        btnOpenGMaps.contentEdgeInsets = UIEdgeInsets(top: 15, left: 16, bottom: 15, right: 16)
        btnOpenGMaps.addTarget(self, action: #selector(onTapOpenGMaps), for: .touchUpInside)
        content.addArrangedSubview(btnOpenGMaps)

        let subActionRow = UIStackView()
        subActionRow.axis = .horizontal
        subActionRow.spacing = 10
        subActionRow.distribution = .fillEqually

        btnTestBgReroute.setTitle("🧪 Test Hết Pin (6s)", for: .normal)
        btnTestBgReroute.titleLabel?.font = UIFont.systemFont(ofSize: 13, weight: .bold)
        btnTestBgReroute.backgroundColor = UIColor(red: 0.85, green: 0.47, blue: 0.02, alpha: 1.0)
        btnTestBgReroute.setTitleColor(.white, for: .normal)
        btnTestBgReroute.layer.cornerRadius = 12
        btnTestBgReroute.contentEdgeInsets = UIEdgeInsets(top: 12, left: 8, bottom: 12, right: 8)
        btnTestBgReroute.addTarget(self, action: #selector(onTapTestBgReroute), for: .touchUpInside)

        btnSkipStation.setTitle("⏭️ Đổi Tủ Khác Ngay", for: .normal)
        btnSkipStation.titleLabel?.font = UIFont.systemFont(ofSize: 13, weight: .bold)
        btnSkipStation.backgroundColor = UIColor(red: 0.20, green: 0.26, blue: 0.36, alpha: 1.0)
        btnSkipStation.setTitleColor(.white, for: .normal)
        btnSkipStation.layer.cornerRadius = 12
        btnSkipStation.contentEdgeInsets = UIEdgeInsets(top: 12, left: 8, bottom: 12, right: 8)
        btnSkipStation.addTarget(self, action: #selector(onTapSkipStation), for: .touchUpInside)

        subActionRow.addArrangedSubview(btnTestBgReroute)
        subActionRow.addArrangedSubview(btnSkipStation)
        content.addArrangedSubview(subActionRow)

        // Note box explaining how background Google Maps switching works
        let infoNote = UILabel()
        infoNote.text = "💡 Khi bạn đang mở Google Maps: App vẫn chạy ngầm quét pin mỗi 3 giây. Nếu tủ hết pin, loa sẽ đọc báo động Tiếng Việt và hiện Banner ngay trên đầu Google Maps — chạm 1 cái vào Banner là Google Maps tự bẻ lái sang tủ mới!"
        infoNote.font = UIFont.systemFont(ofSize: 12, weight: .medium)
        infoNote.textColor = UIColor(red: 0.58, green: 0.64, blue: 0.72, alpha: 1.0)
        infoNote.numberOfLines = 0
        content.addArrangedSubview(infoNote)

        // Top 5 Section Title
        let top5Header = UILabel()
        top5Header.text = "📋 TOP 5 TỦ CÒN PIN GẦN NHẤT (CHẠM ĐỂ MỞ GOOGLE MAPS)"
        top5Header.font = UIFont.systemFont(ofSize: 13, weight: .heavy)
        top5Header.textColor = UIColor(red: 0.06, green: 0.72, blue: 0.50, alpha: 1.0)
        content.addArrangedSubview(top5Header)

        top5Stack.axis = .vertical
        top5Stack.spacing = 10
        content.addArrangedSubview(top5Stack)
    }

    // MARK: - 4. ĐỊNH VỊ GPS VỆ TINH TRỰC TIẾP
    private func setupLocation() {
        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyBestForNavigation
        locationManager.distanceFilter = kCLDistanceFilterNone
        locationManager.requestWhenInUseAuthorization()
        locationManager.startUpdatingLocation()
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        manager.startUpdatingLocation()
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let loc = locations.last, loc.horizontalAccuracy >= 0 else { return }
        userLat = loc.coordinate.latitude
        userLng = loc.coordinate.longitude
        userAccuracy = loc.horizontalAccuracy

        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.gpsLabel.text = String(
                format: "📍 GPS Trực Tiếp: %.5f, %.5f (±%.0fm)",
                self.userLat, self.userLng, self.userAccuracy
            )
        }

        let movedKm = lastLockedLat != 0 ? haversineKm(lastLockedLat, lastLockedLng, userLat, userLng) : 999.0
        if !hasRealGps {
            hasRealGps = true
            lastLockedLat = userLat
            lastLockedLng = userLng
            bestAccuracyAtLock = userAccuracy
            lockedStation = nil
            checkStationsNow(deepScan: true, autoOpenGMapsOnLock: false)
        } else if movedKm > 0.12 && userAccuracy < bestAccuracyAtLock * 0.8 {
            // Chốt lại tủ gần nhất khi GPS chuyển từ trạm phát sóng sang vệ tinh chính xác
            lastLockedLat = userLat
            lastLockedLng = userLng
            bestAccuracyAtLock = userAccuracy
            lockedStation = nil
            checkStationsNow(deepScan: true, autoOpenGMapsOnLock: false)
        }
    }

    // MARK: - 5. CRON 3 GIÂY & QUÉT TRỰC TIẾP API VINFAST + OSRM
    private func startCronTimer() {
        let timer = Timer(timeInterval: 3.0, repeats: true) { [weak self] _ in
            guard let self = self, self.hasRealGps else { return }
            self.checkStationsNow(deepScan: false, autoOpenGMapsOnLock: false)
        }
        RunLoop.main.add(timer, forMode: .common)
        self.cronTimer = timer
    }

    private func haversineKm(_ lat1: Double, _ lon1: Double, _ lat2: Double, _ lon2: Double) -> Double {
        let R = 6371.0
        let dLat = (lat2 - lat1) * .pi / 180.0
        let dLon = (lon2 - lon1) * .pi / 180.0
        let a = sin(dLat / 2) * sin(dLat / 2) +
            cos(lat1 * .pi / 180.0) * cos(lat2 * .pi / 180.0) * sin(dLon / 2) * sin(dLon / 2)
        return 2 * R * asin(sqrt(a))
    }

    private func calcSmartScore(avail: Int, total: Int, distKm: Double) -> Double {
        let ratio = Double(avail) / Double(max(total, 1))
        let cappedAvail = Double(min(avail, 6))
        return (cappedAvail * 2.5) + (ratio * 12.0) - (distKm * 20.0)
    }

    private func makeVinFastRequest(lat: Double, lng: Double) -> URLRequest? {
        let urlStr = String(
            format: "https://escooter-api.vinfast.vn/api-gateway/operation-support/v1.0/battery-swap-stations/near?lat=%.6f&lng=%.6f&distance=5000",
            lat, lng
        )
        guard let url = URL(string: urlStr) else { return nil }
        var req = URLRequest(url: url, timeoutInterval: 8)
        req.httpMethod = "GET"
        req.setValue("okhttp/4.9.3", forHTTPHeaderField: "User-Agent")
        req.setValue("ANDROID000JLNINSJFU43VGQY76BGSN9", forHTTPHeaderField: "client_id")
        req.setValue("ANDROID00000JLNINSJFU43VGQY76BGSN945678901234567890123456789654", forHTTPHeaderField: "client_secret")
        req.setValue("2.38.3", forHTTPHeaderField: "app_version")
        req.setValue("Android", forHTTPHeaderField: "platform")
        req.setValue("vi-VN", forHTTPHeaderField: "Accept-Language")
        return req
    }

    private func checkStationsNow(deepScan: Bool, autoOpenGMapsOnLock: Bool) {
        if isChecking || !hasRealGps { return }
        isChecking = true
        cronCount += 1

        let lat = userLat
        let lng = userLng
        let minPins = minPinsRequired
        let useDeep = deepScan || lockedStation == nil

        var points: [(Double, Double)] = [(lat, lng)]
        if useDeep {
            let d = 0.015
            points.append((lat + d, lng))
            points.append((lat - d, lng))
            points.append((lat, lng + d))
            points.append((lat, lng - d))
        }

        let group = DispatchGroup()
        let lock = NSLock()
        var seen = Set<String>()
        var rawStations: [SwapStation] = []

        for pt in points {
            guard let req = makeVinFastRequest(lat: pt.0, lng: pt.1) else { continue }
            group.enter()
            URLSession.shared.dataTask(with: req) { [weak self] data, _, _ in
                defer { group.leave() }
                guard let self = self,
                      let data = data,
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let arr = json["data"] as? [[String: Any]] else { return }

                lock.lock()
                for item in arr {
                    let code = (item["code"] as? String) ?? ""
                    guard !code.isEmpty, !seen.contains(code) else { continue }
                    seen.insert(code)

                    let status = (item["status"] as? String) ?? ""
                    let avail = (item["numberBatteryAvailable"] as? Int) ?? 0
                    let total = max((item["numberBattery"] as? Int) ?? 1, 1)
                    let sLat = (item["lat"] as? Double) ?? 0.0
                    let sLng = (item["lng"] as? Double) ?? 0.0
                    let name = (item["name"] as? String) ?? "Tủ đổi pin VinFast"
                    let address = (item["address"] as? String) ?? ""
                    let commune = (item["commune"] as? String) ?? ""

                    let straight = self.haversineKm(lat, lng, sLat, sLng)
                    let estRoad = Double(round(straight * 1.32 * 100) / 100)
                    let score = self.calcSmartScore(avail: avail, total: total, distKm: estRoad)

                    rawStations.append(
                        SwapStation(
                            code: code,
                            name: name,
                            address: address,
                            commune: commune,
                            lat: sLat,
                            lng: sLng,
                            avail: avail,
                            total: total,
                            status: status,
                            straightKm: straight,
                            distanceKm: estRoad,
                            durationMin: max(1, Int(round(estRoad * 2.5))),
                            score: score
                        )
                    )
                }
                lock.unlock()
            }.resume()
        }

        group.notify(queue: .global(qos: .userInitiated)) { [weak self] in
            guard let self = self else { return }
            let qualified = rawStations.filter {
                $0.status == "Available" &&
                $0.avail >= minPins &&
                !self.blacklistedCodes.contains($0.code) &&
                !self.simulatedEmptyCodes.contains($0.code)
            }.sorted { $0.straightKm < $1.straightKm }

            if useDeep && !qualified.isEmpty {
                self.enrichWithOSRM(lat: lat, lng: lng, stations: qualified) { finalSorted in
                    self.handleScanResult(qualified: finalSorted, autoOpenGMapsOnLock: autoOpenGMapsOnLock)
                }
            } else {
                // Giữ nguyên khoảng cách OSRM đã tính trước đó nếu có
                var updated = qualified.map { st -> SwapStation in
                    var copy = st
                    if let prev = self.topStations.first(where: { $0.code == st.code }) {
                        copy.distanceKm = prev.distanceKm
                        copy.durationMin = prev.durationMin
                    } else if let locked = self.lockedStation, locked.code == st.code {
                        copy.distanceKm = locked.distanceKm
                        copy.durationMin = locked.durationMin
                    }
                    copy.score = self.calcSmartScore(avail: copy.avail, total: copy.total, distKm: copy.distanceKm)
                    return copy
                }
                updated.sort { $0.score > $1.score }
                self.handleScanResult(qualified: updated, autoOpenGMapsOnLock: autoOpenGMapsOnLock)
            }
        }
    }

    private func enrichWithOSRM(lat: Double, lng: Double, stations: [SwapStation], completion: @escaping ([SwapStation]) -> Void) {
        let targets = Array(stations.prefix(15))
        let coords = ([String(format: "%.6f,%.6f", lng, lat)] + targets.map { String(format: "%.6f,%.6f", $0.lng, $0.lat) }).joined(separator: ";")
        let urlStr = "https://router.project-osrm.org/table/v1/driving/\(coords)?sources=0&annotations=distance,duration"
        guard let url = URL(string: urlStr) else {
            completion(stations.sorted { $0.score > $1.score })
            return
        }

        var req = URLRequest(url: url, timeoutInterval: 5)
        req.setValue("VFSwapRadar/3.0", forHTTPHeaderField: "User-Agent")
        URLSession.shared.dataTask(with: req) { [weak self] data, _, _ in
            guard let self = self else { return }
            var enriched = targets
            if let data = data,
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let distMatrix = json["distances"] as? [[Any]],
               let distRow = distMatrix.first {
                let durRow = (json["durations"] as? [[Any]])?.first
                for i in 0..<enriched.count {
                    if i + 1 < distRow.count, let meters = distRow[i + 1] as? Double, meters > 0 {
                        let km = Double(round((meters / 1000.0) * 100) / 100)
                        enriched[i].distanceKm = km
                        if let durRow = durRow, i + 1 < durRow.count, let secs = durRow[i + 1] as? Double {
                            enriched[i].durationMin = max(1, Int(round(secs / 60.0)))
                        }
                        enriched[i].score = self.calcSmartScore(avail: enriched[i].avail, total: enriched[i].total, distKm: km)
                    }
                }
            }
            enriched.sort { $0.score > $1.score }
            completion(enriched)
        }.resume()
    }

    private func handleScanResult(qualified: [SwapStation], autoOpenGMapsOnLock: Bool) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            defer { self.isChecking = false }

            self.topStations = Array(qualified.prefix(5))
            self.statusBadge.text = "🟢 CANH PIN NGẦM 3s (#\(self.cronCount))"

            let currentValid = self.lockedStation != nil ? qualified.first(where: { $0.code == self.lockedStation!.code }) : nil

            if let oldStation = self.lockedStation, currentValid == nil {
                // TỦ ĐANG ĐI VỪA TỤT XUỐNG < 2 PIN HOẶC HẾT PIN!
                if let nextBest = qualified.first {
                    self.lockedStation = nextBest
                    let isBg = UIApplication.shared.applicationState != .active
                    if isBg {
                        // Đang ở bên màn hình Google Maps -> Đọc giọng nói báo động + Bắn Banner thông báo lên đỉnh Google Maps!
                        self.pendingAutoOpenGoogleMaps = true
                        self.sendRerouteNotification(oldName: oldStation.name, newStation: nextBest)
                        self.speakVietnamese("Cảnh báo! Tủ \(oldStation.name) vừa hết pin! Đã đổi sang tủ \(nextBest.name), còn \(nextBest.avail) pin đầy, cách \(nextBest.distanceKm) ki lô mét. Hãy chạm vào thông báo phía trên màn hình để mở lộ trình mới trên Google Maps!")
                    } else {
                        // Đang ở trong App -> Tự động bắn thẳng sang Google Maps!
                        self.speakVietnamese("Tủ \(oldStation.name) đã hết pin. Tự động mở Google Maps sang tủ \(nextBest.name), còn \(nextBest.avail) pin đầy!")
                        self.openInGoogleMaps(station: nextBest)
                    }
                } else {
                    self.lockedStation = nil
                    self.speakVietnamese("Cảnh báo! Không còn tủ nào đủ \(self.minPinsRequired) pin đầy quanh đây!")
                }
            } else if self.lockedStation == nil, let first = qualified.first {
                self.lockedStation = first
                self.speakVietnamese("Đã khóa tủ \(first.name), sẵn sàng \(first.avail) trên \(first.total) pin đầy, cách \(first.distanceKm) ki lô mét.")
                if autoOpenGMapsOnLock {
                    self.openInGoogleMaps(station: first)
                }
            } else if let valid = currentValid {
                self.lockedStation = valid
                if autoOpenGMapsOnLock {
                    self.openInGoogleMaps(station: valid)
                }
            }

            self.refreshUI()
        }
    }

    // MARK: - 6. CẬP NHẬT GIAO DIỆN & ĐIỀU KHIỂN GOOGLE MAPS
    private func refreshUI() {
        if let st = lockedStation {
            targetNameLabel.text = st.name
            targetAddrLabel.text = "\(st.address)\(st.commune.isEmpty ? "" : " • " + st.commune) (Mã: \(st.code))"
            targetPinBadge.text = "  \(st.avail)/\(st.total) PIN ĐẦY  "
            let durStr = st.durationMin != nil ? " (~\(st.durationMin!) phút lái xe)" : ""
            targetDistLabel.text = "🛵 Lộ trình đường bộ: \(st.distanceKm) km\(durStr)"
        } else {
            targetNameLabel.text = "Không có tủ nào >= \(minPinsRequired) pin đầy"
            targetAddrLabel.text = "Hãy bấm nút '>= \(minPinsRequired) PIN' ở góc trên để hạ mức lọc pin."
            targetPinBadge.text = "  0/0 PIN  "
            targetDistLabel.text = "Lộ trình thực tế: -- km"
        }

        top5Stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for (idx, st) in topStations.enumerated() {
            let isLocked = lockedStation?.code == st.code
            let card = UIButton(type: .system)
            card.backgroundColor = isLocked
                ? UIColor(red: 0.06, green: 0.24, blue: 0.20, alpha: 1.0)
                : UIColor(red: 0.09, green: 0.13, blue: 0.20, alpha: 1.0)
            card.layer.cornerRadius = 12
            card.layer.borderWidth = isLocked ? 2 : 1
            card.layer.borderColor = isLocked
                ? UIColor(red: 0.06, green: 0.72, blue: 0.50, alpha: 1.0).cgColor
                : UIColor(red: 0.18, green: 0.24, blue: 0.35, alpha: 1.0).cgColor
            card.tag = idx
            card.addTarget(self, action: #selector(onTapStationCard(_:)), for: .touchUpInside)

            let lbl = UILabel()
            lbl.numberOfLines = 0
            lbl.isUserInteractionEnabled = false
            lbl.translatesAutoresizingMaskIntoConstraints = false
            let durStr = st.durationMin != nil ? " (~\(st.durationMin!)p)" : ""
            let prefix = isLocked ? "🎯 [ĐANG KHÓA] " : "#\(idx + 1) • "
            let text = "\(prefix)\(st.distanceKm) km\(durStr)  —  [\(st.avail)/\(st.total) PIN ĐẦY]\n\(st.name)\n\(st.address)"
            lbl.text = text
            lbl.font = UIFont.systemFont(ofSize: 13, weight: .semibold)
            lbl.textColor = .white

            card.addSubview(lbl)
            NSLayoutConstraint.activate([
                lbl.topAnchor.constraint(equalTo: card.topAnchor, constant: 12),
                lbl.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -12),
                lbl.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 12),
                lbl.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -12)
            ])
            top5Stack.addArrangedSubview(card)
        }
    }

    private func openInGoogleMaps(station: SwapStation) {
        if let appUrl = station.googleMapsAppUrl, UIApplication.shared.canOpenURL(appUrl) {
            UIApplication.shared.open(appUrl, options: [:], completionHandler: nil)
        } else if let webUrl = station.googleMapsWebUrl {
            UIApplication.shared.open(webUrl, options: [:], completionHandler: nil)
        }
    }

    @objc private func onTapOpenGMaps() {
        if let st = lockedStation {
            openInGoogleMaps(station: st)
        } else {
            checkStationsNow(deepScan: true, autoOpenGMapsOnLock: true)
        }
    }

    @objc private func onTapRefreshGps() {
        gpsLabel.text = "📍 Đang lấy lại vị trí GPS trực tiếp mới nhất..."
        lockedStation = nil
        locationManager.startUpdatingLocation()
        if hasRealGps {
            checkStationsNow(deepScan: true, autoOpenGMapsOnLock: false)
        }
    }

    @objc private func onTapFilterPins() {
        minPinsRequired = minPinsRequired == 2 ? 3 : (minPinsRequired == 3 ? 1 : 2)
        btnFilterPins.setTitle(">= \(minPinsRequired) PIN", for: .normal)
        lockedStation = nil
        checkStationsNow(deepScan: true, autoOpenGMapsOnLock: false)
    }

    @objc private func onTapSkipStation() {
        if let st = lockedStation {
            blacklistedCodes.insert(st.code)
            lockedStation = nil
            checkStationsNow(deepScan: true, autoOpenGMapsOnLock: true)
        }
    }

    @objc private func onTapTestBgReroute() {
        guard let st = lockedStation else { return }
        speakVietnamese("Bắt đầu bài test. Mở Google Maps ngay bây giờ. Sau 6 giây tủ \(st.name) sẽ giả lập hết pin để bạn thử nghiệm thông báo đổi hướng!")
        openInGoogleMaps(station: st)
        let targetCode = st.code
        DispatchQueue.main.asyncAfter(deadline: .now() + 6.0) { [weak self] in
            guard let self = self else { return }
            self.simulatedEmptyCodes.insert(targetCode)
            self.checkStationsNow(deepScan: false, autoOpenGMapsOnLock: false)
        }
    }

    @objc private func onTapStationCard(_ sender: UIButton) {
        let idx = sender.tag
        guard idx >= 0 && idx < topStations.count else { return }
        let chosen = topStations[idx]
        lockedStation = chosen
        refreshUI()
        speakVietnamese("Đã chọn tủ \(chosen.name), còn \(chosen.avail) pin đầy. Đang mở Google Maps.")
        openInGoogleMaps(station: chosen)
    }

    override var preferredStatusBarStyle: UIStatusBarStyle {
        return .lightContent
    }
}
