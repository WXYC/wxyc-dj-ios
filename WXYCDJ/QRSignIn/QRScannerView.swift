//
//  QRScannerView.swift
//  WXYCDJ
//
//  UIViewControllerRepresentable wrapping AVCaptureSession + a metadata output
//  scoped to .qr. Delivers the first recognized payload on the MainActor; the
//  host view model is responsible for deduping (the AV delegate may fire
//  multiple times before the host unmounts the scanner).
//
//  Created by Jake on 6/28/26.
//  Copyright © 2026 WXYC. All rights reserved.
//

import AVFoundation
import OSLog
import SwiftUI
import UIKit

private let scannerLog = Logger(subsystem: "org.wxyc.dj", category: "qrscanner")

struct QRScannerView: UIViewControllerRepresentable {
    /// Called on the MainActor when a QR frame decodes. Idempotent at the
    /// representable layer: the host view model ignores duplicate payloads.
    let onScan: @MainActor (String) -> Void

    func makeUIViewController(context: Context) -> QRScannerViewController {
        let controller = QRScannerViewController()
        controller.onScan = onScan
        return controller
    }

    func updateUIViewController(_ uiViewController: QRScannerViewController, context: Context) {}
}

/// Hosts the AVCaptureSession. The Apple-recommended pattern: never touch
/// `startRunning`/`stopRunning` on the main thread (they can block for tens of
/// ms), so dispatch them onto a dedicated serial queue. Tested only on device —
/// the Simulator has no camera, so the view-model tests stub the scanner away
/// entirely.
final class QRScannerViewController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
    var onScan: (@MainActor (String) -> Void)?

    /// Owned and mutated only from `sessionQueue` (and the main thread during
    /// `viewDidLoad`'s setUp, before any other thread can see it). Not
    /// `Sendable` itself; `nonisolated(unsafe)` is the standard escape hatch for
    /// AV's not-yet-`Sendable` types when access is single-queue.
    private nonisolated(unsafe) let session = AVCaptureSession()
    private var previewLayer: AVCaptureVideoPreviewLayer?
    private let sessionQueue = DispatchQueue(label: "org.wxyc.dj.qrscanner.session")
    private let metadataQueue = DispatchQueue(label: "org.wxyc.dj.qrscanner.metadata")

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        configureCapture()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        sessionQueue.async { [session] in
            if !session.isRunning { session.startRunning() }
        }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        sessionQueue.async { [session] in
            if session.isRunning { session.stopRunning() }
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        previewLayer?.frame = view.bounds
    }

    private func configureCapture() {
        guard let device = AVCaptureDevice.default(for: .video) else {
            scannerLog.warning("No camera device available — scanner inert")
            return
        }
        do {
            let input = try AVCaptureDeviceInput(device: device)
            if session.canAddInput(input) {
                session.addInput(input)
            }
        } catch {
            scannerLog.error("Failed to attach camera: \(error.localizedDescription, privacy: .public)")
            return
        }

        let output = AVCaptureMetadataOutput()
        if session.canAddOutput(output) {
            session.addOutput(output)
            output.setMetadataObjectsDelegate(self, queue: metadataQueue)
            if output.availableMetadataObjectTypes.contains(.qr) {
                output.metadataObjectTypes = [.qr]
            }
        }

        let preview = AVCaptureVideoPreviewLayer(session: session)
        preview.videoGravity = .resizeAspectFill
        view.layer.addSublayer(preview)
        previewLayer = preview
    }

    nonisolated func metadataOutput(
        _ output: AVCaptureMetadataOutput,
        didOutput metadataObjects: [AVMetadataObject],
        from connection: AVCaptureConnection
    ) {
        for object in metadataObjects {
            guard let readable = object as? AVMetadataMachineReadableCodeObject,
                  readable.type == .qr,
                  let value = readable.stringValue
            else { continue }
            Task { @MainActor [weak self] in
                self?.onScan?(value)
            }
            return
        }
    }
}
