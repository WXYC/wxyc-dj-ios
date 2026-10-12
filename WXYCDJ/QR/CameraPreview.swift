//
//  CameraPreview.swift
//  WXYCDJ
//
//  UIViewRepresentable wrapper for AVCaptureVideoPreviewLayer.
//
//  Created by Meira Volk on 8/7/26.
//  Copyright © 2026 WXYC. All rights reserved.
//

import SwiftUI
import AVFoundation

/// Hosts an `AVCaptureVideoPreviewLayer` in SwiftUI. UIKit is unavoidable here:
/// SwiftUI has no native camera-preview view.
struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession
    
    func makeUIView(context: Context) -> VideoPreviewUIView {
        let view = VideoPreviewUIView()
        view.backgroundColor = .black
        view.videoPreviewLayer.session = session
        view.videoPreviewLayer.videoGravity = .resizeAspectFill
        return view
    }
    
    func updateUIView(_ uiView: VideoPreviewUIView, context: Context) {
        if uiView.videoPreviewLayer.session != session {
            uiView.videoPreviewLayer.session = session
        }
    }
}

/// A `UIView` whose backing layer *is* the preview layer, so it resizes with the
/// view without manual frame updates.
final class VideoPreviewUIView: UIView {
    override class var layerClass: AnyClass {
        AVCaptureVideoPreviewLayer.self
    }
    
    var videoPreviewLayer: AVCaptureVideoPreviewLayer {
        layer as! AVCaptureVideoPreviewLayer
    }
}

