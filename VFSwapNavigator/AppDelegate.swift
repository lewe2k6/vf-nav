import UIKit
import CoreLocation
import AVFoundation
import AVKit
import UserNotifications
import MapKit
import CoreMedia
import CoreVideo

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
    var detourKm: Double?
    var drainedCount: Int

    var googleMapsAppUrl: URL? {
        URL(string: String(format: "comgooglemaps://?daddr=%.6f,%.6f&directionsmode=two-wheeler", lat, lng))
    }

    var googleMapsWebUrl: URL? {
        URL(string: String(format: "https://www.google.com/maps/dir/?api=1&destination=%.6f,%.6f&travelmode=two-wheeler", lat, lng))
    }
}

struct BlockedStationEntry: Codable {
    let code: String
    let name: String
    let unblockTimestamp: Double? // nil = Chặn vĩnh viễn, có giá trị = Thời điểm mở chặn (24h)
}

struct SavedDestination: Codable {
    let label: String
    let address: String
    let lat: Double
    let lng: Double

    var googleMapsAppUrl: URL? {
        URL(string: String(format: "comgooglemaps://?daddr=%.6f,%.6f&directionsmode=two-wheeler", lat, lng))
    }

    var googleMapsWebUrl: URL? {
        URL(string: String(format: "https://www.google.com/maps/dir/?api=1&destination=%.6f,%.6f&travelmode=two-wheeler", lat, lng))
    }
}

final class PiPSampleBufferView: UIView {
    override class var layerClass: AnyClass {
        return AVSampleBufferDisplayLayer.self
    }
    var sampleBufferLayer: AVSampleBufferDisplayLayer {
        return layer as! AVSampleBufferDisplayLayer
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

class RadarViewController: UIViewController,
                           CLLocationManagerDelegate,
                           UNUserNotificationCenterDelegate,
                           AVPictureInPictureControllerDelegate,
                           AVPictureInPictureSampleBufferPlaybackDelegate {
    private let locationManager = CLLocationManager()
    private let synthesizer = AVSpeechSynthesizer()
    private var silentPlayer: AVAudioPlayer?
    private var cronTimer: Timer?
    private var pipFrameTimer: Timer?
    private var bgTask: UIBackgroundTaskIdentifier = .invalid

    // MARK: - PiP HUD (Tính năng #1)
    private let pipBufferView = PiPSampleBufferView()
    private var pipController: AVPictureInPictureController?
    private var pipStatusBannerText: String = "ĐANG CANH PIN 3 GIÂY/LẦN"
    private var pipIsWarningAlert: Bool = false

    // MARK: - Trạng thái GPS, Hướng Di Chuyển & Trạm
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

    // Theo dõi khoảng cách ngắn nhất từng đạt được tới tủ đang khóa
    private var minDistanceToLockedKm: Double = 9999.0
    private var autoRerouteByDirection: Bool = true

    // Tính năng #2: Theo dõi tốc độ tụt pin của từng tủ (Drain Rate Alert)
    private var prevAvailByCode: [String: Int] = [:]
    private var drainedAmountByCode: [String: Int] = [:]

    // Tính năng #4: Sổ đen chặn tủ tạm thời / vĩnh viễn
    private let blockedDefaultsKey = "VF_BLOCKED_STATIONS_V1"
    private var sessionSkippedCodes = Set<String>()
    private var simulatedEmptyCodes = Set<String>()

    // Tính năng #5: Điểm đích tiện đường đi (Route Corridor)
    private let homeDestKey = "VF_SAVED_DEST_HOME_V1"
    private let workDestKey = "VF_SAVED_DEST_WORK_V1"
    private var activeDestination: SavedDestination?

    // Tính năng #6: Tự nhận diện đã tới sát tủ (<= 45m)
    private var isAtStation: Bool = false
    private var swappedAtStationCompleted: Bool = false

    private var minPinsRequired: Int = 2
    private var lockedStation: SwapStation?
    private var topStations: [SwapStation] = []
    private var isChecking: Bool = false
    private var cronCount: Int = 0
    private var pendingAutoOpenGoogleMaps: Bool = false

    // MARK: - Giao diện Native UIKit
    private let statusBadge = UILabel()
    private let gpsLabel = UILabel()
    private let btnFilterPins = UIButton(type: .system)
    private let btnToggleDirection = UIButton(type: .system)
    private let btnTogglePiP = UIButton(type: .system)

    // Thanh Điểm Đích Tiện Đường (#5)
    private let destStatusLabel = UILabel()
    private let btnDestHome = UIButton(type: .system)
    private let btnDestWork = UIButton(type: .system)
    private let btnDestCustom = UIButton(type: .system)
    private let btnDestClear = UIButton(type: .system)

    // Thẻ Tủ Mục Tiêu & Cảnh Báo Trạm (#6)
    private let arrivalBannerButton = UIButton(type: .system)
    private let targetTitleLabel = UILabel()
    private let targetNameLabel = UILabel()
    private let targetAddrLabel = UILabel()
    private let targetPinBadge = UILabel()
    private let targetDistLabel = UILabel()
    private let btnOpenGMaps = UIButton(type: .system)
    private let btnTestBgReroute = UIButton(type: .system)
    private let btnBlockMenu = UIButton(type: .system)
    private let top5Stack = UIStackView()

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor(red: 0.04, green: 0.06, blue: 0.10, alpha: 1.0)

        setupAudioKeepAlive()
        setupNotifications()
        setupUI()
        setupPiPController()
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

    // MARK: - 1. SILENT AUDIO & PICTURE-IN-PICTURE HUD ĐÈ LÊN GOOGLE MAPS
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
        data.append(contentsOf: [0x52, 0x49, 0x46, 0x46])
        var leFileSize = fileSize.littleEndian
        data.append(Data(bytes: &leFileSize, count: 4))
        data.append(contentsOf: [0x57, 0x41, 0x56, 0x45])
        data.append(contentsOf: [0x66, 0x6D, 0x74, 0x20])

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

        data.append(contentsOf: [0x64, 0x61, 0x74, 0x61])
        var leDataSize = dataSize.littleEndian
        data.append(Data(bytes: &leDataSize, count: 4))
        data.append(Data(count: Int(dataSize)))
        return data
    }

    private func setupPiPController() {
        var timebase: CMTimebase?
        CMTimebaseCreateWithSourceClock(
            allocator: kCFAllocatorDefault,
            sourceClock: CMClockGetHostTimeClock(),
            timebaseOut: &timebase
        )
        if let tb = timebase {
            CMTimebaseSetTime(tb, time: .zero)
            CMTimebaseSetRate(tb, rate: 1.0)
            pipBufferView.sampleBufferLayer.controlTimebase = tb
        }
        pipBufferView.sampleBufferLayer.videoGravity = .resizeAspect

        renderHudFrameToPiP()

        if AVPictureInPictureController.isPictureInPictureSupported(), #available(iOS 15.0, *) {
            let contentSource = AVPictureInPictureController.ContentSource(
                sampleBufferDisplayLayer: pipBufferView.sampleBufferLayer,
                playbackDelegate: self
            )
            let pip = AVPictureInPictureController(contentSource: contentSource)
            pip.delegate = self
            pip.canStartPictureInPictureAutomaticallyFromInline = true
            if #available(iOS 14.2, *) {
                pip.requiresLinearPlayback = false
            }
            self.pipController = pip
        }

        let fTimer = Timer(timeInterval: 1.5, repeats: true) { [weak self] _ in
            self?.renderHudFrameToPiP()
        }
        RunLoop.main.add(fTimer, forMode: .common)
        self.pipFrameTimer = fTimer
    }

    private func renderHudFrameToPiP() {
        let width = 640
        let height = 190
        let size = CGSize(width: width, height: height)

        let renderer = UIGraphicsImageRenderer(size: size)
        let img = renderer.image { ctx in
            let rect = CGRect(origin: .zero, size: size)
            let bgColor = isAtStation
                ? UIColor(red: 0.04, green: 0.22, blue: 0.16, alpha: 1.0)
                : (pipIsWarningAlert
                    ? UIColor(red: 0.32, green: 0.08, blue: 0.08, alpha: 1.0)
                    : UIColor(red: 0.05, green: 0.08, blue: 0.14, alpha: 1.0))
            bgColor.setFill()
            ctx.fill(rect)

            let borderPath = UIBezierPath(roundedRect: rect.insetBy(dx: 3, dy: 3), cornerRadius: 16)
            borderPath.lineWidth = 4
            let strokeColor = isAtStation
                ? UIColor(red: 0.20, green: 0.95, blue: 0.65, alpha: 1.0)
                : (pipIsWarningAlert
                    ? UIColor(red: 0.98, green: 0.35, blue: 0.35, alpha: 1.0)
                    : UIColor(red: 0.06, green: 0.72, blue: 0.50, alpha: 1.0))
            strokeColor.setStroke()
            borderPath.stroke()

            let topStatus = isAtStation
                ? "ĐANG ĐỨNG TẠI TRẠM (TẠM KHÓA ĐỔI TỦ)"
                : pipStatusBannerText
            let topAttrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 20, weight: .heavy),
                .foregroundColor: pipIsWarningAlert
                    ? UIColor(red: 1.0, green: 0.75, blue: 0.35, alpha: 1.0)
                    : UIColor(red: 0.38, green: 0.88, blue: 0.70, alpha: 1.0)
            ]
            (topStatus as NSString).draw(in: CGRect(x: 18, y: 14, width: 430, height: 28), withAttributes: topAttrs)

            if let st = lockedStation {
                let badgeRect = CGRect(x: 455, y: 12, width: 168, height: 42)
                let badgePath = UIBezierPath(roundedRect: badgeRect, cornerRadius: 10)
                UIColor(red: 0.06, green: 0.72, blue: 0.50, alpha: 1.0).setFill()
                badgePath.fill()

                let pinStr = "\(st.avail)/\(st.total) PIN"
                let pinStyle = NSMutableParagraphStyle()
                pinStyle.alignment = .center
                let pinAttrs: [NSAttributedString.Key: Any] = [
                    .font: UIFont.systemFont(ofSize: 24, weight: .black),
                    .foregroundColor: UIColor(red: 0.02, green: 0.16, blue: 0.08, alpha: 1.0),
                    .paragraphStyle: pinStyle
                ]
                (pinStr as NSString).draw(in: CGRect(x: 455, y: 18, width: 168, height: 32), withAttributes: pinAttrs)

                let nameAttrs: [NSAttributedString.Key: Any] = [
                    .font: UIFont.systemFont(ofSize: 27, weight: .black),
                    .foregroundColor: UIColor.white
                ]
                (st.name as NSString).draw(in: CGRect(x: 18, y: 56, width: 604, height: 68), withAttributes: nameAttrs)

                let durText = st.durationMin != nil ? " (~\(st.durationMin!)p)" : ""
                let detourText = st.detourKm != nil ? String(format: " • Lệch đích +%.1fkm", st.detourKm!) : ""
                let drainText = st.drainedCount > 0 ? " • VỪA TỤT -\(st.drainedCount) PIN!" : ""
                let charging = max(0, st.total - st.avail)
                let bottomLine = "Cách \(st.distanceKm) km\(durText) • Đang sạc: \(charging)\(detourText)\(drainText)"
                let botAttrs: [NSAttributedString.Key: Any] = [
                    .font: UIFont.systemFont(ofSize: 22, weight: .bold),
                    .foregroundColor: UIColor(red: 0.75, green: 0.88, blue: 1.0, alpha: 1.0)
                ]
                (bottomLine as NSString).draw(in: CGRect(x: 18, y: 138, width: 604, height: 36), withAttributes: botAttrs)
            } else {
                let waitAttrs: [NSAttributedString.Key: Any] = [
                    .font: UIFont.systemFont(ofSize: 26, weight: .bold),
                    .foregroundColor: UIColor.white
                ]
                ("Đang quét tìm tủ đủ >= \(minPinsRequired) pin đầy..." as NSString).draw(
                    in: CGRect(x: 18, y: 78, width: 604, height: 50),
                    withAttributes: waitAttrs
                )
            }
        }

        guard let cgImage = img.cgImage else { return }
        enqueueCGImageToSampleBufferLayer(cgImage: cgImage, width: width, height: height)
    }

    private func enqueueCGImageToSampleBufferLayer(cgImage: CGImage, width: Int, height: Int) {
        let attrs: [CFString: Any] = [
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as [String: Any]
        ]
        var pixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_32BGRA,
            attrs as CFDictionary,
            &pixelBuffer
        )
        guard status == kCVReturnSuccess, let pxBuffer = pixelBuffer else { return }

        CVPixelBufferLockBaseAddress(pxBuffer, [])
        if let baseAddress = CVPixelBufferGetBaseAddress(pxBuffer) {
            let bytesPerRow = CVPixelBufferGetBytesPerRow(pxBuffer)
            let colorSpace = CGColorSpaceCreateDeviceRGB()
            let bitmapInfo = CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue
            if let context = CGContext(
                data: baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: bytesPerRow,
                space: colorSpace,
                bitmapInfo: bitmapInfo
            ) {
                context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
            }
        }
        CVPixelBufferUnlockBaseAddress(pxBuffer, [])

        var formatDesc: CMVideoFormatDescription?
        guard CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pxBuffer,
            formatDescriptionOut: &formatDesc
        ) == noErr, let fmt = formatDesc else { return }

        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: 2),
            presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()),
            decodeTimeStamp: .invalid
        )
        var sampleBuffer: CMSampleBuffer?
        guard CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pxBuffer,
            formatDescription: fmt,
            sampleTiming: &timing,
            sampleBufferOut: &sampleBuffer
        ) == noErr, let sBuf = sampleBuffer else { return }

        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sBuf, createIfNecessary: true) {
            let dict = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(
                dict,
                Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                Unmanaged.passUnretained(kCFBooleanTrue).toOpaque()
            )
        }

        let layer = pipBufferView.sampleBufferLayer
        if layer.status == .failed {
            layer.flush()
        }
        layer.enqueue(sBuf)
    }

    // MARK: - AVPictureInPicturePlaybackDelegate
    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, setPlaying playing: Bool) {}

    func pictureInPictureControllerTimeRangeForPlayback(_ pictureInPictureController: AVPictureInPictureController) -> CMTimeRange {
        return CMTimeRange(start: .negativeInfinity, duration: .positiveInfinity)
    }

    func pictureInPictureControllerIsPlaybackPaused(_ pictureInPictureController: AVPictureInPictureController) -> Bool {
        return false
    }

    func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        didTransitionToRenderSize newRenderSize: CMVideoDimensions
    ) {
        renderHudFrameToPiP()
    }

    func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        skipByInterval skipInterval: CMTime,
        completion completionHandler: @escaping () -> Void
    ) {
        completionHandler()
    }

    @objc private func onTapTogglePiP() {
        guard let pip = pipController else {
            speakVietnamese("Thiết bị này không hỗ trợ cửa sổ nổi PiP.")
            return
        }
        renderHudFrameToPiP()
        if pip.isPictureInPictureActive {
            pip.stopPictureInPicture()
            btnTogglePiP.setTitle("📺 Bật Cửa Sổ Nổi PiP Đè Lên Google Maps", for: .normal)
        } else {
            pip.startPictureInPicture()
            btnTogglePiP.setTitle("📺 Đang Bật Cửa Sổ Nổi PiP (Chạm Để Thu Nhỏ)", for: .normal)
        }
    }

    @objc private func appDidEnterBackground() {
        if silentPlayer?.isPlaying != true {
            silentPlayer?.play()
        }
        renderHudFrameToPiP()
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
        content.spacing = 10
        content.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(content)

        let safe = view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: safe.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: safe.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: safe.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: safe.trailingAnchor),

            content.topAnchor.constraint(equalTo: scroll.topAnchor, constant: 8),
            content.bottomAnchor.constraint(equalTo: scroll.bottomAnchor, constant: -24),
            content.leadingAnchor.constraint(equalTo: scroll.leadingAnchor, constant: 14),
            content.trailingAnchor.constraint(equalTo: scroll.trailingAnchor, constant: -14),
            content.widthAnchor.constraint(equalTo: scroll.widthAnchor, constant: -28)
        ])

        // Header Row 1: Status & Filter/Refresh
        let headerRow = UIStackView()
        headerRow.axis = .horizontal
        headerRow.alignment = .center
        headerRow.distribution = .equalSpacing

        statusBadge.text = "🟢 CANH PIN 3s (#0)"
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

        // GPS Label
        gpsLabel.text = "📍 Đang lấy tọa độ GPS vệ tinh chính xác từ iPhone..."
        gpsLabel.font = UIFont.systemFont(ofSize: 11.5, weight: .medium)
        gpsLabel.textColor = UIColor(red: 0.58, green: 0.64, blue: 0.72, alpha: 1.0)
        gpsLabel.numberOfLines = 2
        content.addArrangedSubview(gpsLabel)

        // Khung Live Preview của Cửa Sổ Nổi PiP HUD (#1)
        let pipSection = UIStackView()
        pipSection.axis = .vertical
        pipSection.spacing = 6

        pipBufferView.translatesAutoresizingMaskIntoConstraints = false
        pipBufferView.layer.cornerRadius = 12
        pipBufferView.clipsToBounds = true
        NSLayoutConstraint.activate([
            pipBufferView.heightAnchor.constraint(equalToConstant: 92)
        ])

        btnTogglePiP.setTitle("📺 Bật Cửa Sổ Nổi PiP Đè Lên Google Maps", for: .normal)
        btnTogglePiP.titleLabel?.font = UIFont.systemFont(ofSize: 12, weight: .heavy)
        btnTogglePiP.backgroundColor = UIColor(red: 0.14, green: 0.22, blue: 0.38, alpha: 1.0)
        btnTogglePiP.setTitleColor(UIColor(red: 0.55, green: 0.82, blue: 1.0, alpha: 1.0), for: .normal)
        btnTogglePiP.layer.cornerRadius = 9
        btnTogglePiP.contentEdgeInsets = UIEdgeInsets(top: 8, left: 10, bottom: 8, right: 10)
        btnTogglePiP.addTarget(self, action: #selector(onTapTogglePiP), for: .touchUpInside)

        pipSection.addArrangedSubview(pipBufferView)
        pipSection.addArrangedSubview(btnTogglePiP)
        content.addArrangedSubview(pipSection)

        // Thanh Chọn Điểm Đích Tiện Đường Đi (#5)
        let destCard = UIView()
        destCard.backgroundColor = UIColor(red: 0.07, green: 0.11, blue: 0.18, alpha: 1.0)
        destCard.layer.cornerRadius = 12
        destCard.layer.borderWidth = 1
        destCard.layer.borderColor = UIColor(red: 0.18, green: 0.26, blue: 0.38, alpha: 1.0).cgColor

        let destStack = UIStackView()
        destStack.axis = .vertical
        destStack.spacing = 7
        destStack.translatesAutoresizingMaskIntoConstraints = false
        destCard.addSubview(destStack)

        NSLayoutConstraint.activate([
            destStack.topAnchor.constraint(equalTo: destCard.topAnchor, constant: 9),
            destStack.bottomAnchor.constraint(equalTo: destCard.bottomAnchor, constant: -9),
            destStack.leadingAnchor.constraint(equalTo: destCard.leadingAnchor, constant: 10),
            destStack.trailingAnchor.constraint(equalTo: destCard.trailingAnchor, constant: -10)
        ])

        destStatusLabel.text = "🛣️ Tiện đường về đích: ĐANG TẮT (Tìm tủ gần nhất theo hướng xe)"
        destStatusLabel.font = UIFont.systemFont(ofSize: 11.5, weight: .bold)
        destStatusLabel.textColor = UIColor(red: 0.70, green: 0.78, blue: 0.88, alpha: 1.0)
        destStatusLabel.numberOfLines = 2

        let destBtnRow = UIStackView()
        destBtnRow.axis = .horizontal
        destBtnRow.spacing = 6
        destBtnRow.distribution = .fillEqually

        styleSmallButton(btnDestHome, title: "🏠 Về Nhà")
        btnDestHome.addTarget(self, action: #selector(onTapDestHome), for: .touchUpInside)

        styleSmallButton(btnDestWork, title: "🏢 Chỗ Làm")
        btnDestWork.addTarget(self, action: #selector(onTapDestWork), for: .touchUpInside)

        styleSmallButton(btnDestCustom, title: "📍 Đích Khác")
        btnDestCustom.addTarget(self, action: #selector(onTapDestCustom), for: .touchUpInside)

        styleSmallButton(btnDestClear, title: "❌ Tắt Đích")
        btnDestClear.addTarget(self, action: #selector(onTapDestClear), for: .touchUpInside)

        destBtnRow.addArrangedSubview(btnDestHome)
        destBtnRow.addArrangedSubview(btnDestWork)
        destBtnRow.addArrangedSubview(btnDestCustom)
        destBtnRow.addArrangedSubview(btnDestClear)

        destStack.addArrangedSubview(destStatusLabel)
        destStack.addArrangedSubview(destBtnRow)
        content.addArrangedSubview(destCard)

        // Nút Bật/Tắt Tự Đổi Tủ Theo Hướng Xe
        btnToggleDirection.setTitle("🧭 Tự động đổi sang tủ gần nhất theo hướng di chuyển: BẬT", for: .normal)
        btnToggleDirection.titleLabel?.font = UIFont.systemFont(ofSize: 11.5, weight: .bold)
        btnToggleDirection.backgroundColor = UIColor(red: 0.07, green: 0.25, blue: 0.22, alpha: 1.0)
        btnToggleDirection.setTitleColor(UIColor(red: 0.43, green: 0.91, blue: 0.72, alpha: 1.0), for: .normal)
        btnToggleDirection.layer.cornerRadius = 10
        btnToggleDirection.layer.borderWidth = 1
        btnToggleDirection.layer.borderColor = UIColor(red: 0.06, green: 0.72, blue: 0.50, alpha: 0.6).cgColor
        btnToggleDirection.contentEdgeInsets = UIEdgeInsets(top: 8, left: 10, bottom: 8, right: 10)
        btnToggleDirection.addTarget(self, action: #selector(onTapToggleDirection), for: .touchUpInside)
        content.addArrangedSubview(btnToggleDirection)

        // Banner Chế độ Đang Đứng Tại Trạm Đổi Pin (#6)
        arrivalBannerButton.isHidden = true
        arrivalBannerButton.titleLabel?.font = UIFont.systemFont(ofSize: 13, weight: .black)
        arrivalBannerButton.titleLabel?.numberOfLines = 0
        arrivalBannerButton.titleLabel?.textAlignment = .center
        arrivalBannerButton.backgroundColor = UIColor(red: 0.05, green: 0.55, blue: 0.38, alpha: 1.0)
        arrivalBannerButton.setTitleColor(.white, for: .normal)
        arrivalBannerButton.layer.cornerRadius = 12
        arrivalBannerButton.contentEdgeInsets = UIEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        arrivalBannerButton.addTarget(self, action: #selector(onTapArrivalBanner), for: .touchUpInside)
        content.addArrangedSubview(arrivalBannerButton)

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
            targetStack.topAnchor.constraint(equalTo: targetCard.topAnchor, constant: 13),
            targetStack.bottomAnchor.constraint(equalTo: targetCard.bottomAnchor, constant: -13),
            targetStack.leadingAnchor.constraint(equalTo: targetCard.leadingAnchor, constant: 13),
            targetStack.trailingAnchor.constraint(equalTo: targetCard.trailingAnchor, constant: -13)
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
        targetNameLabel.font = UIFont.systemFont(ofSize: 17.5, weight: .black)
        targetNameLabel.textColor = .white
        targetNameLabel.numberOfLines = 2

        targetAddrLabel.text = "Hãy chọn 'Cho phép khi dùng ứng dụng' nếu iPhone hỏi quyền Vị Trí."
        targetAddrLabel.font = UIFont.systemFont(ofSize: 12.5, weight: .medium)
        targetAddrLabel.textColor = UIColor(red: 0.75, green: 0.80, blue: 0.88, alpha: 1.0)
        targetAddrLabel.numberOfLines = 0

        targetDistLabel.text = "Lộ trình thực tế: -- km"
        targetDistLabel.font = UIFont.systemFont(ofSize: 14.5, weight: .heavy)
        targetDistLabel.textColor = UIColor(red: 0.20, green: 0.90, blue: 0.60, alpha: 1.0)
        targetDistLabel.numberOfLines = 2

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
        btnOpenGMaps.contentEdgeInsets = UIEdgeInsets(top: 14, left: 16, bottom: 14, right: 16)
        btnOpenGMaps.addTarget(self, action: #selector(onTapOpenGMaps), for: .touchUpInside)
        content.addArrangedSubview(btnOpenGMaps)

        let subActionRow = UIStackView()
        subActionRow.axis = .horizontal
        subActionRow.spacing = 10
        subActionRow.distribution = .fillEqually

        btnTestBgReroute.setTitle("🧪 Test Đổi Tủ (6s)", for: .normal)
        btnTestBgReroute.titleLabel?.font = UIFont.systemFont(ofSize: 12.5, weight: .bold)
        btnTestBgReroute.backgroundColor = UIColor(red: 0.85, green: 0.47, blue: 0.02, alpha: 1.0)
        btnTestBgReroute.setTitleColor(.white, for: .normal)
        btnTestBgReroute.layer.cornerRadius = 12
        btnTestBgReroute.contentEdgeInsets = UIEdgeInsets(top: 12, left: 8, bottom: 12, right: 8)
        btnTestBgReroute.addTarget(self, action: #selector(onTapTestBgReroute), for: .touchUpInside)

        btnBlockMenu.setTitle("🚫 Chặn / Sổ Đen Tủ", for: .normal)
        btnBlockMenu.titleLabel?.font = UIFont.systemFont(ofSize: 12.5, weight: .bold)
        btnBlockMenu.backgroundColor = UIColor(red: 0.45, green: 0.14, blue: 0.18, alpha: 1.0)
        btnBlockMenu.setTitleColor(.white, for: .normal)
        btnBlockMenu.layer.cornerRadius = 12
        btnBlockMenu.contentEdgeInsets = UIEdgeInsets(top: 12, left: 8, bottom: 12, right: 8)
        btnBlockMenu.addTarget(self, action: #selector(onTapBlockMenu), for: .touchUpInside)

        subActionRow.addArrangedSubview(btnTestBgReroute)
        subActionRow.addArrangedSubview(btnBlockMenu)
        content.addArrangedSubview(subActionRow)

        let top5Header = UILabel()
        top5Header.text = "📋 TOP 5 TỦ PHÙ HỢP NHẤT HIỆN TẠI"
        top5Header.font = UIFont.systemFont(ofSize: 13, weight: .heavy)
        top5Header.textColor = UIColor(red: 0.06, green: 0.72, blue: 0.50, alpha: 1.0)
        content.addArrangedSubview(top5Header)

        top5Stack.axis = .vertical
        top5Stack.spacing = 10
        content.addArrangedSubview(top5Stack)

        updateBlockedButtonTitle()
    }

    private func styleSmallButton(_ btn: UIButton, title: String) {
        btn.setTitle(title, for: .normal)
        btn.titleLabel?.font = UIFont.systemFont(ofSize: 11, weight: .bold)
        btn.backgroundColor = UIColor(red: 0.13, green: 0.19, blue: 0.29, alpha: 1.0)
        btn.setTitleColor(.white, for: .normal)
        btn.layer.cornerRadius = 8
        btn.contentEdgeInsets = UIEdgeInsets(top: 7, left: 4, bottom: 7, right: 4)
    }

    // MARK: - 4. SỔ ĐEN CHẶN TỦ 24H / VĨNH VIỄN (Tính năng #4)
    private func loadBlockedEntries() -> [BlockedStationEntry] {
        guard let data = UserDefaults.standard.data(forKey: blockedDefaultsKey),
              let arr = try? JSONDecoder().decode([BlockedStationEntry].self, from: data) else {
            return []
        }
        let now = Date().timeIntervalSince1970
        let valid = arr.filter { entry in
            if let exp = entry.unblockTimestamp {
                return exp > now
            }
            return true
        }
        if valid.count != arr.count {
            saveBlockedEntries(valid)
        }
        return valid
    }

    private func saveBlockedEntries(_ entries: [BlockedStationEntry]) {
        if let data = try? JSONEncoder().encode(entries) {
            UserDefaults.standard.set(data, forKey: blockedDefaultsKey)
        }
        updateBlockedButtonTitle()
    }

    private func addStationToBlacklist(_ station: SwapStation, durationHours: Double?) {
        var current = loadBlockedEntries().filter { $0.code != station.code }
        let exp = durationHours != nil ? Date().timeIntervalSince1970 + (durationHours! * 3600.0) : nil
        current.append(BlockedStationEntry(code: station.code, name: station.name, unblockTimestamp: exp))
        saveBlockedEntries(current)
    }

    private func updateBlockedButtonTitle() {
        let count = loadBlockedEntries().count + sessionSkippedCodes.count
        let suffix = count > 0 ? " (\(count))" : ""
        btnBlockMenu.setTitle("🚫 Chặn / Sổ Đen\(suffix)", for: .normal)
    }

    @objc private func onTapBlockMenu() {
        let alert = UIAlertController(
            title: "Chặn Tủ Lỗi / Quản Lý Sổ Đen",
            message: lockedStation != nil
                ? "Tủ đang khóa: \(lockedStation!.name)\nBạn muốn bỏ qua hay chặn tủ này?"
                : "Quản lý danh sách các tủ đã bị chặn",
            preferredStyle: .actionSheet
        )

        if let st = lockedStation {
            alert.addAction(UIAlertAction(title: "⏭️ Bỏ qua tạm thời (Chỉ trong chuyến này)", style: .default) { [weak self] _ in
                guard let self = self else { return }
                self.sessionSkippedCodes.insert(st.code)
                self.updateBlockedButtonTitle()
                self.switchAfterBlockingCurrent()
            })

            alert.addAction(UIAlertAction(title: "⏳ Chặn 24 Giờ (Tủ đang bảo trì / kẹt khay)", style: .default) { [weak self] _ in
                guard let self = self else { return }
                self.addStationToBlacklist(st, durationHours: 24.0)
                self.speakVietnamese("Đã chặn tủ \(st.name) trong 24 giờ và chuyển sang tủ khác.")
                self.switchAfterBlockingCurrent()
            })

            alert.addAction(UIAlertAction(title: "🚫 Chặn Vĩnh Viễn (Tủ nội bộ / cấm vào)", style: .destructive) { [weak self] _ in
                guard let self = self else { return }
                self.addStationToBlacklist(st, durationHours: nil)
                self.speakVietnamese("Đã đưa tủ \(st.name) vào sổ đen vĩnh viễn.")
                self.switchAfterBlockingCurrent()
            })
        }

        let blockedList = loadBlockedEntries()
        if !blockedList.isEmpty || !sessionSkippedCodes.isEmpty {
            alert.addAction(UIAlertAction(title: "🗂️ Xem & Gỡ chặn (\(blockedList.count + sessionSkippedCodes.count) tủ)", style: .default) { [weak self] _ in
                self?.showUnblockListSheet()
            })
        }

        alert.addAction(UIAlertAction(title: "Đóng", style: .cancel))
        if let pop = alert.popoverPresentationController {
            pop.sourceView = btnBlockMenu
            pop.sourceRect = btnBlockMenu.bounds
        }
        present(alert, animated: true)
    }

    private func showUnblockListSheet() {
        let entries = loadBlockedEntries()
        let sheet = UIAlertController(
            title: "Danh Sách Tủ Đang Chặn",
            message: "Chạm vào tên tủ bất kỳ để gỡ chặn ngay lập tức:",
            preferredStyle: .actionSheet
        )

        for item in entries {
            let tag = item.unblockTimestamp == nil ? "[Vĩnh viễn]" : "[24h]"
            sheet.addAction(UIAlertAction(title: "🔓 Gỡ: \(tag) \(item.name)", style: .default) { [weak self] _ in
                guard let self = self else { return }
                let remain = self.loadBlockedEntries().filter { $0.code != item.code }
                self.saveBlockedEntries(remain)
                self.checkStationsNow(deepScan: true, autoOpenGMapsOnLock: false)
            })
        }

        sheet.addAction(UIAlertAction(title: "🗑️ Xóa sạch toàn bộ Sổ Đen", style: .destructive) { [weak self] _ in
            guard let self = self else { return }
            self.sessionSkippedCodes.removeAll()
            self.saveBlockedEntries([])
            self.checkStationsNow(deepScan: true, autoOpenGMapsOnLock: false)
        })

        sheet.addAction(UIAlertAction(title: "Quay lại", style: .cancel))
        if let pop = sheet.popoverPresentationController {
            pop.sourceView = btnBlockMenu
            pop.sourceRect = btnBlockMenu.bounds
        }
        present(sheet, animated: true)
    }

    private func switchAfterBlockingCurrent() {
        lockedStation = nil
        isAtStation = false
        minDistanceToLockedKm = 9999.0
        checkStationsNow(deepScan: true, autoOpenGMapsOnLock: true)
    }

    // MARK: - 5. CHẾ ĐỘ TÌM TỦ TIỆN ĐƯỜNG ĐI VỀ ĐÍCH (Tính năng #5)
    private func loadSavedDestination(key: String) -> SavedDestination? {
        guard let data = UserDefaults.standard.data(forKey: key),
              let dest = try? JSONDecoder().decode(SavedDestination.self, from: data) else {
            return nil
        }
        return dest
    }

    private func saveDestination(_ dest: SavedDestination, key: String) {
        if let data = try? JSONEncoder().encode(dest) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    @objc private func onTapDestHome() {
        handlePresetDestinationTap(label: "Nhà", storageKey: homeDestKey)
    }

    @objc private func onTapDestWork() {
        handlePresetDestinationTap(label: "Chỗ Làm", storageKey: workDestKey)
    }

    private func handlePresetDestinationTap(label: String, storageKey: String) {
        if let saved = loadSavedDestination(key: storageKey) {
            let sheet = UIAlertController(
                title: "Điểm Đích: \(label)",
                message: "Địa chỉ đã lưu: \(saved.address)",
                preferredStyle: .actionSheet
            )
            sheet.addAction(UIAlertAction(title: "✅ Bật tìm tủ tiện đường về \(label)", style: .default) { [weak self] _ in
                self?.activateDestination(saved)
            })
            sheet.addAction(UIAlertAction(title: "✏️ Đổi lại địa chỉ \(label)...", style: .default) { [weak self] _ in
                self?.promptSearchDestination(label: label, saveKey: storageKey)
            })
            sheet.addAction(UIAlertAction(title: "Hủy", style: .cancel))
            if let pop = sheet.popoverPresentationController {
                pop.sourceView = view
                pop.sourceRect = CGRect(x: view.bounds.midX, y: 180, width: 1, height: 1)
            }
            present(sheet, animated: true)
        } else {
            promptSearchDestination(label: label, saveKey: storageKey)
        }
    }

    @objc private func onTapDestCustom() {
        promptSearchDestination(label: "Điểm Đích", saveKey: nil)
    }

    @objc private func onTapDestClear() {
        activeDestination = nil
        destStatusLabel.text = "🛣️ Tiện đường về đích: ĐANG TẮT (Tìm tủ gần nhất theo hướng xe)"
        destStatusLabel.textColor = UIColor(red: 0.70, green: 0.78, blue: 0.88, alpha: 1.0)
        lockedStation = nil
        minDistanceToLockedKm = 9999.0
        speakVietnamese("Đã tắt chế độ điểm đích, chuyển về tìm tủ gần nhất.")
        checkStationsNow(deepScan: true, autoOpenGMapsOnLock: false)
    }

    private func promptSearchDestination(label: String, saveKey: String?) {
        let alert = UIAlertController(
            title: "Thiết Lập \(label)",
            message: "Nhập tên đường, tòa nhà hoặc quận/huyện (hoặc lấy luôn vị trí GPS đang đứng):",
            preferredStyle: .alert
        )
        alert.addTextField { tf in
            tf.placeholder = "VD: 120 Nguyễn Trãi, Thanh Xuân, Hà Nội"
            tf.clearButtonMode = .whileEditing
        }

        alert.addAction(UIAlertAction(title: "🔍 Tìm & Chọn Địa Chỉ Này", style: .default) { [weak self] _ in
            guard let self = self else { return }
            let query = (alert.textFields?.first?.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !query.isEmpty else { return }
            self.geocodeAndSetDestination(query: query, label: label, saveKey: saveKey)
        })

        if hasRealGps {
            alert.addAction(UIAlertAction(title: "📍 Lấy Vị Trí GPS Hiện Tại Làm \(label)", style: .default) { [weak self] _ in
                guard let self = self else { return }
                let dest = SavedDestination(
                    label: label,
                    address: String(format: "Tọa độ GPS (%.4f, %.4f)", self.userLat, self.userLng),
                    lat: self.userLat,
                    lng: self.userLng
                )
                if let key = saveKey {
                    self.saveDestination(dest, key: key)
                }
                self.activateDestination(dest)
            })
        }

        alert.addAction(UIAlertAction(title: "Hủy", style: .cancel))
        present(alert, animated: true)
    }

    private func geocodeAndSetDestination(query: String, label: String, saveKey: String?) {
        destStatusLabel.text = "⏳ Đang tìm tọa độ cho '\(query)'..."
        let req = MKLocalSearch.Request()
        req.naturalLanguageQuery = query
        if hasRealGps {
            req.region = MKCoordinateRegion(
                center: CLLocationCoordinate2D(latitude: userLat, longitude: userLng),
                latitudinalMeters: 30000,
                longitudinalMeters: 30000
            )
        }
        MKLocalSearch(request: req).start { [weak self] resp, _ in
            DispatchQueue.main.async {
                guard let self = self else { return }
                if let item = resp?.mapItems.first {
                    let coord = item.placemark.coordinate
                    let name = item.name ?? query
                    let dest = SavedDestination(label: label, address: name, lat: coord.latitude, lng: coord.longitude)
                    if let key = saveKey {
                        self.saveDestination(dest, key: key)
                    }
                    self.activateDestination(dest)
                } else {
                    self.destStatusLabel.text = "⚠️ Không tìm thấy '\(query)'. Hãy thử nhập rõ tên đường/quận hơn."
                }
            }
        }
    }

    private func activateDestination(_ dest: SavedDestination) {
        activeDestination = dest
        destStatusLabel.text = "🛣️ Đang lọc tủ tiện đường về [\(dest.label)]: \(dest.address)"
        destStatusLabel.textColor = UIColor(red: 0.35, green: 0.92, blue: 0.68, alpha: 1.0)
        lockedStation = nil
        minDistanceToLockedKm = 9999.0
        speakVietnamese("Đã bật tìm tủ tiện đường về \(dest.label).")
        checkStationsNow(deepScan: true, autoOpenGMapsOnLock: false)
    }

    // MARK: - 6. ĐỊNH VỊ GPS VỆ TINH & NHẬN DIỆN TỚI TRẠM (<= 45m)
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

        // Kiểm tra khoảng cách tới tủ đang khóa để bật/tắt Chế Độ Đang Đứng Tại Trạm (#6)
        if let locked = lockedStation {
            let distMeters = haversineKm(userLat, userLng, locked.lat, locked.lng) * 1000.0
            if distMeters <= 45.0 && !isAtStation {
                isAtStation = true
                swappedAtStationCompleted = false
                pipIsWarningAlert = false
                pipStatusBannerText = "ĐANG ĐỨNG TẠI TRẠM ĐỔI PIN"
                speakVietnamese("Bạn đã tới sát trạm \(locked.name). Đã tạm ngắt tự động đổi tủ để bạn yên tâm rút pin.")
                DispatchQueue.main.async { [weak self] in
                    self?.refreshUI()
                }
            } else if distMeters >= 85.0 && isAtStation {
                isAtStation = false
                pipStatusBannerText = "ĐANG CANH PIN 3 GIÂY/LẦN"
                if let dest = activeDestination {
                    speakVietnamese("Bạn đã rời trạm đổi pin. Chạm thông báo hoặc nút trên màn hình để mở Google Maps đi thẳng tới \(dest.label).")
                }
                DispatchQueue.main.async { [weak self] in
                    self?.refreshUI()
                }
            }
        }

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
            checkStationsNow(deepScan: true, autoOpenGMapsOnLock: false)
        }
    }

    // MARK: - 7. CRON 3 GIÂY, PHÁT HIỆN TRANH TỦ (#2) & TỰ ĐỔI THEO HƯỚNG / ĐÍCH
    private func startCronTimer() {
        let timer = Timer(timeInterval: 3.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }
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

    private func computeMetricsForStation(
        userLat: Double,
        userLng: Double,
        sLat: Double,
        sLng: Double,
        roadKm: Double,
        bearingToStation: Double
    ) -> (effectiveKm: Double, isAhead: Bool, detourKm: Double?) {
        var isAhead = false
        var eff = roadKm
        var detourResult: Double? = nil

        if userCourse >= 0 {
            let diff = absAngleDiff(userCourse, bearingToStation)
            isAhead = diff <= 70.0
            if autoRerouteByDirection && diff > 120.0 {
                eff += 0.30
            }
        }

        if let dest = activeDestination {
            let directToDestKm = haversineKm(userLat, userLng, dest.lat, dest.lng) * 1.30
            let stationToDestKm = haversineKm(sLat, sLng, dest.lat, dest.lng) * 1.30
            let detour = max(0.0, Double(round(((roadKm + stationToDestKm) - directToDestKm) * 100) / 100))
            detourResult = detour
            eff = Double(round((roadKm + detour * 1.8) * 100) / 100)
        }

        return (eff, isAhead, detourResult)
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
        let persistentBlockedCodes = Set(loadBlockedEntries().map { $0.code })
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
                    let metrics = self.computeMetricsForStation(
                        userLat: lat,
                        userLng: lng,
                        sLat: sLat,
                        sLng: sLng,
                        roadKm: estRoad,
                        bearingToStation: brng
                    )

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
                            effectiveDistanceKm: metrics.effectiveKm,
                            durationMin: max(1, Int(round(estRoad * 2.5))),
                            bearingDeg: brng,
                            isAheadOfCourse: metrics.isAhead,
                            detourKm: metrics.detourKm,
                            drainedCount: 0
                        )
                    )
                }
                lock.unlock()
            }.resume()
        }

        group.notify(queue: .global(qos: .userInitiated)) { [weak self] in
            guard let self = self else { return }

            let allFetched = rawStations
            let qualified = rawStations.filter {
                $0.status == "Available" &&
                $0.avail >= minPins &&
                !persistentBlockedCodes.contains($0.code) &&
                !self.sessionSkippedCodes.contains($0.code) &&
                !self.simulatedEmptyCodes.contains($0.code)
            }.sorted { $0.straightKm < $1.straightKm }

            if useDeep && !qualified.isEmpty {
                self.enrichWithOSRM(lat: lat, lng: lng, stations: qualified) { finalSorted in
                    self.handleScanResult(allFetched: allFetched, qualified: finalSorted, autoOpenGMapsOnLock: autoOpenGMapsOnLock)
                }
            } else {
                var updated = qualified.map { st -> SwapStation in
                    var copy = st
                    let currentStraight = self.haversineKm(lat, lng, st.lat, st.lng)
                    copy.straightKm = currentStraight
                    if let prev = self.topStations.first(where: { $0.code == st.code }) {
                        let delta = currentStraight - prev.straightKm
                        copy.distanceKm = max(0.05, Double(round((prev.distanceKm + delta * 1.25) * 100) / 100))
                        copy.durationMin = prev.durationMin
                    } else if let locked = self.lockedStation, locked.code == st.code {
                        let delta = currentStraight - locked.straightKm
                        copy.distanceKm = max(0.05, Double(round((locked.distanceKm + delta * 1.25) * 100) / 100))
                        copy.durationMin = locked.durationMin
                    }
                    let brng = self.calcBearingDeg(lat, lng, copy.lat, copy.lng)
                    let metrics = self.computeMetricsForStation(
                        userLat: lat,
                        userLng: lng,
                        sLat: copy.lat,
                        sLng: copy.lng,
                        roadKm: copy.distanceKm,
                        bearingToStation: brng
                    )
                    copy.bearingDeg = brng
                    copy.effectiveDistanceKm = metrics.effectiveKm
                    copy.isAheadOfCourse = metrics.isAhead
                    copy.detourKm = metrics.detourKm
                    return copy
                }
                updated.sort {
                    if $0.effectiveDistanceKm != $1.effectiveDistanceKm { return $0.effectiveDistanceKm < $1.effectiveDistanceKm }
                    if $0.distanceKm != $1.distanceKm { return $0.distanceKm < $1.distanceKm }
                    return $0.avail > $1.avail
                }
                self.handleScanResult(allFetched: allFetched, qualified: updated, autoOpenGMapsOnLock: autoOpenGMapsOnLock)
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
        req.setValue("VFSwapRadar/4.0", forHTTPHeaderField: "User-Agent")
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
                        let metrics = self.computeMetricsForStation(
                            userLat: lat,
                            userLng: lng,
                            sLat: enriched[i].lat,
                            sLng: enriched[i].lng,
                            roadKm: km,
                            bearingToStation: enriched[i].bearingDeg
                        )
                        enriched[i].effectiveDistanceKm = metrics.effectiveKm
                        enriched[i].isAheadOfCourse = metrics.isAhead
                        enriched[i].detourKm = metrics.detourKm
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

    private func handleScanResult(allFetched: [SwapStation], qualified: [SwapStation], autoOpenGMapsOnLock: Bool) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            defer {
                self.isChecking = false
                self.renderHudFrameToPiP()
            }

            // 1. Tính toán biến động số pin của từng tủ sau mỗi 3 giây (Tính năng #2: Drain Rate Tracker)
            var updatedQualified: [SwapStation] = []
            for var st in qualified {
                if let prev = self.prevAvailByCode[st.code] {
                    if st.avail < prev {
                        let diff = prev - st.avail
                        self.drainedAmountByCode[st.code] = diff
                    } else if st.avail > prev {
                        self.drainedAmountByCode[st.code] = 0
                    }
                }
                self.prevAvailByCode[st.code] = st.avail
                st.drainedCount = self.drainedAmountByCode[st.code] ?? 0
                updatedQualified.append(st)
            }
            for raw in allFetched {
                self.prevAvailByCode[raw.code] = raw.avail
            }

            self.topStations = Array(updatedQualified.prefix(5))
            self.statusBadge.text = "🟢 CANH PIN 3s (#\(self.cronCount))"

            // 2. Nếu người dùng ĐANG ĐỨNG TẠI TRẠM ĐỔI PIN (<= 45m, Tính năng #6):
            // Tuyệt đối không báo động giả hoặc tự nhảy tủ khi chính tay người dùng đang rút pin!
            if self.isAtStation, let oldLocked = self.lockedStation {
                if let rawMatch = allFetched.first(where: { $0.code == oldLocked.code }) {
                    if rawMatch.avail < oldLocked.avail && !self.swappedAtStationCompleted {
                        self.swappedAtStationCompleted = true
                        if let dest = self.activeDestination {
                            self.speakVietnamese("Đã nhận diện bạn vừa rút pin tại trạm. Sau khi lắp pin xong, hãy bấm nút màu xanh trên màn hình để mở Google Maps đi thẳng tới \(dest.label)!")
                        }
                    }
                    self.lockedStation = SwapStation(
                        code: rawMatch.code,
                        name: rawMatch.name,
                        address: rawMatch.address,
                        commune: rawMatch.commune,
                        lat: rawMatch.lat,
                        lng: rawMatch.lng,
                        avail: rawMatch.avail,
                        total: rawMatch.total,
                        status: rawMatch.status,
                        straightKm: rawMatch.straightKm,
                        distanceKm: oldLocked.distanceKm,
                        effectiveDistanceKm: oldLocked.effectiveDistanceKm,
                        durationMin: oldLocked.durationMin,
                        bearingDeg: oldLocked.bearingDeg,
                        isAheadOfCourse: oldLocked.isAheadOfCourse,
                        detourKm: oldLocked.detourKm,
                        drainedCount: 0
                    )
                }
                self.refreshUI()
                return
            }

            let currentValid = self.lockedStation != nil
                ? updatedQualified.first(where: { $0.code == self.lockedStation!.code })
                : nil

            if let oldStation = self.lockedStation, currentValid == nil {
                // TRƯỜNG HỢP 1: TỦ ĐANG ĐI VỪA HẾT PIN (< minPins)
                if let nextBest = updatedQualified.first {
                    self.lockedStation = nextBest
                    self.minDistanceToLockedKm = nextBest.distanceKm
                    self.pipIsWarningAlert = true
                    self.pipStatusBannerText = "TỦ CŨ HẾT PIN -> ĐÃ ĐỔI TỦ MỚI!"
                    self.triggerRerouteAlert(
                        reasonTitle: "⚠️ TỦ ĐANG ĐI ĐÃ HẾT PIN! CHẠM ĐỂ ĐỔI HƯỚNG",
                        voiceMsgBg: "Cảnh báo! Tủ \(oldStation.name) vừa hết pin! Đã đổi sang tủ gần nhất là \(nextBest.name), còn \(nextBest.avail) pin đầy, cách \(nextBest.distanceKm) ki lô mét. Hãy chạm vào thông báo phía trên màn hình để mở lộ trình mới trên Google Maps!",
                        voiceMsgFg: "Tủ \(oldStation.name) đã hết pin. Tự động mở Google Maps sang tủ gần nhất là \(nextBest.name), còn \(nextBest.avail) pin đầy!",
                        newStation: nextBest
                    )
                } else {
                    self.lockedStation = nil
                    self.pipIsWarningAlert = true
                    self.pipStatusBannerText = "KHÔNG CÒN TỦ ĐỦ PIN QUANH ĐÂY!"
                    self.speakVietnamese("Cảnh báo! Không còn tủ nào đủ \(self.minPinsRequired) pin đầy quanh đây!")
                }
            } else if let validLocked = currentValid {
                let prevLockedAvail = self.lockedStation?.avail ?? validLocked.avail
                self.lockedStation = validLocked

                if validLocked.distanceKm < self.minDistanceToLockedKm {
                    self.minDistanceToLockedKm = validLocked.distanceKm
                }

                // KIỂM TRA TÍNH NĂNG #2: PHÁT HIỆN CÓ NGƯỜI VỪA RÚT BỚT PIN TẠI TỦ ĐANG ĐI (DRAIN RATE ALERT)
                if validLocked.avail < prevLockedAvail && validLocked.distanceKm >= 0.60 {
                    let dropped = prevLockedAvail - validLocked.avail
                    self.pipIsWarningAlert = true
                    self.pipStatusBannerText = "CẢNH BÁO: TỦ VỪA BỊ RÚT -\(dropped) PIN!"

                    let saferCandidate = updatedQualified.first(where: {
                        $0.code != validLocked.code &&
                        $0.avail >= validLocked.avail + 2 &&
                        $0.effectiveDistanceKm <= validLocked.effectiveDistanceKm + 0.75
                    })

                    if validLocked.avail == self.minPinsRequired,
                       validLocked.distanceKm >= 0.80,
                       let safer = saferCandidate {
                        // Nguy cơ cao bị người tiếp theo rút hết trước khi kịp chạy tới -> Tự động chuyển sang tủ an toàn hơn
                        self.lockedStation = safer
                        self.minDistanceToLockedKm = safer.distanceKm
                        self.triggerRerouteAlert(
                            reasonTitle: "🚨 TỦ ĐANG ĐI BỊ RÚT CÒN \(validLocked.avail) PIN! ĐỔI TỦ AN TOÀN HƠN",
                            voiceMsgBg: "Chú ý! Tủ \(validLocked.name) vừa bị người khác rút mất \(dropped) cục, chỉ còn \(validLocked.avail) cục cuối khi bạn còn cách \(validLocked.distanceKm) ki lô mét. Đã chuyển sang tủ an toàn hơn là \(safer.name) đang có \(safer.avail) pin đầy, cách \(safer.distanceKm) ki lô mét. Chạm thông báo để bẻ lái Google Maps!",
                            voiceMsgFg: "Tủ \(validLocked.name) vừa bị rút chỉ còn \(validLocked.avail) cục cuối. Tự động chuyển sang tủ an toàn hơn là \(safer.name) có \(safer.avail) pin đầy!",
                            newStation: safer
                        )
                        self.refreshUI()
                        return
                    } else {
                        self.speakVietnamese("Chú ý! Tủ \(validLocked.name) vừa có người rút mất \(dropped) cục, hiện còn \(validLocked.avail) cục pin đầy.")
                    }
                } else {
                    self.pipIsWarningAlert = false
                    self.pipStatusBannerText = self.activeDestination != nil
                        ? "TIỆN ĐƯỜNG VỀ: \(self.activeDestination!.label.uppercased())"
                        : "ĐANG KHÓA TỦ GẦN NHẤT"
                }

                // KIỂM TRA ĐỔI TỦ THEO HƯỚNG DI CHUYỂN / ĐI XA KHỎI TỦ CŨ
                let movedAwayKm = validLocked.distanceKm - self.minDistanceToLockedKm
                if self.autoRerouteByDirection,
                   let best = updatedQualified.first,
                   best.code != validLocked.code {
                    let isMovingAway = movedAwayKm >= 0.30 && best.effectiveDistanceKm <= validLocked.effectiveDistanceKm
                    let isMuchCloser = (validLocked.effectiveDistanceKm - best.effectiveDistanceKm) >= 0.25

                    if isMovingAway || isMuchCloser {
                        self.lockedStation = best
                        self.minDistanceToLockedKm = best.distanceKm
                        self.pipIsWarningAlert = true
                        self.pipStatusBannerText = "ĐÃ ĐỔI TỦ MỚI THUẬN ĐƯỜNG HƠN!"
                        let reasonText = isMovingAway
                            ? "Bạn đã đi xa khỏi tủ cũ \(String(format: "%.0f", movedAwayKm * 1000)) mét."
                            : "Phát hiện tủ mới thuận đường hơn."
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
            } else if self.lockedStation == nil, let first = updatedQualified.first {
                self.lockedStation = first
                self.minDistanceToLockedKm = first.distanceKm
                self.pipIsWarningAlert = false
                self.pipStatusBannerText = self.activeDestination != nil
                    ? "TIỆN ĐƯỜNG VỀ: \(self.activeDestination!.label.uppercased())"
                    : "ĐANG KHÓA TỦ GẦN NHẤT"
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

    // MARK: - 8. CẬP NHẬT GIAO DIỆN & ĐIỀU KHIỂN GOOGLE MAPS
    private func refreshUI() {
        if isAtStation {
            arrivalBannerButton.isHidden = false
            if let dest = activeDestination {
                arrivalBannerButton.setTitle("🏁 ĐANG ĐỨNG TẠI TRẠM (Đã tạm khóa báo động)\n👉 Chạm vào đây khi đổi pin xong để mở Google Maps đi tới [\(dest.label)]", for: .normal)
            } else {
                arrivalBannerButton.setTitle("🏁 ĐANG ĐỨNG TẠI TRẠM ĐỔI PIN (<= 45m)\nĐã tự động khóa cảnh báo hết pin để bạn yên tâm rút pin", for: .normal)
            }
        } else {
            arrivalBannerButton.isHidden = true
        }

        if let st = lockedStation {
            let charging = max(0, st.total - st.avail)
            let aheadTag = st.isAheadOfCourse ? " • ⬆️ Thuận hướng" : ""
            let detourTag = st.detourKm != nil ? String(format: " • 🛣️ Lệch đích: +%.2f km", st.detourKm!) : ""
            let drainTag = st.drainedCount > 0 ? "\n⚠️ CẢNH BÁO: Vừa có người rút bớt \(st.drainedCount) cục tại tủ này!" : ""

            targetNameLabel.text = st.name
            targetAddrLabel.text = "\(st.address)\(st.commune.isEmpty ? "" : " • " + st.commune) (Mã: \(st.code))\n🔋 Sẵn sàng rút: \(st.avail) cục (≥95%) • Đang sạc khóa khay: \(charging) cục\(drainTag)"
            targetPinBadge.text = "  \(st.avail)/\(st.total) PIN ĐẦY  "
            let durStr = st.durationMin != nil ? " (~\(st.durationMin!)p)" : ""
            targetDistLabel.text = "🛵 Cách \(st.distanceKm) km\(durStr)\(aheadTag)\(detourTag)"
        } else {
            targetNameLabel.text = "Không có tủ nào >= \(minPinsRequired) pin đầy"
            targetAddrLabel.text = "Hãy bấm nút '>= \(minPinsRequired) PIN' ở góc trên để hạ mức lọc pin hoặc gỡ bớt tủ trong Sổ Đen."
            targetPinBadge.text = "  0/0 PIN  "
            targetDistLabel.text = "Lộ trình thực tế: -- km"
        }

        top5Stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for (idx, st) in topStations.enumerated() {
            let isLocked = lockedStation?.code == st.code
            let charging = max(0, st.total - st.avail)
            let aheadBadge = st.isAheadOfCourse ? " ⬆️ Thuận hướng" : ""
            let detourBadge = st.detourKm != nil ? String(format: " • 🛣️ Lệch +%.2fkm", st.detourKm!) : ""
            let drainBadge = st.drainedCount > 0 ? " • ⚠️ Vừa tụt -\(st.drainedCount) pin" : ""

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
            let text = "\(prefix)\(st.distanceKm) km\(durStr)\(aheadBadge)\(detourBadge)  —  [\(st.avail)/\(st.total) PIN]\n\(st.name)\n\(st.address)\n🔋 Rút ngay: \(st.avail) cục (≥95%) • Đang sạc: \(charging) cục\(drainBadge)"
            lbl.text = text
            lbl.font = UIFont.systemFont(ofSize: 12.5, weight: .semibold)
            lbl.textColor = .white

            card.addSubview(lbl)
            NSLayoutConstraint.activate([
                lbl.topAnchor.constraint(equalTo: card.topAnchor, constant: 11),
                lbl.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -11),
                lbl.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 11),
                lbl.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -11)
            ])
            top5Stack.addArrangedSubview(card)
        }
    }

    private func openInGoogleMaps(station: SwapStation) {
        renderHudFrameToPiP()
        if let appUrl = station.googleMapsAppUrl, UIApplication.shared.canOpenURL(appUrl) {
            UIApplication.shared.open(appUrl, options: [:], completionHandler: nil)
        } else if let webUrl = station.googleMapsWebUrl {
            UIApplication.shared.open(webUrl, options: [:], completionHandler: nil)
        }
    }

    private func openDestinationInGoogleMaps(_ dest: SavedDestination) {
        if let appUrl = dest.googleMapsAppUrl, UIApplication.shared.canOpenURL(appUrl) {
            UIApplication.shared.open(appUrl, options: [:], completionHandler: nil)
        } else if let webUrl = dest.googleMapsWebUrl {
            UIApplication.shared.open(webUrl, options: [:], completionHandler: nil)
        }
    }

    @objc private func onTapArrivalBanner() {
        if let dest = activeDestination {
            isAtStation = false
            speakVietnamese("Đang mở Google Maps dẫn đường đi thẳng tới \(dest.label).")
            openDestinationInGoogleMaps(dest)
        } else {
            isAtStation = false
            refreshUI()
            speakVietnamese("Đã mở khóa lại chế độ tự động canh tủ.")
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
        isAtStation = false
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
        isAtStation = false
        minDistanceToLockedKm = 9999.0
        checkStationsNow(deepScan: true, autoOpenGMapsOnLock: false)
    }

    @objc private func onTapTestBgReroute() {
        guard let st = lockedStation else { return }
        speakVietnamese("Bắt đầu bài test. Mở Google Maps ngay bây giờ. Sau 6 giây ứng dụng sẽ giả lập tủ hết pin để bạn kiểm tra Cửa sổ nổi PiP và thông báo đổi hướng!")
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
        isAtStation = false
        minDistanceToLockedKm = chosen.distanceKm
        pipIsWarningAlert = false
        pipStatusBannerText = "ĐANG KHÓA TỦ ĐÃ CHỌN"
        refreshUI()
        renderHudFrameToPiP()
        speakVietnamese("Đã chọn tủ \(chosen.name), còn \(chosen.avail) pin đầy. Đang mở Google Maps.")
        openInGoogleMaps(station: chosen)
    }

    override var preferredStatusBarStyle: UIStatusBarStyle {
        return .lightContent
    }
}
