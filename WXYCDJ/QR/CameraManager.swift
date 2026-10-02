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

@MainActor
@Observable
class CameraManager {
    var capturedCode: String?
    var isSessionRunning = false
    var authorizationStatus: AVAuthorizationStatus = .notDetermined
    
    private let cameraService = CameraService()
    
    var session: AVCaptureSession {
        cameraService.session
    }
    
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



