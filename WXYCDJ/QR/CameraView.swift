//
//  CameraView.swift
//  WXYCDJ
//
//  Created by Meira Volk on 8/7/26.
//

import SwiftUI
import AVFoundation
import AVKit //for photo quality I think; don't think is used

struct CameraView: View {

    @Binding var showScanner: Bool
    @Binding var qrCode: String
    @State private var cameraManager = CameraManager()
    let onDismiss: () -> Void
    
    var body: some View {
        //ZStack for layering preview w/ controls
        ZStack {
            if cameraManager.authorizationStatus == .authorized {
                CameraPreview(session: cameraManager.session, qrOutput: cameraManager.qrOutput) .ignoresSafeArea()
            } else {
                VStack{
                    Image(systemName: "camera.fill")
                        .font(.largeTitle)
                        .foregroundStyle(.gray)
                    Text("Camera Access Required")
                        .font(.largeTitle)
                        .foregroundStyle(.gray)
                    
                    if cameraManager.authorizationStatus == .denied{
                        Text("please enable camera in settings")
                        
                        Button("Open Settings"){
                            if let settingsURL = URL(string:
                                                        UIApplication.openSettingsURLString){
                                UIApplication.shared.open(settingsURL)
                            }
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
            }
            }
        .onAppear {
            cameraManager.checkAuthorization()
        }
        .onChange(of: cameraManager.capturedCode) { oldCode, newCode in
            if let metadataString = cameraManager.capturedCode {
                if metadataString != "No QR code is detected" {
                    qrCode = metadataString
                    onDismiss()
                }
            }
        }
        .padding()
        }
        
        
     
}
