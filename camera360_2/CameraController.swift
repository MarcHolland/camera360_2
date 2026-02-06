//
//  CameraController.swift
//  camera360_2
//
//  Created by Marc Holland on 05.02.26.
//

import Foundation
import Combine
import Network
import UIKit
import INSCameraSDK
import INSCameraServiceSDK
import INSCoreMedia

@MainActor
final class CameraController: NSObject, ObservableObject {
    private enum ActiveCaptureKind {
        case video
        case timelapseVideo
    }

    enum CameraError: LocalizedError {
        case notConnected
        case commandFailed(String)
        case exportFailed(String)

        var errorDescription: String? {
            switch self {
            case .notConnected:
                return "Camera not connected."
            case let .commandFailed(message):
                return message
            case let .exportFailed(message):
                return message
            }
        }
    }

    enum ConnectionState: Equatable {
        case disconnected
        case connecting
        case connected(cameraName: String)
        case error(message: String)
    }

    @Published private(set) var connectionState: ConnectionState = .disconnected
    @Published private(set) var batteryPercentage: Int?
    @Published private(set) var storageFreeBytes: Int64?
    @Published private(set) var storageTotalBytes: Int64?

    @Published private(set) var isRecordingTimelapse = false
    @Published private(set) var recordingStartDate: Date?
    @Published private(set) var lastRecordedURI: String?

    @Published var downloadProgress: Double?
    @Published var exportProgress: Double?
    @Published var exportedVideoURL: URL?

    var isConnected: Bool {
        if case .connected = connectionState { return true }
        return false
    }

    private let cameraManager = INSCameraManager.socket()
    private var notificationTokens: [NSObjectProtocol] = []
    private var cameraStateObservation: NSKeyValueObservation?
    private var currentCameraObservation: NSKeyValueObservation?
    private var refreshTask: Task<Void, Never>?
    private var started = false

    private var activeDownloadTask: URLSessionTask?
    private var activeExporter: INSExportSimplify?
    private var activeExportDelegate: ExportDelegate?

    private var lastConnectionError: NSError?
    private var lastObservedCameraState: INSCameraState?
    private var lastObservedCameraName: String?

    private var permissionProbeBrowser: NWBrowser?
    private let permissionProbeQueue = DispatchQueue(label: "camera360_2.localnetwork.probe")

    private var activeCaptureKind: ActiveCaptureKind?
    private var didApplyCapturePrerequisites = false

    private var localNetworkSettingsPath: String {
        let appName =
            (Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String)

        if let appName, !appName.isEmpty {
            return "Settings → \(appName) → Local Network"
        }

        return "Settings → Local Network"
    }

#if DEBUG
    private var sdkLogDelegate: SDKLogDelegate?
#endif

    func start() {
        guard !started else { return }
        started = true

        connectionState = .connecting
        cameraManager.autoReconnect = true

#if DEBUG
        let logger = INSCameraSDKLogger.shared()
        logger.logLevel = .debug
        let delegate = SDKLogDelegate()
        logger.logDelegate = delegate
        sdkLogDelegate = delegate
#endif

        let center = NotificationCenter.default
        notificationTokens.append(
            center.addObserver(forName: .INSCameraDidConnect, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.handleConnected() }
            }
        )
        notificationTokens.append(
            center.addObserver(forName: .INSCameraDidDisconnect, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.handleDisconnected() }
            }
        )
        notificationTokens.append(
            center.addObserver(forName: .INSCameraConnectionError, object: nil, queue: .main) { [weak self] note in
                Task { @MainActor in self?.handleConnectionError(note) }
            }
        )
        notificationTokens.append(
            center.addObserver(forName: .INSCameraDidReconnect, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.handleConnected() }
            }
        )

        cameraStateObservation = cameraManager.observe(\.cameraState, options: [.initial, .new]) { [weak self] _, _ in
            Task { @MainActor in self?.updateConnectionStateFromManager() }
        }
        currentCameraObservation = cameraManager.observe(\.currentCamera, options: [.new]) { [weak self] _, _ in
            Task { @MainActor in self?.updateConnectionStateFromManager() }
        }

        startLocalNetworkPermissionProbe()
        cameraManager.setup()

        updateConnectionStateFromManager()

        refreshTask = Task { [weak self] in
            var tick = 0
            while !Task.isCancelled {
                if let strongSelf = self {
                    await strongSelf.updateConnectionStateFromManager()
                    if case .connected = strongSelf.connectionState, tick % 5 == 0 {
                        await strongSelf.refreshStatus()
                    }
                }
                tick += 1
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    func stop() {
        refreshTask?.cancel()
        refreshTask = nil

        for token in notificationTokens {
            NotificationCenter.default.removeObserver(token)
        }
        notificationTokens.removeAll()

        cameraStateObservation?.invalidate()
        cameraStateObservation = nil
        currentCameraObservation?.invalidate()
        currentCameraObservation = nil

        stopLocalNetworkPermissionProbe()
        cameraManager.shutdown()
        started = false
    }

    func reconnect() {
        guard started else { return }
        lastConnectionError = nil
        connectionState = .connecting
        cameraManager.shutdown()
        startLocalNetworkPermissionProbe()
        cameraManager.setup()
        updateConnectionStateFromManager()
    }

    func refreshStatus() async {
        guard case .connected = connectionState else { return }

        let optionTypes: [NSNumber] = [
            NSNumber(value: INSCameraOptionsType.batteryStatus.rawValue),
            NSNumber(value: INSCameraOptionsType.storageState.rawValue),
        ]

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            cameraManager.commandManager.getOptionsWithTypes(optionTypes) { [weak self] (error: Error?, options: INSCameraOptions?, _: [NSNumber]?) in
                Task { @MainActor in
                    defer { continuation.resume() }
                    guard let self else { return }
                    if let error {
                        self.connectionState = .error(message: error.localizedDescription)
                        return
                    }
                    guard let options else { return }

                    if let battery = options.batteryStatus {
                        let scale = max(1, battery.batteryScale)
                        let percent = Int((Double(battery.batteryLevel) / Double(scale)) * 100.0)
                        self.batteryPercentage = min(100, max(0, percent))
                    }

                    if let storage = options.storageStatus {
                        self.storageFreeBytes = storage.freeSpace
                        self.storageTotalBytes = storage.totalSpace
                    }
                }
            }
        }
    }

    func startTimelapseCaptureHighestQuality() async throws {
        guard isConnected else { throw CameraError.notConnected }
        exportedVideoURL = nil
        downloadProgress = nil
        exportProgress = nil

        await applyCapturePrerequisitesBestEffort()

        do {
            try await startVideoCapture()
            activeCaptureKind = .video
        } catch {
            // Fallback for older cameras / specific modes that only support timelapse capture APIs.
            let timelapseOptions = await setDefaultTimelapseOptionsBestEffort()
            try await startTimelapseVideoCapture(timelapseOptions: timelapseOptions)
            activeCaptureKind = .timelapseVideo
        }

        isRecordingTimelapse = true
        recordingStartDate = Date()
        lastRecordedURI = nil
    }

    private func applyCapturePrerequisitesBestEffort() async {
        guard isConnected else { return }
        guard !didApplyCapturePrerequisites else { return }
        didApplyCapturePrerequisites = true

        // Some newer models (X3/X4 family) require an authorization id to be set for full control.
        // This is a best-effort attempt; failures are ignored and surfaced by later commands.
        let options = INSCameraOptions()
        let sdkAuthId = INSConnectionUtils.authorizationId()
        options.authorizationId = sdkAuthId.isEmpty ? UIDevice.current.identifierForVendor?.uuidString : sdkAuthId
        options.videoSubMode = 0

        let types: [NSNumber] = [
            NSNumber(value: INSCameraOptionsType.authorizationId.rawValue),
            NSNumber(value: INSCameraOptionsType.videoSubMode.rawValue),
        ]

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            cameraManager.commandManager.setOptions(options, requestOptions: nil, forTypes: types) { _, _ in
                continuation.resume()
            }
        }

        // Keep-alive; the SDK expects heartbeats once the socket is connected.
        cameraManager.commandManager.sendHeartbeats(with: nil)
    }

    private func normalVideoCaptureOptions() -> INSCaptureOptions {
        let mode = INSCaptureMode()
        mode.mode = 1
        let options = INSCaptureOptions()
        options.mode = mode
        return options
    }

    private func currentCaptureStatus() async throws -> INSCameraCaptureStatus {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<INSCameraCaptureStatus, Error>) in
            cameraManager.commandManager.getCurrentCaptureStatus { error, status in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                guard let status else {
                    continuation.resume(throwing: CameraError.commandFailed("No capture status returned by camera."))
                    return
                }
                continuation.resume(returning: status)
            }
        }
    }

    private func phoneAuthorizationStatusBestEffort() async -> INSPhoneAuthorizationStatus? {
        await withCheckedContinuation { (continuation: CheckedContinuation<INSPhoneAuthorizationStatus?, Never>) in
            cameraManager.commandManager.checkAuthorization(with: nil, type: .bleConnect) { _, status in
                continuation.resume(returning: status)
            }
        }
    }

    private func validateCaptureStarted(kindDescription: String) async throws {
        // The SDK can sometimes report success before the camera UI actually transitions.
        try? await Task.sleep(for: .milliseconds(400))
        let first = try? await currentCaptureStatus()
        if let first, isCapturing(status: first) {
            return
        }

        try? await Task.sleep(for: .milliseconds(900))
        let status = try? await currentCaptureStatus()
        if let status, isCapturing(status: status) {
            return
        }

        let auth = await phoneAuthorizationStatusBestEffort()
        let authInfo: String
        if let auth {
            authInfo = " authorizationState=\(auth.state.rawValue) deviceId=\(auth.deviceId)"
        } else {
            authInfo = ""
        }

        if let status {
            throw CameraError.commandFailed("Camera did not start \(kindDescription). status.state=\(status.state.rawValue) status.captureSubmode=\(status.captureSubmode.rawValue).\(authInfo)")
        }
        throw CameraError.commandFailed("Camera did not start \(kindDescription).\(authInfo)")
    }

    private func isCapturing(status: INSCameraCaptureStatus) -> Bool {
        let state = status.state.rawValue
        // 0 = not capture, 8 = setting new value
        if state == 0 || state == 8 { return false }
        return true
    }

    private func startVideoCapture() async throws {
        let status = try? await currentCaptureStatus()
        if let status, isCapturing(status: status) {
            throw CameraError.commandFailed("Camera is already capturing. status.state=\(status.state.rawValue)")
        }

        let options = normalVideoCaptureOptions()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            cameraManager.commandManager.startCapture(with: options) { [weak self] error in
                Task { @MainActor in
                    guard let self else {
                        continuation.resume(throwing: CameraError.notConnected)
                        return
                    }
                    if let error {
                        continuation.resume(throwing: error)
                        return
                    }
                    continuation.resume()
                }
            }
        }

        try await validateCaptureStarted(kindDescription: "recording")
    }

    private func startTimelapseVideoCapture(timelapseOptions: INSTimelapseOptions) async throws {
        let startOptions = INSStartCaptureTimelapseOptions()
        startOptions.mode = .video
        startOptions.timelapseOptions = timelapseOptions

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            cameraManager.commandManager.startCaptureTimelapse(with: startOptions) { [weak self] error in
                Task { @MainActor in
                    guard let self else {
                        continuation.resume(throwing: CameraError.notConnected)
                        return
                    }
                    if let error {
                        continuation.resume(throwing: error)
                        return
                    }
                    continuation.resume()
                }
            }
        }
    }

    func stopTimelapseCapture() async throws -> String {
        guard isConnected else { throw CameraError.notConnected }

        defer {
            isRecordingTimelapse = false
            recordingStartDate = nil
        }

        switch activeCaptureKind {
        case .video:
            let uri = try await stopVideoCapture()
            lastRecordedURI = uri
            activeCaptureKind = nil
            return uri
        case .timelapseVideo:
            let uri = try await stopTimelapseVideoCapture()
            lastRecordedURI = uri
            activeCaptureKind = nil
            return uri
        case .none:
            // Best-effort: try normal stop first, then fall back to timelapse stop.
            do {
                let uri = try await stopVideoCapture()
                lastRecordedURI = uri
                return uri
            } catch {
                let uri = try await stopTimelapseVideoCapture()
                lastRecordedURI = uri
                return uri
            }
        }
    }

    private func stopVideoCapture() async throws -> String {
        let options = normalVideoCaptureOptions()
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
            cameraManager.commandManager.stopCapture(with: options) { [weak self] error, videoInfo in
                Task { @MainActor in
                    guard let self else {
                        continuation.resume(throwing: CameraError.notConnected)
                        return
                    }
                    if let error {
                        continuation.resume(throwing: error)
                        return
                    }

                    guard let videoInfo else {
                        continuation.resume(throwing: CameraError.commandFailed("No video info returned by camera."))
                        return
                    }

                    continuation.resume(returning: videoInfo.uri)
                }
            }
        }
    }

    private func stopTimelapseVideoCapture() async throws -> String {
        let stopOptions = INSStopCaptureTimelapseOptions()
        stopOptions.mode = .video

        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
            cameraManager.commandManager.stopCaptureTimelapse(with: stopOptions) { [weak self] error, videoInfo in
                Task { @MainActor in
                    guard let self else {
                        continuation.resume(throwing: CameraError.notConnected)
                        return
                    }

                    if let error {
                        continuation.resume(throwing: error)
                        return
                    }

                    guard let videoInfo else {
                        continuation.resume(throwing: CameraError.commandFailed("No video info returned by camera."))
                        return
                    }

                    continuation.resume(returning: videoInfo.uri)
                }
            }
        }
    }

    func downloadAndExportLastRecording(uri: String) async throws -> URL {
        guard isConnected else { throw CameraError.notConnected }

        let downloaded = try await downloadResource(uri: uri)
        let exported = try await exportToMP4(inputURL: downloaded)
        exportedVideoURL = exported
        return exported
    }

    private func downloadResource(uri: String) async throws -> URL {
        let cachesDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        let downloadsDir = cachesDir.appendingPathComponent("camera360-downloads", isDirectory: true)
        try? FileManager.default.createDirectory(at: downloadsDir, withIntermediateDirectories: true, attributes: nil)

        let name = uri.split(separator: "/").last.map(String.init) ?? "insta360-recording.insv"
        let localURL = downloadsDir.appendingPathComponent(name)

        if FileManager.default.fileExists(atPath: localURL.path) {
            try? FileManager.default.removeItem(at: localURL)
        }

        downloadProgress = 0
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL, Error>) in
            let task = cameraManager.commandManager.fetchResource(withURI: uri, toLocalFile: localURL, progress: { [weak self] progress in
                Task { @MainActor in
                    guard let self, let progress else { return }
                    self.downloadProgress = progress.fractionCompleted
                }
            }, completion: { [weak self] error in
                Task { @MainActor in
                    guard let self else {
                        continuation.resume(throwing: CameraError.notConnected)
                        return
                    }
                    self.activeDownloadTask = nil
                    self.downloadProgress = nil
                    if let error {
                        continuation.resume(throwing: error)
                        return
                    }
                    continuation.resume(returning: localURL)
                }
            })
            Task { @MainActor in
                self.activeDownloadTask = task
            }
            task.resume()
        }
    }

    private func exportToMP4(inputURL: URL) async throws -> URL {
        let cachesDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        let exportsDir = cachesDir.appendingPathComponent("camera360-exports", isDirectory: true)
        try? FileManager.default.createDirectory(at: exportsDir, withIntermediateDirectories: true, attributes: nil)

        let outputURL = exportsDir.appendingPathComponent("export-\(Int(Date().timeIntervalSince1970)).mp4")
        if FileManager.default.fileExists(atPath: outputURL.path) {
            try? FileManager.default.removeItem(at: outputURL)
        }

        exportProgress = 0

        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL, Error>) in
            let delegate = ExportDelegate()
            delegate.onProgress = { [weak self] progress in
                Task { @MainActor in self?.exportProgress = progress }
            }
            delegate.onComplete = { [weak self] error in
                Task { @MainActor in
                    guard let self else {
                        continuation.resume(throwing: CameraError.notConnected)
                        return
                    }

                    self.exportProgress = nil
                    self.activeExporter?.shutDown()
                    self.activeExporter = nil
                    self.activeExportDelegate = nil

                    if let error {
                        continuation.resume(throwing: error)
                        return
                    }
                    continuation.resume(returning: outputURL)
                }
            }

            let exporter = INSExportSimplify(urls: [inputURL], outputUrl: outputURL)
            exporter.exportManagedelegate = delegate
            exporter.width = 3840
            exporter.height = 1920
            exporter.bitrate = 60 * 1024 * 1024

            Task { @MainActor in
                self.activeExporter = exporter
                self.activeExportDelegate = delegate
            }

            if let error = exporter.start() {
                Task { @MainActor in
                    self.exportProgress = nil
                    self.activeExporter = nil
                    self.activeExportDelegate = nil
                }
                continuation.resume(throwing: error)
            }
        }
    }

    private func setDefaultTimelapseOptionsBestEffort() async -> INSTimelapseOptions {
        let options = INSTimelapseOptions()
        options.duration = 24 * 60 * 60
        options.lapseTime = 1000
        options.accelerateFequency = 10

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            cameraManager.commandManager.setTimelapseOptions(options, for: .video) { error in
                _ = error
                continuation.resume()
            }
        }

        return options
    }

    private func setHighestAvailableVideoResolutionForVideoRecording() async {
        // See `INSCameraPhotographyBasic.h` comments: 7 == NormalVideo.
        let mode = INSCameraFunctionMode(functionMode: 7)
        let optionTypes: [NSNumber] = [NSNumber(value: INSPhotographyOptionsType.videoResolution.rawValue)]

        let candidates: [INSVideoResolution] = [
            INSVideoResolution8192x4608x30,
            INSVideoResolution8000x6000x30,
            INSVideoResolution7680x4320x30,
            INSVideoResolution7680x3272x30,
            INSVideoResolution7680x3268x30,
            INSVideoResolution5472x3078x30,
            INSVideoResolution4096x2304x30,
            INSVideoResolution3840x2160x30,
            INSVideoResolution3840x1920x60,
            INSVideoResolution3840x1920x50,
            INSVideoResolution3840x1920x48,
            INSVideoResolution3840x1920x30,
            INSVideoResolution3072x1536x30,
            INSVideoResolution2880x2880x48,
            INSVideoResolution2880x2880x30,
            INSVideoResolution2560x1280x30,
            INSVideoResolution1920x960x30,
        ]

        for candidate in candidates {
            let setViaPhotographySucceeded = await trySetVideoResolutionViaPhotographyOptions(candidate, mode: mode, types: optionTypes)
            if setViaPhotographySucceeded {
                return
            }

            let setViaGlobalOptionsSucceeded = await trySetVideoResolutionViaGlobalOptions(candidate)
            if setViaGlobalOptionsSucceeded {
                return
            }
        }
    }

    private func trySetVideoResolutionViaPhotographyOptions(_ resolution: INSVideoResolution, mode: INSCameraFunctionMode, types: [NSNumber]) async -> Bool {
        let options = INSPhotographyOptions()
        options.videoResolution = resolution

        return await withCheckedContinuation { continuation in
            cameraManager.commandManager.setPhotographyOptions(options, for: mode, types: types) { error, _ in
                continuation.resume(returning: error == nil)
            }
        }
    }

    private func trySetVideoResolutionViaGlobalOptions(_ resolution: INSVideoResolution) async -> Bool {
        let options = INSCameraOptions()
        options.videoResolution = resolution
        let types: [NSNumber] = [NSNumber(value: INSCameraOptionsType.videoResolution.rawValue)]

        return await withCheckedContinuation { continuation in
            cameraManager.commandManager.setOptions(options, requestOptions: nil, forTypes: types) { error, _ in
                continuation.resume(returning: error == nil)
            }
        }
    }

    private func updateConnectionStateFromManager() {
        let state = cameraManager.cameraState
        let wasConnected = isConnected
        let cameraName = cameraManager.currentCamera?.name

        switch state {
        case .connected:
            lastConnectionError = nil
            stopLocalNetworkPermissionProbe()
            if let cameraName {
                connectionState = .connected(cameraName: cameraName)
            } else {
                connectionState = .connecting
            }
        case .found, .synchronized:
            lastConnectionError = nil
            connectionState = .connecting
            batteryPercentage = nil
            storageFreeBytes = nil
            storageTotalBytes = nil
            isRecordingTimelapse = false
            recordingStartDate = nil
        case .connectFailed:
            connectionState = .error(message: lastConnectionError.map(connectionErrorMessage(from:)) ?? "Failed to connect to camera.")
            batteryPercentage = nil
            storageFreeBytes = nil
            storageTotalBytes = nil
            isRecordingTimelapse = false
            recordingStartDate = nil
        case .noConnection:
            if let lastConnectionError, isPermissionOrNetworkBlockError(lastConnectionError) {
                connectionState = .error(message: connectionErrorMessage(from: lastConnectionError))
            } else {
                connectionState = .connecting
            }
            batteryPercentage = nil
            storageFreeBytes = nil
            storageTotalBytes = nil
            isRecordingTimelapse = false
            recordingStartDate = nil
        @unknown default:
            connectionState = .connecting
        }

#if DEBUG
        if lastObservedCameraState != state || lastObservedCameraName != cameraName {
            let camName = cameraName ?? "nil"
            print("[CameraController] cameraState=\(state.rawValue) currentCamera=\(camName)")
        }
#endif

        lastObservedCameraState = state
        lastObservedCameraName = cameraName

        if !wasConnected, isConnected {
            Task { await refreshStatus() }
        }
    }

    private func handleConnected() {
        updateConnectionStateFromManager()
        Task { await applyCapturePrerequisitesBestEffort() }
    }

    private func handleDisconnected() {
        updateConnectionStateFromManager()
        didApplyCapturePrerequisites = false
    }

    private func handleConnectionError(_ note: Notification) {
        let nsError =
            (note.userInfo?["error"] as? NSError)
            ?? note.userInfo?.values.compactMap({ $0 as? NSError }).first
            ?? (note.object as? NSError)

#if DEBUG
        print("[CameraController] Connection error notification userInfo=\(note.userInfo ?? [:])")
#endif

        if let nsError {
            lastConnectionError = nsError
            connectionState = .error(message: connectionErrorMessage(from: nsError))
        } else {
            connectionState = .error(message: "Failed to connect to camera.")
        }
    }

    private func connectionErrorMessage(from error: NSError) -> String {
        if error.domain == INSNWSocketErrorDomain {
            switch NWSocketErrorCode(rawValue: error.code) {
            case .localNetworkDenied:
                return "Local Network access is blocked. Enable it in \(localNetworkSettingsPath), then reopen the app."
            case .wifiDenied:
                return "Wi‑Fi access is blocked. Check Screen Time restrictions or MDM policies, then reopen the app."
            case .cellularDenied:
                return "Cellular access is blocked. Connect via Wi‑Fi to the camera and try again."
            case .wifiUnsatisfied:
                return "Wi‑Fi is not available. Join the Insta360 camera’s Wi‑Fi network and try again."
            case .connectionCloseByPeer:
                return "Connection closed by camera. Make sure the camera is powered on and try again."
            case .none:
                break
            }
        }

        return error.localizedDescription
    }

    private func isPermissionOrNetworkBlockError(_ error: NSError) -> Bool {
        guard error.domain == INSNWSocketErrorDomain else { return false }
        switch NWSocketErrorCode(rawValue: error.code) {
        case .wifiDenied, .cellularDenied, .wifiUnsatisfied, .localNetworkDenied:
            return true
        case .connectionCloseByPeer, .none:
            return false
        }
    }

    private enum NWSocketErrorCode: Int {
        case connectionCloseByPeer = 1
        case wifiDenied = 2
        case cellularDenied = 3
        case wifiUnsatisfied = 4
        case localNetworkDenied = 5
    }

    private func startLocalNetworkPermissionProbe() {
        guard permissionProbeBrowser == nil else { return }

        let params = NWParameters.tcp
        let browser = NWBrowser(for: .bonjour(type: "_lnp._tcp", domain: "local."), using: params)
        browser.stateUpdateHandler = { [weak self] newState in
            Task { @MainActor in
                guard let self else { return }
                switch newState {
                case .failed(let error):
                    if !self.isConnected, self.isLocalNetworkDenied(error) {
                        self.connectionState = .error(message: "Local Network permission is denied. Enable it in \(self.localNetworkSettingsPath), then reopen the app.")
                    }
                    self.stopLocalNetworkPermissionProbe()
                case .ready:
                    // Permission granted; keep probe briefly to help discovery, then stop.
                    Task { @MainActor in
                        try? await Task.sleep(for: .seconds(5))
                        self.stopLocalNetworkPermissionProbe()
                    }
                default:
                    break
                }
            }
        }
        browser.start(queue: permissionProbeQueue)
        permissionProbeBrowser = browser
    }

    private func stopLocalNetworkPermissionProbe() {
        permissionProbeBrowser?.cancel()
        permissionProbeBrowser = nil
    }

    private func isLocalNetworkDenied(_ error: NWError) -> Bool {
        switch error {
        case .posix(let posix):
            return posix == .EACCES
        case .dns(let dnsError):
            // kDNSServiceErr_PolicyDenied == -65570 (local network denied)
            return dnsError == -65570
        default:
            return false
        }
    }
}

@MainActor
private final class ExportDelegate: NSObject, INSRExporter2ManagerDelegate {
    var onProgress: ((Double) -> Void)?
    var onComplete: ((Error?) -> Void)?

    func exporter2Manager(_ manager: INSExporter2Manager, progress: Float) {
        onProgress?(Double(progress))
    }

    func exporter2Manager(_ manager: INSExporter2Manager, state: INSExporter2State, error: Error?) {
        switch state {
        case .complete:
            onComplete?(nil)
        case .cancel:
            onComplete?(NSError(domain: "camera360.export", code: -2, userInfo: [NSLocalizedDescriptionKey: "Export cancelled."]))
        case .disconnect:
            onComplete?(NSError(domain: "camera360.export", code: -3, userInfo: [NSLocalizedDescriptionKey: "Export disconnected."]))
        case .interrupt:
            onComplete?(NSError(domain: "camera360.export", code: -4, userInfo: [NSLocalizedDescriptionKey: "Export interrupted."]))
        case .initError, .error:
            onComplete?(error ?? NSError(domain: "camera360.export", code: -1, userInfo: [NSLocalizedDescriptionKey: "Export failed."]))
        @unknown default:
            onComplete?(error ?? NSError(domain: "camera360.export", code: -999, userInfo: [NSLocalizedDescriptionKey: "Export failed."]))
        }
    }

    func exporter2Manager(_ manager: INSExporter2Manager, correctOffset: String, errorNum: Int32, totalNum: Int32, clipIndex: Int32, type: String) {
        // Not used.
    }
}

#if DEBUG
private final class SDKLogDelegate: NSObject, INSCameraSDKLoggerProtocol {
    func logError(_ message: String, filePath: String, funcName: String, lineNum: Int) {
        print("[Insta360SDK][E] \(message) (\(funcName):\(lineNum))")
    }

    func logWarning(_ message: String, filePath: String, funcName: String, lineNum: Int) {
        print("[Insta360SDK][W] \(message) (\(funcName):\(lineNum))")
    }

    func logInfo(_ message: String, filePath: String, funcName: String, lineNum: Int) {
        print("[Insta360SDK][I] \(message) (\(funcName):\(lineNum))")
    }

    func logDebug(_ message: String, filePath: String, funcName: String, lineNum: Int) {
        print("[Insta360SDK][D] \(message) (\(funcName):\(lineNum))")
    }

    func logCrash(_ message: String, filePath: String, funcName: String, lineNum: Int) {
        print("[Insta360SDK][C] \(message) (\(funcName):\(lineNum))")
    }
}
#endif
