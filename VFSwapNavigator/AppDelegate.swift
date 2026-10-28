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
    var effectiveDistanceKm: Double
    var durationMin: Int?
    var bearingDeg: Double
    var isAheadOfCourse: Bool

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

    // Trạng thái GPS, Hướng Di Chuyển (Course) & Trạm
    private var userLat: Double = 0.0
    private var userLng: Double = 0.0
    private var prevGpsLat: Double = 0.0
    private var prevGpsLng: Double = 0.0
    private var userAccuracy: Double = 9999.0
    private var userCourse: Double = -1.0
    private var userSpeed: Double = 0.0
    private var hasRealGps: Bool = false

    private var lastLockedLat: Double = 0.0
    private var lastLockedLng: Double = 0.0
    private var lastDeepScanLat: Double = 0.0
    private var lastDeepScanLng: Double = 0.0
    private var bestAccuracyAtLock: Double = 9999.0

    // Theo dõi khoảng cách ngắn nhất từng đạt được tới tủ đang khóa để phát hiện đi xa (Moving Away)
    private var minDistanceToLockedKm: Double = 9999.0
    private var autoRerouteByDirection: Bool = true

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
    private let btnToggleDirection = UIButton(type: .system)
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

    // MARK: - 1. SILENT AUDIO KEEP-ALIVE (Giữ Cron 3s & GPS sống khi đang mở Google Maps)
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

        var fmtChunkSize: UInt32 = UInt32(16).littleEndian
        var audioFormat: UInt16 = UInt16(1).littleEndian
        var numChannels: UInt16 = UInt16(1).littleEndian
        var leSampleRate: UInt32 = sampleRate.littleEndian
        var byteRate: UInt32 = (sampleRate * 2).littleEndian
        var blockAlign: UInt16 = UInt16(2).littleEndian
        var bitsPerSample: UInt16 = UInt16(16).littleEndian

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
        locationManager.startUpdatingLocation()
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

    private func sendBannerNotification(title: String, body: String, station: SwapStation) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.userInfo = ["code": station.code]

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
        content.spacing = 11
        content.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(content)

        let safe = view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: safe.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: safe.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: safe.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: safe.trailingAnchor),

            content.topAnchor.constraint(equalTo: scroll.topAnchor, constant: 10),
            content.bottomAnchor.constraint(equalTo: scroll.bottomAnchor, constant: -24),
            content.leadingAnchor.constraint(equalTo: scroll.leadingAnchor, constant: 14),
            content.trailingAnchor.constraint(equalTo: scroll.trailingAnchor, constant: -14),
            content.widthAnchor.constraint(equalTo: scroll.widthAnchor, constant: -28)
        ])

        // Header Row 1: Status & Buttons
        let headerRow = UIStackView()
        headerRow.axis = .horizontal
        headerRow.alignment = .center
        headerRow.distribution = .equalSpacing

        statusBadge.text = "🟢 CANH PIN & HƯỚNG ĐI 3s (#0)"
        statusBadge.font = UIFont.systemFont(ofSize: 12.5, weight: .heavy)
        statusBadge.textColor = UIColor(red: 0.20, green: 0.90, blue: 0.60, alpha: 1.0)

        let rightBtns = UIStackView()
        rightBtns.axis = .horizontal
        rightBtns.spacing = 6

        btnFilterPins.setTitle(">= 2 PIN", for: .normal)
        btnFilterPins.titleLabel?.font = UIFont.systemFont(ofSize: 11.5, weight: .bold)
        btnFilterPins.backgroundColor = UIColor(red: 0.12, green: 0.18, blue: 0.28, alpha: 1.0)
        btnFilterPins.setTitleColor(.white, for: .normal)
        btnFilterPins.layer.cornerRadius = 8
        btnFilterPins.contentEdgeInsets = UIEdgeInsets(top: 6, left: 9, bottom: 6, right: 9)
        btnFilterPins.addTarget(self, action: #selector(onTapFilterPins), for: .touchUpInside)

        let btnRefreshGps = UIButton(type: .system)
        btnRefreshGps.setTitle("↻ GPS Mới", for: .normal)
        btnRefreshGps.titleLabel?.font = UIFont.systemFont(ofSize: 11.5, weight: .heavy)
        btnRefreshGps.backgroundColor = UIColor(red: 0.06, green: 0.72, blue: 0.50, alpha: 1.0)
        btnRefreshGps.setTitleColor(UIColor(red: 0.02, green: 0.18, blue: 0.10, alpha: 1.0), for: .normal)
        btnRefreshGps.layer.cornerRadius = 8
        btnRefreshGps.contentEdgeInsets = UIEdgeInsets(top: 6, left: 10, bottom: 6, right: 10)
        btnRefreshGps.addTarget(self, action: #selector(onTapRefreshGps), for: .touchUpInside)

        rightBtns.addArrangedSubview(btnFilterPins)
        rightBtns.addArrangedSubview(btnRefreshGps)

        headerRow.addArrangedSubview(statusBadge)
        headerRow.addArrangedSubview(rightBtns)
        content.addArrangedSubview(headerRow)

        // Header Row 2: Direction Reroute Toggle Button
        btnToggleDirection.setTitle("🧭 Tự động đổi sang tủ gần nhất theo hướng di chuyển: BẬT", for: .normal)
        btnToggleDirection.titleLabel?.font = UIFont.systemFont(ofSize: 12, weight: .bold)
        btnToggleDirection.backgroundColor = UIColor(red: 0.07, green: 0.25, blue: 0.22, alpha: 1.0)
        btnToggleDirection.setTitleColor(UIColor(red: 0.43, green: 0.91, blue: 0.72, alpha: 1.0), for: .normal)
        btnToggleDirection.layer.cornerRadius = 10
        btnToggleDirection.layer.borderWidth = 1
        btnToggleDirection.layer.borderColor = UIColor(red: 0.06, green: 0.72, blue: 0.50, alpha: 0.6).cgColor
        btnToggleDirection.contentEdgeInsets = UIEdgeInsets(top: 8, left: 10, bottom: 8, right: 10)
        btnToggleDirection.addTarget(self, action: #selector(onTapToggleDirection), for: .touchUpInside)
        content.addArrangedSubview(btnToggleDirection)

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

        targetTitleLabel.text = "🎯 TỦ GẦN NHẤT ĐANG KHÓA"
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
        targetAddrLabel.numberOfLines = 0

        targetDistLabel.text = "Lộ trình thực tế: -- km"
        targetDistLabel.font = UIFont.systemFont(ofSize: 15, weight: .heavy)
        targetDistLabel.textColor = UIColor(red: 0.20, green: 0.90, blue: 0.60, alpha: 1.0)

        targetStack.addArrangedSubview(topTargetRow)
        targetStack.addArrangedSubview(targetNameLabel)
        targetStack.addArrangedSubview(targetAddrLabel)
        targetStack.addArrangedSubview(targetDistLabel)
        content.addArrangedSubview(targetCard)

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

        btnTestBgReroute.setTitle("🧪 Test Đổi Tủ (6s)", for: .normal)
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

        let infoNote = UILabel()
        infoNote.text = "💡 Tự động đổi tủ khi: (1) Tủ đang đi hết pin (<2 pin), HOẶC (2) Bạn đi xa khỏi tủ đang khóa >= 300m, HOẶC (3) Trên hướng bạn chạy xuất hiện tủ khác gần hơn từ 250m trở lên. Chạm vào Banner thông báo trên đầu Google Maps để bẻ lái ngay!"
        infoNote.font = UIFont.systemFont(ofSize: 11.5, weight: .medium)
        infoNote.textColor = UIColor(red: 0.58, green: 0.64, blue: 0.72, alpha: 1.0)
        infoNote.numberOfLines = 0
        content.addArrangedSubview(infoNote)

        let top5Header = UILabel()
        top5Header.text = "📋 TOP 5 TỦ GẦN NHẤT THEO VỊ TRÍ & HƯỚNG ĐI"
        top5Header.font = UIFont.systemFont(ofSize: 13, weight: .heavy)
        top5Header.textColor = UIColor(red: 0.06, green: 0.72, blue: 0.50, alpha: 1.0)
        content.addArrangedSubview(top5Header)

        top5Stack.axis = .vertical
        top5Stack.spacing = 10
        content.addArrangedSubview(top5Stack)
    }

    // MARK: - 4. ĐỊNH VỊ GPS VỆ TINH & TÍNH HƯỚNG DI CHUYỂN (COURSE VECTOR)
    private func setupLocation() {
        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyBestForNavigation
        locationManager.distanceFilter = kCLDistanceFilterNone
        locationManager.pausesLocationUpdatesAutomatically = false
        locationManager.requestAlwaysAuthorization()
        locationManager.requestWhenInUseAuthorization()
        locationManager.startUpdatingLocation()
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        manager.startUpdatingLocation()
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let loc = locations.last, loc.horizontalAccuracy >= 0 else { return }
        let newLat = loc.coordinate.latitude
        let newLng = loc.coordinate.longitude

        // Tính góc di chuyển (Course 0..360) từ phần cứng GPS hoặc từ vector dịch chuyển thực tế (>20m)
        if loc.course >= 0 && loc.speed > 1.5 {
            userCourse = loc.course
        } else if prevGpsLat != 0 {
            let stepKm = haversineKm(prevGpsLat, prevGpsLng, newLat, newLng)
            if stepKm >= 0.020 {
                userCourse = calcBearingDeg(prevGpsLat, prevGpsLng, newLat, newLng)
                prevGpsLat = newLat
                prevGpsLng = newLng
            }
        } else {
            prevGpsLat = newLat
            prevGpsLng = newLng
        }

        userLat = newLat
        userLng = newLng
        userAccuracy = loc.horizontalAccuracy
        userSpeed = max(0.0, loc.speed)

        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            let courseStr = self.userCourse >= 0 ? String(format: " • Hướng: %.0f°", self.userCourse) : ""
            self.gpsLabel.text = String(
                format: "📍 GPS: %.5f, %.5f (±%.0fm)%@",
                self.userLat, self.userLng, self.userAccuracy, courseStr
            )
        }

        let movedFromFirstLockKm = lastLockedLat != 0 ? haversineKm(lastLockedLat, lastLockedLng, userLat, userLng) : 999.0
        let movedFromLastDeepScanKm = lastDeepScanLat != 0 ? haversineKm(lastDeepScanLat, lastDeepScanLng, userLat, userLng) : 999.0

        if !hasRealGps {
            hasRealGps = true
            lastLockedLat = userLat
            lastLockedLng = userLng
            bestAccuracyAtLock = userAccuracy
            lockedStation = nil
            minDistanceToLockedKm = 9999.0
            checkStationsNow(deepScan: true, autoOpenGMapsOnLock: false)
        } else if movedFromFirstLockKm > 0.12 && userAccuracy < bestAccuracyAtLock * 0.8 {
            lastLockedLat = userLat
            lastLockedLng = userLng
            bestAccuracyAtLock = userAccuracy
            lockedStation = nil
            minDistanceToLockedKm = 9999.0
            checkStationsNow(deepScan: true, autoOpenGMapsOnLock: false)
        } else if movedFromLastDeepScanKm >= 0.14 {
            // Mỗi khi xe di chuyển thêm >= 140m, quét lại bán kính 5 tâm + khoảng cách đường bộ OSRM để bám sát vị trí mới!
            checkStationsNow(deepScan: true, autoOpenGMapsOnLock: false)
        }
    }

    // MARK: - 5. CRON 3 GIÂY & THUẬT TOÁN TỰ ĐỔI TỦ THEO HƯỚNG DI CHUYỂN
    private func startCronTimer() {
        let timer = Timer(timeInterval: 3.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            // Giữ luồng GPS luôn thức khi chạy ngầm cùng Silent Audio
            self.locationManager.startUpdatingLocation()
            guard self.hasRealGps else { return }
            let movedKm = self.lastDeepScanLat != 0 ? self.haversineKm(self.lastDeepScanLat, self.lastDeepScanLng, self.userLat, self.userLng) : 999.0
            self.checkStationsNow(deepScan: movedKm >= 0.14, autoOpenGMapsOnLock: false)
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

    private func calcBearingDeg(_ lat1: Double, _ lon1: Double, _ lat2: Double, _ lon2: Double) -> Double {
        let p1 = lat1 * .pi / 180.0
        let p2 = lat2 * .pi / 180.0
        let dLon = (lon2 - lon1) * .pi / 180.0
        let y = sin(dLon) * cos(p2)
        let x = cos(p1) * sin(p2) - sin(p1) * cos(p2) * cos(dLon)
        let brng = atan2(y, x) * 180.0 / .pi
        return (brng + 360.0).truncatingRemainder(dividingBy: 360.0)
    }

    private func absAngleDiff(_ a: Double, _ b: Double) -> Double {
        let diff = abs(a - b).truncatingRemainder(dividingBy: 360.0)
        return diff > 180.0 ? 360.0 - diff : diff
    }

    // Tính khoảng cách hiệu dụng có xét đến hướng mũi xe đang chạy (phạt +0.30km nếu tủ nằm ngược phía sau lưng xe >120 độ)
    private func computeEffectiveDistance(roadKm: Double, bearingToStation: Double) -> (Double, Bool) {
        guard autoRerouteByDirection, userCourse >= 0 else {
            return (roadKm, false)
        }
        let diff = absAngleDiff(userCourse, bearingToStation)
        let isAhead = diff <= 70.0
        if diff > 120.0 {
            return (roadKm + 0.30, false)
        }
        return (roadKm, isAhead)
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
        if useDeep {
            lastDeepScanLat = lat
            lastDeepScanLng = lng
        }

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
                    let brng = self.calcBearingDeg(lat, lng, sLat, sLng)
                    let (effDist, isAhead) = self.computeEffectiveDistance(roadKm: estRoad, bearingToStation: brng)

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
                            effectiveDistanceKm: effDist,
                            durationMin: max(1, Int(round(estRoad * 2.5))),
                            bearingDeg: brng,
                            isAheadOfCourse: isAhead
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
                var updated = qualified.map { st -> SwapStation in
                    var copy = st
                    let currentStraight = self.haversineKm(lat, lng, st.lat, st.lng)
                    copy.straightKm = currentStraight
                    if let prev = self.topStations.first(where: { $0.code == st.code }) {
                        // Nội suy khoảng cách đường bộ theo sự thay đổi vị trí GPS trực tiếp
                        let delta = currentStraight - prev.straightKm
                        copy.distanceKm = max(0.05, Double(round((prev.distanceKm + delta * 1.25) * 100) / 100))
                        copy.durationMin = prev.durationMin
                    } else if let locked = self.lockedStation, locked.code == st.code {
                        let delta = currentStraight - locked.straightKm
                        copy.distanceKm = max(0.05, Double(round((locked.distanceKm + delta * 1.25) * 100) / 100))
                        copy.durationMin = locked.durationMin
                    }
                    let brng = self.calcBearingDeg(lat, lng, copy.lat, copy.lng)
                    let (effDist, isAhead) = self.computeEffectiveDistance(roadKm: copy.distanceKm, bearingToStation: brng)
                    copy.bearingDeg = brng
                    copy.effectiveDistanceKm = effDist
                    copy.isAheadOfCourse = isAhead
                    return copy
                }
                updated.sort {
                    if $0.effectiveDistanceKm != $1.effectiveDistanceKm { return $0.effectiveDistanceKm < $1.effectiveDistanceKm }
                    if $0.distanceKm != $1.distanceKm { return $0.distanceKm < $1.distanceKm }
                    return $0.avail > $1.avail
                }
                self.handleScanResult(qualified: updated, autoOpenGMapsOnLock: autoOpenGMapsOnLock)
            }
        }
    }

    private func enrichWithOSRM(lat: Double, lng: Double, stations: [SwapStation], completion: @escaping ([SwapStation]) -> Void) {
        let targets = Array(stations.prefix(15))
        let coords = ([String(format: "%.6f,%.6f", lng, lat)] + targets.map { String(format: "%.6f,%.6f", $0.lng, $0.lat) }).joined(separator: ";")
        let urlStr = "https://router.project-osrm.org/table/v1/driving/\(coords)?sources=0&annotations=distance,duration"
        guard let url = URL(string: urlStr) else {
            completion(stations.sorted {
                if $0.effectiveDistanceKm != $1.effectiveDistanceKm { return $0.effectiveDistanceKm < $1.effectiveDistanceKm }
                return $0.distanceKm < $1.distanceKm
            })
            return
        }

        var req = URLRequest(url: url, timeoutInterval: 5)
        req.setValue("VFSwapRadar/3.1", forHTTPHeaderField: "User-Agent")
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
                        let (effDist, isAhead) = self.computeEffectiveDistance(roadKm: km, bearingToStation: enriched[i].bearingDeg)
                        enriched[i].effectiveDistanceKm = effDist
                        enriched[i].isAheadOfCourse = isAhead
                    }
                }
            }
            enriched.sort {
                if $0.effectiveDistanceKm != $1.effectiveDistanceKm { return $0.effectiveDistanceKm < $1.effectiveDistanceKm }
                if $0.distanceKm != $1.distanceKm { return $0.distanceKm < $1.distanceKm }
                return $0.avail > $1.avail
            }
            completion(enriched)
        }.resume()
    }

    private func handleScanResult(qualified: [SwapStation], autoOpenGMapsOnLock: Bool) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            defer { self.isChecking = false }

            self.topStations = Array(qualified.prefix(5))
            self.statusBadge.text = "🟢 CANH PIN & HƯỚNG ĐI 3s (#\(self.cronCount))"

            let currentValid = self.lockedStation != nil ? qualified.first(where: { $0.code == self.lockedStation!.code }) : nil

            if let oldStation = self.lockedStation, currentValid == nil {
                // TRƯỜNG HỢP 1: TỦ ĐANG ĐI VỪA HẾT PIN (< minPins)
                if let nextBest = qualified.first {
                    self.lockedStation = nextBest
                    self.minDistanceToLockedKm = nextBest.distanceKm
                    self.triggerRerouteAlert(
                        reasonTitle: "⚠️ TỦ ĐANG ĐI ĐÃ HẾT PIN! CHẠM ĐỂ ĐỔI HƯỚNG",
                        voiceMsgBg: "Cảnh báo! Tủ \(oldStation.name) vừa hết pin! Đã đổi sang tủ gần nhất là \(nextBest.name), còn \(nextBest.avail) pin đầy, cách \(nextBest.distanceKm) ki lô mét. Hãy chạm vào thông báo phía trên màn hình để mở lộ trình mới trên Google Maps!",
                        voiceMsgFg: "Tủ \(oldStation.name) đã hết pin. Tự động mở Google Maps sang tủ gần nhất là \(nextBest.name), còn \(nextBest.avail) pin đầy!",
                        newStation: nextBest
                    )
                } else {
                    self.lockedStation = nil
                    self.speakVietnamese("Cảnh báo! Không còn tủ nào đủ \(self.minPinsRequired) pin đầy quanh đây!")
                }
            } else if let validLocked = currentValid {
                // Tủ đang khóa vẫn còn pin -> Kiểm tra xem người dùng có ĐANG ĐI XA KHỎI TỦ ĐÓ hoặc TIẾN GẦN TỦ KHÁC HƠN KHÔNG
                self.lockedStation = validLocked
                if validLocked.distanceKm < self.minDistanceToLockedKm {
                    self.minDistanceToLockedKm = validLocked.distanceKm
                }

                let movedAwayKm = validLocked.distanceKm - self.minDistanceToLockedKm
                let bestCandidate = qualified.first

                if self.autoRerouteByDirection,
                   let best = bestCandidate,
                   best.code != validLocked.code {
                    let isMovingAway = movedAwayKm >= 0.30 && best.distanceKm <= validLocked.distanceKm
                    let isMuchCloser = (validLocked.distanceKm - best.distanceKm) >= 0.25

                    if isMovingAway || isMuchCloser {
                        // TRƯỜNG HỢP 2: TỰ ĐỘNG ĐỔI TỦ THEO HƯỚNG DI CHUYỂN / KHI ĐI XA KHỎI TỦ CŨ!
                        self.lockedStation = best
                        self.minDistanceToLockedKm = best.distanceKm
                        let reasonText = isMovingAway
                            ? "Bạn đã đi xa khỏi tủ cũ \(String(format: "%.0f", movedAwayKm * 1000)) mét."
                            : "Phát hiện tủ mới gần vị trí bạn hơn."
                        self.triggerRerouteAlert(
                            reasonTitle: "🧭 ĐỔI TỦ GẦN HƠN THEO HƯỚNG ĐI! CHẠM ĐỂ RẼ",
                            voiceMsgBg: "\(reasonText) Đã chuyển mục tiêu sang tủ \(best.name), cách \(best.distanceKm) ki lô mét, còn \(best.avail) pin đầy. Chạm vào thông báo phía trên màn hình để bẻ lái Google Maps!",
                            voiceMsgFg: "\(reasonText) Tự động chuyển Google Maps sang tủ \(best.name), cách \(best.distanceKm) ki lô mét!",
                            newStation: best
                        )
                        self.refreshUI()
                        return
                    }
                }

                if autoOpenGMapsOnLock {
                    self.openInGoogleMaps(station: validLocked)
                }
            } else if self.lockedStation == nil, let first = qualified.first {
                self.lockedStation = first
                self.minDistanceToLockedKm = first.distanceKm
                self.speakVietnamese("Đã khóa tủ gần nhất \(first.name), sẵn sàng \(first.avail) trên \(first.total) pin đầy, cách \(first.distanceKm) ki lô mét.")
                if autoOpenGMapsOnLock {
                    self.openInGoogleMaps(station: first)
                }
            }

            self.refreshUI()
        }
    }

    private func triggerRerouteAlert(reasonTitle: String, voiceMsgBg: String, voiceMsgFg: String, newStation: SwapStation) {
        let isBg = UIApplication.shared.applicationState != .active
        if isBg {
            self.pendingAutoOpenGoogleMaps = true
            let durText = newStation.durationMin != nil ? " (~\(newStation.durationMin!)p)" : ""
            let body = "Mục tiêu mới: \(newStation.name) [\(newStation.avail)/\(newStation.total) PIN • Cách \(newStation.distanceKm)km\(durText)]. Chạm vào đây để cập nhật Google Maps ngay!"
            self.sendBannerNotification(title: reasonTitle, body: body, station: newStation)
            self.speakVietnamese(voiceMsgBg)
        } else {
            self.speakVietnamese(voiceMsgFg)
            self.openInGoogleMaps(station: newStation)
        }
    }

    // MARK: - 6. CẬP NHẬT GIAO DIỆN & ĐIỀU KHIỂN GOOGLE MAPS
    private func refreshUI() {
        if let st = lockedStation {
            let charging = max(0, st.total - st.avail)
            let aheadTag = st.isAheadOfCourse ? " • ⬆️ Thuận hướng đang đi" : ""
            targetNameLabel.text = st.name
            targetAddrLabel.text = "\(st.address)\(st.commune.isEmpty ? "" : " • " + st.commune) (Mã: \(st.code))\n🔋 Sẵn sàng rút: \(st.avail) cục (≥95%) • Đang sạc khóa khay: \(charging) cục"
            targetPinBadge.text = "  \(st.avail)/\(st.total) PIN ĐẦY  "
            let durStr = st.durationMin != nil ? " (~\(st.durationMin!) phút)" : ""
            targetDistLabel.text = "🛵 Cách \(st.distanceKm) km\(durStr)\(aheadTag)"
        } else {
            targetNameLabel.text = "Không có tủ nào >= \(minPinsRequired) pin đầy"
            targetAddrLabel.text = "Hãy bấm nút '>= \(minPinsRequired) PIN' ở góc trên để hạ mức lọc pin."
            targetPinBadge.text = "  0/0 PIN  "
            targetDistLabel.text = "Lộ trình thực tế: -- km"
        }

        top5Stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for (idx, st) in topStations.enumerated() {
            let isLocked = lockedStation?.code == st.code
            let charging = max(0, st.total - st.avail)
            let aheadBadge = st.isAheadOfCourse ? " ⬆️ Thuận hướng" : ""
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
            let prefix = isLocked ? "🎯 [GẦN NHẤT - ĐANG KHÓA] " : "#\(idx + 1) • "
            let text = "\(prefix)\(st.distanceKm) km\(durStr)\(aheadBadge)  —  [\(st.avail)/\(st.total) PIN ĐẦY]\n\(st.name)\n\(st.address)\n🔋 Rút ngay: \(st.avail) cục (≥95%) • Đang sạc: \(charging) cục"
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

    @objc private func onTapToggleDirection() {
        autoRerouteByDirection.toggle()
        if autoRerouteByDirection {
            btnToggleDirection.setTitle("🧭 Tự động đổi sang tủ gần nhất theo hướng di chuyển: BẬT", for: .normal)
            btnToggleDirection.backgroundColor = UIColor(red: 0.07, green: 0.25, blue: 0.22, alpha: 1.0)
            btnToggleDirection.setTitleColor(UIColor(red: 0.43, green: 0.91, blue: 0.72, alpha: 1.0), for: .normal)
            speakVietnamese("Đã bật tự động đổi sang tủ gần nhất theo hướng di chuyển.")
        } else {
            btnToggleDirection.setTitle("🔒 Tự động đổi theo hướng di chuyển: TẮT (Chỉ đổi khi hết pin)", for: .normal)
            btnToggleDirection.backgroundColor = UIColor(red: 0.16, green: 0.19, blue: 0.26, alpha: 1.0)
            btnToggleDirection.setTitleColor(UIColor(red: 0.75, green: 0.80, blue: 0.88, alpha: 1.0), for: .normal)
            speakVietnamese("Đã khóa cố định tủ hiện tại, chỉ tự động đổi khi tủ hết pin.")
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
        minDistanceToLockedKm = 9999.0
        locationManager.startUpdatingLocation()
        if hasRealGps {
            checkStationsNow(deepScan: true, autoOpenGMapsOnLock: false)
        }
    }

    @objc private func onTapFilterPins() {
        minPinsRequired = minPinsRequired == 2 ? 3 : (minPinsRequired == 3 ? 1 : 2)
        btnFilterPins.setTitle(">= \(minPinsRequired) PIN", for: .normal)
        lockedStation = nil
        minDistanceToLockedKm = 9999.0
        checkStationsNow(deepScan: true, autoOpenGMapsOnLock: false)
    }

    @objc private func onTapSkipStation() {
        if let st = lockedStation {
            blacklistedCodes.insert(st.code)
            lockedStation = nil
            minDistanceToLockedKm = 9999.0
            checkStationsNow(deepScan: true, autoOpenGMapsOnLock: true)
        }
    }

    @objc private func onTapTestBgReroute() {
        guard let st = lockedStation else { return }
        speakVietnamese("Bắt đầu bài test. Mở Google Maps ngay bây giờ. Sau 6 giây ứng dụng sẽ giả lập đổi hướng sang tủ mới để bạn thử nghiệm thông báo!")
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
        minDistanceToLockedKm = chosen.distanceKm
        refreshUI()
        speakVietnamese("Đã chọn tủ \(chosen.name), còn \(chosen.avail) pin đầy. Đang mở Google Maps.")
        openInGoogleMaps(station: chosen)
    }

    override var preferredStatusBarStyle: UIStatusBarStyle {
        return .lightContent
    }
}
