//
//  CameraManager.swift
//  WXYCDJ
//
//  Created by Meira Volk on 8/7/26.
//

import AVFoundation
import SwiftUI
import Combine


@MainActor
@Observable
class CameraManager {
    var capturedCode: String?
    var isSessionRunning = false
    var authorizationStatus: AVAuthorizationStatus = .notDetermined
    
    private let cameraService = CameraService()
    /*
    init(capturedCode: String? = nil, isSessionRunning: Bool = false, authorizationStatus: AVAuthorizationStatus, session: AVCaptureSession) {
        self.capturedCode = capturedCode
        self.isSessionRunning = isSessionRunning
        self.authorizationStatus = authorizationStatus
        self.session = session
    }
     */
    
    var session: AVCaptureSession {
        cameraService.session
    }
    
    func checkAuthorization() {
        Task {
            let status = AVCaptureDevice.authorizationStatus(for: .video)
            switch status {
            case .authorized:
                self.authorizationStatus = .authorized
                self.startCamera()
                
            case .notDetermined:
                self.authorizationStatus = .notDetermined
                
                // Using the modern async version eliminates the closure and 'self' errors
                let granted = await AVCaptureDevice.requestAccess(for: .video)
                self.authorizationStatus = granted ? .authorized : .denied
                if granted {
                    self.startCamera()
                }
                
            case .denied, .restricted:
                self.authorizationStatus = .denied
            @unknown default:
                self.authorizationStatus = .denied
            }
        }
    }
    
    private func startCamera() {
        Task {
            // Create a stream to yield results. The continuation is inherently Sendable.
            let stream = AsyncStream<String> { continuation in
                Task {
                    // Pass a closure that ONLY captures the continuation, not 'self'
                    let success = await cameraService.setupSession { resultString in
                        continuation.yield(resultString)
                    }
                    
                    if success {
                        await cameraService.startSession()
                        // Ensure we update the Published property on the MainActor
                        await MainActor.run {
                            self.isSessionRunning = true
                        }
                    }
                }
            }
            
            // Loop over the stream safely on the MainActor
            for await code in stream {
                self.capturedCode = code
            }
        }
    }
}


actor CameraService {
    nonisolated(unsafe) let session = AVCaptureSession()
    var qrOutput = AVCaptureMetadataOutput()
    private let metadataObjectsQueue = DispatchQueue(label: "metadata objects queue")
    
    private var scannerDelegate: QRScannerDelegate?
    
    func setupSession(onResult: @escaping @Sendable (String) -> Void) -> Bool {
        session.beginConfiguration()
        session.sessionPreset = .high
        
        guard let camera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
              let input = try? AVCaptureDeviceInput(device: camera),
              session.canAddInput(input) else {
            session.commitConfiguration()
            return false
        }
        
        session.addInput(input)
        
        if session.canAddOutput(qrOutput) {
            session.addOutput(qrOutput)
            
            let delegate = QRScannerDelegate(onResult: onResult)
            self.scannerDelegate = delegate
            
            qrOutput.setMetadataObjectsDelegate(delegate, queue: metadataObjectsQueue)
            qrOutput.metadataObjectTypes = [.qr]
        }
        
        session.commitConfiguration()
        return true
    }
    
    func startSession() {
        if !session.isRunning {
            session.startRunning()
        }
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
        guard !metadataObjects.isEmpty,
              let metadataObj = metadataObjects[0] as? AVMetadataMachineReadableCodeObject,
              metadataObj.type == .qr,
              let stringValue = metadataObj.stringValue else {
            onResult("No QR code is detected")
            return
        }
        
        onResult(stringValue)
    }
}


/*
@Observable
class CameraManager: NSObject, ObservableObject, AVCaptureMetadataOutputObjectsDelegate{
    var capturedCode: String?
    var isSessionRunning = false
    var authorizationStatus: AVAuthorizationStatus = .notDetermined
    //AVFoundation Components
    let session = AVCaptureSession()
    private let metadataObjectsQueue = DispatchQueue(label: "metadata objects queue", attributes: [], target: nil)
    let qrOutput = AVCaptureMetadataOutput()
    
    private var currentInput: AVCaptureDeviceInput?
    
    private let sessionQueue = DispatchQueue(label: "com.customcamera.sesssionQueue")
    
    override init() {
        super.init()
    }
    func checkAuthorization () {
        switch AVCaptureDevice.authorizationStatus(for: .video){
        case .authorized:
            authorizationStatus = .authorized
            setupSession()
            
        case .notDetermined:
            authorizationStatus = .notDetermined
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                DispatchQueue.main.async {
                    self?.authorizationStatus = granted ? .authorized : .denied
                    if granted {
                        self?.setupSession()
                    }
                }
                
            }
        case .denied, .restricted:
            authorizationStatus = .denied
        @unknown default:
            authorizationStatus = .denied
        }
    }
    //Config AVSetup
    private func setupSession() {
        sessionQueue.async {
            [weak self] in
            guard let self = self else {return}
            
            //set session preset
            self.session.beginConfiguration()
            self.session.sessionPreset = .high
            
            // Set delegate and use the default dispatch queue to execute the call back
            //camera input
            
            guard let camera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back), let input = try? AVCaptureDeviceInput(device: camera) else {
                print("Failed to access camera")
                self.session.commitConfiguration()
                return
            }
            if self.session.canAddInput(input){
                self.session.addInput(input)
                self.currentInput = input
            }
            // add qr output
            
            if self.session.canAddOutput(self.qrOutput){
                self.session.addOutput(self.qrOutput)
                //May need to add more here from appcoda
                qrOutput.setMetadataObjectsDelegate(self, queue: metadataObjectsQueue)
                qrOutput.metadataObjectTypes = [AVMetadataObject.ObjectType.qr]
            }
            self.session.commitConfiguration()
            
            //start the session
            
            self.session.startRunning()
                       
            DispatchQueue.main.async {
                self.isSessionRunning = self.session.isRunning
            }
        }
    }
    
       nonisolated func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput metadataObjects: [AVMetadataObject], from connection: AVCaptureConnection){
        
        Task { @MainActor in
            // Checks metadataObjects array is not empty
            
            if metadataObjects.count == 0 {
                self.capturedCode = "No QR code is detected"
                return
            }
            // Safely unwrap the metadata object
            guard let metadataObj = metadataObjects[0] as? AVMetadataMachineReadableCodeObject else { return }
           
                if metadataObj.type == .qr {
                    // If a string value exists, update your @Published property
                    if let metadataString = metadataObj.stringValue {
                        self.capturedCode = metadataString
                    }
                }
            
        }
    }
}
*/
