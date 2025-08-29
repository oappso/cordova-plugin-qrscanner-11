import Foundation
import AVFoundation

@objc(QRScanner)
class QRScanner : CDVPlugin, AVCaptureMetadataOutputObjectsDelegate {
    
    class CameraView: UIView {
        var videoPreviewLayer:AVCaptureVideoPreviewLayer?
        
        func interfaceOrientationToVideoOrientation(_ orientation : UIInterfaceOrientation) -> AVCaptureVideoOrientation {
            switch (orientation) {
            case .portrait: return .portrait
            case .portraitUpsideDown: return .portraitUpsideDown
            case .landscapeLeft: return .landscapeLeft
            case .landscapeRight: return .landscapeRight
            default: return .portraitUpsideDown
            }
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            if let sublayers = self.layer.sublayers {
                for layer in sublayers {
                    layer.frame = self.bounds
                }
            }
            self.videoPreviewLayer?.connection?.videoOrientation =
                interfaceOrientationToVideoOrientation(UIApplication.shared.statusBarOrientation)
        }
        
        func addPreviewLayer(_ previewLayer:AVCaptureVideoPreviewLayer?) {
            previewLayer!.videoGravity = .resizeAspectFill
            previewLayer!.frame = self.bounds
            self.layer.addSublayer(previewLayer!)
            self.videoPreviewLayer = previewLayer
        }
        
        func removePreviewLayer() {
            if self.videoPreviewLayer != nil {
                self.videoPreviewLayer!.removeFromSuperlayer()
                self.videoPreviewLayer = nil
            }
        }
    }

    var cameraView: CameraView!
    var captureSession:AVCaptureSession?
    var captureVideoPreviewLayer:AVCaptureVideoPreviewLayer?
    var metaOutput: AVCaptureMetadataOutput?

    var currentCamera: Int = 0
    var frontCamera: AVCaptureDevice?
    var backCamera: AVCaptureDevice?

    var scanning: Bool = false
    var paused: Bool = false
    var nextScanningCommand: CDVInvokedUrlCommand?

    enum QRScannerError: Int32 {
        case unexpected_error = 0,
        camera_access_denied = 1,
        camera_access_restricted = 2,
        back_camera_unavailable = 3,
        front_camera_unavailable = 4,
        camera_unavailable = 5,
        scan_canceled = 6,
        light_unavailable = 7,
        open_settings_unavailable = 8
    }

    enum CaptureError: Error {
        case backCameraUnavailable
        case frontCameraUnavailable
        case couldNotCaptureInput(error: NSError)
    }

    enum LightError: Error {
        case torchUnavailable
    }

    override func pluginInitialize() {
        super.pluginInitialize()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(pageDidLoad),
            name: NSNotification.Name.CDVPageDidLoad,
            object: nil
        )
        self.cameraView = CameraView(frame: UIScreen.main.bounds)
        self.cameraView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    }

    func sendErrorCode(command: CDVInvokedUrlCommand, error: QRScannerError){
        let pluginResult = CDVPluginResult(status: CDVCommandStatus_ERROR, messageAs: error.rawValue)
        commandDelegate!.send(pluginResult, callbackId:command.callbackId)
    }

    // MARK: - Internal helpers

    private func resetSessionCompletely() {
        if let session = self.captureSession {
            session.stopRunning()
        }
        self.cameraView.removePreviewLayer()
        self.captureVideoPreviewLayer = nil
        self.metaOutput = nil
        self.captureSession = nil
        self.currentCamera = 0
        self.frontCamera = nil
        self.backCamera = nil
    }

    // Utility helper
    @objc func backgroundThread(delay: Double = 0.0, background: (() -> Void)? = nil, completion: (() -> Void)? = nil) {
        if #available(iOS 8.0, *) {
            DispatchQueue.global(qos: .userInitiated).async {
                background?()
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                    completion?()
                }
            }
        } else {
            background?()
            completion?()
        }
    }

    @objc func prepScanner(command: CDVInvokedUrlCommand) -> Bool {
        let status = AVCaptureDevice.authorizationStatus(for: .video)
        if status == .restricted {
            self.sendErrorCode(command: command, error: .camera_access_restricted)
            return false
        } else if status == .denied {
            self.sendErrorCode(command: command, error: .camera_access_denied)
            return false
        }

        // FIX #1: stale session cleanup (e.g., after app offload/restore)
        if let session = captureSession {
            if session.inputs.isEmpty || session.outputs.isEmpty {
                resetSessionCompletely()
            }
        }

        do {
            if (captureSession?.isRunning != true) {
                cameraView.backgroundColor = .clear
                if let webView = self.webView, let parent = webView.superview {
                    parent.insertSubview(cameraView, belowSubview: webView)
                }

                let discovery = AVCaptureDevice.DiscoverySession(
                    deviceTypes: [.builtInWideAngleCamera], // add more types if you want
                    mediaType: .video,
                    position: .unspecified
                )
                let cameras = discovery.devices

                // Populate front/back references
                for camera in cameras {
                    if camera.position == .front {
                        self.frontCamera = camera
                    } else if camera.position == .back {
                        self.backCamera = camera
                        do {
                            try camera.lockForConfiguration()
                            if camera.isFocusModeSupported(.continuousAutoFocus) {
                                camera.focusMode = .continuousAutoFocus
                            }
                            camera.unlockForConfiguration()
                        } catch {
                            // non-fatal: keep going
                        }
                    }
                }

                // FIX #2: no-device guard (avoid white overlay)
                if backCamera == nil && frontCamera == nil {
                    self.sendErrorCode(command: command, error: .camera_unavailable)
                    return false
                }

                // If no back camera, default to front
                if backCamera == nil { currentCamera = 1 }

                let input = try self.createCaptureDeviceInput()

                let session = AVCaptureSession()
                // (Optionally tune the preset here if needed)
                session.beginConfiguration()
                if session.canAddInput(input) { session.addInput(input) }

                let output = AVCaptureMetadataOutput()
                if session.canAddOutput(output) { session.addOutput(output) }
                output.setMetadataObjectsDelegate(self, queue: DispatchQueue.main)
                if output.availableMetadataObjectTypes.contains(.qr) {
                    output.metadataObjectTypes = [.qr]
                }

                session.commitConfiguration()

                captureSession = session
                captureVideoPreviewLayer = AVCaptureVideoPreviewLayer(session: session)
                cameraView.addPreviewLayer(captureVideoPreviewLayer)
                session.startRunning()
            }
            return true
        } catch CaptureError.backCameraUnavailable {
            self.sendErrorCode(command: command, error: .back_camera_unavailable)
        } catch CaptureError.frontCameraUnavailable {
            self.sendErrorCode(command: command, error: .front_camera_unavailable)
        } catch CaptureError.couldNotCaptureInput(_) {
            self.sendErrorCode(command: command, error: .camera_unavailable)
        } catch {
            self.sendErrorCode(command: command, error: .unexpected_error)
        }
        return false
    }

    @objc func createCaptureDeviceInput() throws -> AVCaptureDeviceInput {
        let captureDevice: AVCaptureDevice
        if currentCamera == 0 {
            guard let back = backCamera else { throw CaptureError.backCameraUnavailable }
            captureDevice = back
        } else {
            guard let front = frontCamera else { throw CaptureError.frontCameraUnavailable }
            captureDevice = front
        }
        do {
            return try AVCaptureDeviceInput(device: captureDevice)
        } catch let error as NSError {
            throw CaptureError.couldNotCaptureInput(error: error)
        }
    }

    @objc func makeOpaque(){
        self.webView?.isOpaque = true
        self.webView?.backgroundColor = .white
        self.webView?.scrollView.backgroundColor = .white
    }

    @objc func boolToNumberString(bool: Bool) -> String {
        return bool ? "1" : "0"
    }

    @objc func configureLight(command: CDVInvokedUrlCommand, state: Bool){
        var useMode = AVCaptureDevice.TorchMode.on
        if !state { useMode = .off }
        do {
            guard backCamera != nil,
                  backCamera!.hasTorch,
                  backCamera!.isTorchAvailable,
                  backCamera!.isTorchModeSupported(useMode) else {
                throw LightError.torchUnavailable
            }
            try backCamera!.lockForConfiguration()
            backCamera!.torchMode = useMode
            backCamera!.unlockForConfiguration()
            self.getStatus(command)
        } catch {
            self.sendErrorCode(command: command, error: .light_unavailable)
        }
    }

    // MARK: - AVCaptureMetadataOutputObjectsDelegate

    func metadataOutput(_ captureOutput: AVCaptureMetadataOutput, didOutput metadataObjects: [AVMetadataObject], from connection: AVCaptureConnection) {
        if metadataObjects.count == 0 || scanning == false {
            return
        }
        let found = metadataObjects[0] as! AVMetadataMachineReadableCodeObject
        if found.type == .qr, let value = found.stringValue {
            scanning = false
            let pluginResult = CDVPluginResult(status: CDVCommandStatus_OK, messageAs: value)
            commandDelegate!.send(pluginResult, callbackId: nextScanningCommand?.callbackId!)
            nextScanningCommand = nil
        }
    }

    @objc func pageDidLoad() {
        self.webView?.isOpaque = false
        self.webView?.backgroundColor = .clear
    }

    // ---- BEGIN EXTERNAL API ----

    @objc func prepare(_ command: CDVInvokedUrlCommand){
        let status = AVCaptureDevice.authorizationStatus(for: .video)
        if status == .notDetermined {
            AVCaptureDevice.requestAccess(for: .video, completionHandler: { (_: Bool) -> Void in
                self.backgroundThread(delay: 0, completion: {
                    if(self.prepScanner(command: command)){
                        self.getStatus(command)
                    }
                })
            })
        } else {
            if(self.prepScanner(command: command)){
                self.getStatus(command)
            }
        }
    }

    @objc func scan(_ command: CDVInvokedUrlCommand){
        if(self.prepScanner(command: command)){
            nextScanningCommand = command
            scanning = true
        }
    }

    @objc func cancelScan(_ command: CDVInvokedUrlCommand){
        if(self.prepScanner(command: command)){
            scanning = false
            if nextScanningCommand != nil {
                self.sendErrorCode(command: nextScanningCommand!, error: .scan_canceled)
            }
            self.getStatus(command)
        }
    }

    @objc func show(_ command: CDVInvokedUrlCommand) {
        self.webView?.isOpaque = false
        self.webView?.backgroundColor = .clear
        self.webView?.scrollView.backgroundColor = .clear
        self.getStatus(command)
    }

    @objc func hide(_ command: CDVInvokedUrlCommand) {
        self.makeOpaque()
        self.getStatus(command)
    }

    @objc func pausePreview(_ command: CDVInvokedUrlCommand) {
        if scanning {
            paused = true
            scanning = false
        }
        captureVideoPreviewLayer?.connection?.isEnabled = false
        self.getStatus(command)
    }

    @objc func resumePreview(_ command: CDVInvokedUrlCommand) {
        if paused {
            paused = false
            scanning = true
        }
        captureVideoPreviewLayer?.connection?.isEnabled = true
        self.getStatus(command)
    }

    // backCamera is 0, frontCamera is 1
    @objc func useCamera(_ command: CDVInvokedUrlCommand){
        let index = command.arguments[0] as! Int
        if(currentCamera != index){
            if(backCamera != nil && frontCamera != nil){
                currentCamera = index
                if(self.prepScanner(command: command)){
                    do {
                        captureSession!.beginConfiguration()
                        if let currentInput = captureSession?.inputs.first as? AVCaptureDeviceInput {
                            captureSession!.removeInput(currentInput)
                        }
                        let input = try self.createCaptureDeviceInput()
                        if captureSession!.canAddInput(input) {
                            captureSession!.addInput(input)
                        }
                        captureSession!.commitConfiguration()
                        self.getStatus(command)
                    } catch {
                        self.sendErrorCode(command: command, error: .unexpected_error)
                    }
                }
            } else {
                if(backCamera == nil){
                    self.sendErrorCode(command: command, error: .back_camera_unavailable)
                } else {
                    self.sendErrorCode(command: command, error: .front_camera_unavailable)
                }
            }
        } else {
            self.getStatus(command)
        }
    }

    @objc func enableLight(_ command: CDVInvokedUrlCommand) {
        if(self.prepScanner(command: command)){
            self.configureLight(command: command, state: true)
        }
    }

    @objc func disableLight(_ command: CDVInvokedUrlCommand) {
        if(self.prepScanner(command: command)){
            self.configureLight(command: command, state: false)
        }
    }

    @objc func destroy(_ command: CDVInvokedUrlCommand) {
        self.makeOpaque()
        if self.captureSession != nil {
            backgroundThread(delay: 0, background: {
                self.resetSessionCompletely()
            }, completion: {
                self.getStatus(command)
            })
        } else {
            self.getStatus(command)
        }
    }

    @objc func getStatus(_ command: CDVInvokedUrlCommand){
        let authorizationStatus = AVCaptureDevice.authorizationStatus(for: .video)

        let authorized = (authorizationStatus == .authorized)
        let denied = (authorizationStatus == .denied)
        let restricted = (authorizationStatus == .restricted)
        let prepared = (captureSession?.isRunning == true)
        let previewing = (captureVideoPreviewLayer?.connection?.isEnabled == true)
        let showing = (self.webView!.backgroundColor == .clear)
        let lightEnabled = (backCamera?.torchMode == .on)
        let canOpenSettings = true
        let canEnableLight = (backCamera?.hasTorch == true && backCamera?.isTorchAvailable == true && backCamera?.isTorchModeSupported(.on) == true)
        let canChangeCamera = (backCamera != nil && frontCamera != nil)

        let status = [
            "authorized": boolToNumberString(bool: authorized),
            "denied": boolToNumberString(bool: denied),
            "restricted": boolToNumberString(bool: restricted),
            "prepared": boolToNumberString(bool: prepared),
            "scanning": boolToNumberString(bool: scanning),
            "previewing": boolToNumberString(bool: previewing),
            "showing": boolToNumberString(bool: showing),
            "lightEnabled": boolToNumberString(bool: lightEnabled ?? false),
            "canOpenSettings": boolToNumberString(bool: canOpenSettings),
            "canEnableLight": boolToNumberString(bool: canEnableLight),
            "canChangeCamera": boolToNumberString(bool: canChangeCamera),
            "currentCamera": String(currentCamera)
        ]

        let pluginResult = CDVPluginResult(status: CDVCommandStatus_OK, messageAs: status)
        commandDelegate!.send(pluginResult, callbackId:command.callbackId)
    }

    @objc func openSettings(_ command: CDVInvokedUrlCommand) {
        if #available(iOS 10.0, *) {
            guard let settingsUrl = URL(string: UIApplication.openSettingsURLString) else { return }
            if UIApplication.shared.canOpenURL(settingsUrl) {
                UIApplication.shared.open(settingsUrl, completionHandler: { _ in
                    self.getStatus(command)
                })
            } else {
                self.sendErrorCode(command: command, error: .open_settings_unavailable)
            }
        } else {
            if #available(iOS 8.0, *) {
                UIApplication.shared.openURL(NSURL(string: UIApplication.openSettingsURLString)! as URL)
                self.getStatus(command)
            } else {
                self.sendErrorCode(command: command, error: .open_settings_unavailable)
            }
        }
    }
}
