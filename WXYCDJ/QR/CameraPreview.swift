//
//  CameraPreview.swift
//  WXYCDJ
//
//  Created by Meira Volk on 8/7/26.
//

import SwiftUI
import AVFoundation

struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession
    let qrOutput: AVCaptureMetadataOutput
    
    func makeUIView(context: Context) -> UIView {
        let view = UIView(frame: .zero)
        view.backgroundColor = .black
        
        let previewLayer = AVCaptureVideoPreviewLayer(session: session)
        previewLayer.videoGravity = .resizeAspectFill
        previewLayer.frame = view.bounds
        view.layer.addSublayer(previewLayer)
        context.coordinator.previewLayer = previewLayer
        
        return view
        }
        
        func  updateUIView(_ uiView: UIView, context: Context) {
            if let previewLayer = context.coordinator.previewLayer {
                DispatchQueue.main.async {
                    previewLayer.frame = uiView.bounds
                }
            }
        }
        //communicates changes in view to rest of Swift UI interface
        func makeCoordinator() -> Coordinator {
            Coordinator()
        }
        
        class Coordinator {
            var previewLayer: AVCaptureVideoPreviewLayer?
        }
}
