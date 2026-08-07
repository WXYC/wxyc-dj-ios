//
//  CameraManager.swift
//  WXYCDJ
//
//  Created by Meira Volk on 7/17/26.
//
import AVFoundation
import SwiftUI
import Combine

@MainActor
class CameraManager: NSObject, ObservableObject, @MainActor AVCaptureMetadataOutputObjectsDelegate{
    @Published var capturedCode: String?
    @Published var isSessionRunning = false
    @Published var authorizationStatus: AVAuthorizationStatus = .notDetermined
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
        Task { @MainActor
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
    
       func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput metadataObjects: [AVMetadataObject], from connection: AVCaptureConnection){
           if metadataObjects.count == 0 {
               self.capturedCode = "No QR code is detected"
               return
           }

        Task { @MainActor in
            // Checks metadataObjects array is not empty
            
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

