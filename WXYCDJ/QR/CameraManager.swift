//
//  CameraManager.swift
//  WXYCDJ
//
//  Manages AVCaptureSession lifecycle, camera authorization, and QR metadata extraction.
//
//  Created by Meira Volk on 8/7/26.
//  Copyright © 2026 WXYC. All rights reserved.
//

import AVFoundation
import SwiftUI

/// The scanner's observable state for `CameraView`: camera permission, whether
/// the capture session is running, and the most recent decoded QR string.
///
/// The `AVCaptureSession` itself is owned by `CameraService`, an actor, so the
/// blocking configure/start/stop calls run off the main actor.
@MainActor
@Observable
class CameraManager {
    /// The last QR payload decoded. `CameraView` observes this and hands the first
    /// non-empty value back to its presenter.
    var capturedCode: String?
    var isSessionRunning = false
    /// Mirrors `AVCaptureDevice.authorizationStatus(for: .video)`; `.restricted`
    /// and unknown future values are folded into `.denied`.
    var authorizationStatus: AVAuthorizationStatus = .notDetermined
    
    private let cameraService = CameraService()
    
    var session: AVCaptureSession {
        cameraService.session
    }
    
    /// Reads camera permission, prompting on first use, and starts the camera if
    /// it is (or becomes) granted. The prompt text is `NSCameraUsageDescription`,
    /// declared in `project.yml` — `WXYCDJ/Info.plist` is generated, so a key
    /// added only there would be wiped by the next `xcodegen generate`, and iOS
    /// terminates an app that opens the camera without one.
    func checkAuthorization() {
        let status = AVCaptureDevice.authorizationStatus(for: .video)
        self.authorizationStatus = status
        
        switch status {
        case .authorized:
            self.startCamera()
            
        case .notDetermined:
            Task {
                let granted = await AVCaptureDevice.requestAccess(for: .video)
                self.authorizationStatus = granted ? .authorized : .denied
                if granted {
                    self.startCamera()
                }
            }
            
        case .denied, .restricted:
            self.authorizationStatus = .denied
            
        @unknown default:
            self.authorizationStatus = .denied
        }
    }
    
    func startCamera() {
        Task {
            let success = await cameraService.setupAndStartSession { [weak self] resultString in
                Task { @MainActor in
                    self?.capturedCode = resultString
                }
            }
            if success {
                self.isSessionRunning = true
            }
        }
    }
    
    func stopCamera() {
        Task {
            await cameraService.stopSession()
            self.isSessionRunning = false
        }
    }
}

/// Owns the `AVCaptureSession`: picks the back camera, attaches a QR-only
/// metadata output, and starts/stops the session. An actor so
/// `startRunning()`/`stopRunning()` — blocking calls Apple says not to make on the
/// main thread — never run there. Configuration happens once; later starts only
/// re-attach a fresh delegate.
actor CameraService {
    nonisolated(unsafe) let session = AVCaptureSession()
    private let qrOutput = AVCaptureMetadataOutput()
    private let metadataObjectsQueue = DispatchQueue(label: "org.wxyc.dj.metadataObjectsQueue")
    private var scannerDelegate: QRScannerDelegate?
    private var isConfigured = false
    
    func setupAndStartSession(onResult: @escaping @Sendable (String) -> Void) -> Bool {
        let delegate = QRScannerDelegate(onResult: onResult)
        self.scannerDelegate = delegate
        
        if !isConfigured {
            session.beginConfiguration()
            session.sessionPreset = .high
            
            let device: AVCaptureDevice? = {
                if let backCamera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) {
                    return backCamera
                }
                return AVCaptureDevice.DiscoverySession(
                    deviceTypes: [.builtInTripleCamera, .builtInDualWideCamera, .builtInDualCamera, .builtInWideAngleCamera],
                    mediaType: .video,
                    position: .back
                ).devices.first
            }()
            
            guard let camera = device,
                  let input = try? AVCaptureDeviceInput(device: camera),
                  session.canAddInput(input) else {
                session.commitConfiguration()
                return false
            }
            
            session.addInput(input)
            
            if session.canAddOutput(qrOutput) {
                session.addOutput(qrOutput)
                qrOutput.setMetadataObjectsDelegate(delegate, queue: metadataObjectsQueue)
                if qrOutput.availableMetadataObjectTypes.contains(.qr) {
                    qrOutput.metadataObjectTypes = [.qr]
                }
            }
            
            session.commitConfiguration()
            isConfigured = true
        } else {
            qrOutput.setMetadataObjectsDelegate(delegate, queue: metadataObjectsQueue)
            if qrOutput.availableMetadataObjectTypes.contains(.qr) {
                qrOutput.metadataObjectTypes = [.qr]
            }
        }
        
        if !session.isRunning {
            session.startRunning()
        }
        return true
    }
    
    func stopSession() {
        if session.isRunning {
            session.stopRunning()
        }
    }
}

/// Receives metadata callbacks on `CameraService`'s private queue and forwards each
/// non-empty QR string to `onResult`. `@unchecked Sendable` is sound because its
/// only stored property is an immutable `@Sendable` closure.
final class QRScannerDelegate: NSObject, AVCaptureMetadataOutputObjectsDelegate, @unchecked Sendable {
    private let onResult: @Sendable (String) -> Void
    
    init(onResult: @escaping @Sendable (String) -> Void) {
        self.onResult = onResult
        super.init()
    }
    
    func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput metadataObjects: [AVMetadataObject], from connection: AVCaptureConnection) {
        guard let metadataObj = metadataObjects.first as? AVMetadataMachineReadableCodeObject,
              metadataObj.type == .qr,
              let stringValue = metadataObj.stringValue,
              !stringValue.isEmpty else {
            return
        }
        
        onResult(stringValue)
    }
}



