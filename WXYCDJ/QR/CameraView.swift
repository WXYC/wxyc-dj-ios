//
//  CameraView.swift
//  WXYCDJ
//
//  Renders the live camera viewfinder and reticle overlay for scanning QR codes.
//
//  Created by Meira Volk on 8/7/26.
//  Copyright © 2026 WXYC. All rights reserved.
//

import SwiftUI
import AVFoundation

struct CameraView: View {
    @Binding var showScanner: Bool
    @Binding var scannedCode: String?
    @State private var cameraManager = CameraManager()
    let onDismiss: () -> Void
    
    var body: some View {
        ZStack {
            // Camera Preview configured to fill the entire sheet
            if cameraManager.authorizationStatus == .authorized {
                CameraPreview(session: cameraManager.session)
                    .ignoresSafeArea()
            } else {
                fallbackView
            }
            
            // Scanner UI Overlay
            if cameraManager.authorizationStatus == .authorized {
                VStack {
                    // Top Bar: Cancel Button
                    HStack {
                        Button("Cancel") {
                            cameraManager.stopCamera()
                            onDismiss()
                        }
                        .font(.headline)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 24)
                        .padding(.top, 24)
                        
                        Spacer()
                    }
                    
                    Spacer()
                    
                    // Center: QR Outline
                    ScannerReticle()
                        .frame(width: 260, height: 260)
                    
                    // Bottom: Instructions
                    VStack(spacing: 8) {
                        Text("Point at the QR on **dj.wxyc.org**")
                            .font(.system(size: 16, weight: .regular))
                            .foregroundStyle(.white)
                    }
                    .padding(.top, 40)
                    
                    Spacer()
                    Spacer()
                }
            }
        }
        .onAppear {
            cameraManager.checkAuthorization()
        }
        .onDisappear {
            cameraManager.stopCamera()
        }
        .onChange(of: cameraManager.capturedCode) { _, newCode in
            if let metadataString = newCode, !metadataString.isEmpty, metadataString != "No QR code is detected" {
                scannedCode = metadataString
                cameraManager.stopCamera()
                onDismiss()
            }
        }
    }
    
    // Extracted fallback view for permission handling
    @ViewBuilder
    private var fallbackView: some View {
        VStack {
            Image(systemName: "camera.fill")
                .font(.largeTitle)
                .foregroundStyle(.gray)
            Text("Camera Access Required")
                .font(.title2)
                .foregroundStyle(.gray)
                .padding(.top, 8)
            
            if cameraManager.authorizationStatus == .denied {
                Text("Please enable camera in settings")
                    .foregroundStyle(.gray)
                    .padding(.top, 16)
                
                Button("Open Settings") {
                    if let settingsURL = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(settingsURL)
                    }
                }
                .buttonStyle(.borderedProminent)
                .padding(.top, 8)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black)
    }
}

// Custom Shape for the rounded QR corners
struct ScannerReticle: View {
    var body: some View {
        Path { path in
            let size: CGFloat = 260
            let length: CGFloat = 40
            let radius: CGFloat = 16
            
            // Top Left
            path.move(to: CGPoint(x: 0, y: length))
            path.addArc(tangent1End: CGPoint(x: 0, y: 0), tangent2End: CGPoint(x: length, y: 0), radius: radius)
            path.addLine(to: CGPoint(x: length, y: 0))
            
            // Top Right
            path.move(to: CGPoint(x: size - length, y: 0))
            path.addArc(tangent1End: CGPoint(x: size, y: 0), tangent2End: CGPoint(x: size, y: length), radius: radius)
            path.addLine(to: CGPoint(x: size, y: length))
            
            // Bottom Right
            path.move(to: CGPoint(x: size, y: size - length))
            path.addArc(tangent1End: CGPoint(x: size, y: size), tangent2End: CGPoint(x: size - length, y: size), radius: radius)
            path.addLine(to: CGPoint(x: size - length, y: size))
            
            // Bottom Left
            path.move(to: CGPoint(x: length, y: size))
            path.addArc(tangent1End: CGPoint(x: 0, y: size), tangent2End: CGPoint(x: 0, y: size - length), radius: radius)
            path.addLine(to: CGPoint(x: 0, y: size - length))
        }
        .stroke(Color.white, style: StrokeStyle(lineWidth: 5, lineCap: .round))
        .shadow(color: .black.opacity(0.5), radius: 4, x: 0, y: 2)
    }
}

