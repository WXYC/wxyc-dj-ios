//
//  QRSignInFlowView.swift
//  WXYCDJ
//
//  Host for the QR-sign-in flow: presents the camera scanner full-screen,
//  drops the approval bottom sheet when a payload is parsed, shows the
//  prototype's role-gate denial and success/rejection cards. Translates
//  QRSignInViewModel state transitions into SwiftUI views.
//
//  Created by Jake on 6/28/26.
//  Copyright © 2026 WXYC. All rights reserved.
//

import SwiftUI
import WXYCAPI

struct QRSignInFlowView: View {
    @Environment(AppDependencies.self) private var deps
    @Environment(AuthService.self) private var auth
    @Environment(\.dismiss) private var dismiss

    @State private var viewModel: QRSignInViewModel?

    var body: some View {
        Group {
            if let viewModel {
                content(for: viewModel)
                    .onChange(of: viewModel.state) { _, newState in
                        // Auto-dismiss on the terminal user-affirmed states
                        // after a short pause so the success/rejected card
                        // is visible before the cover goes away.
                        switch newState {
                        case .succeeded, .rejected:
                            Task {
                                try? await Task.sleep(for: .seconds(1.6))
                                dismiss()
                            }
                        default:
                            break
                        }
                    }
            } else {
                ProgressView()
            }
        }
        .onAppear {
            if viewModel == nil {
                viewModel = QRSignInViewModel(
                    api: deps.api,
                    authService: auth,
                    biometrics: deps.biometrics
                )
            }
        }
    }

    @ViewBuilder
    private func content(for viewModel: QRSignInViewModel) -> some View {
        ZStack {
            QRScannerView(onScan: { payload in
                viewModel.handleScannedPayload(payload)
            })
            .ignoresSafeArea()

            // Cancel button + caption overlaid on the scanner.
            VStack {
                HStack {
                    Button("Cancel") { dismiss() }
                        .foregroundStyle(.white)
                        .font(.body)
                        .padding(.leading, 16)
                        .padding(.top, 8)
                    Spacer()
                }
                Spacer()
                scannerHint
                Spacer()
            }

            // Approval sheet, denial card, success/error states all render as
            // overlays over the still-running scanner.
            overlay(for: viewModel)
        }
        .preferredColorScheme(.dark)
    }

    private var scannerHint: some View {
        VStack(spacing: 6) {
            Text("Point at the QR on dj.wxyc.org")
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.9))
            Text("Camera scopes are limited to QR codes")
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.55))
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.black.opacity(0.45))
        )
    }

    @ViewBuilder
    private func overlay(for viewModel: QRSignInViewModel) -> some View {
        switch viewModel.state {
        case .scanning:
            EmptyView()
        case .approving, .authenticating, .verifying:
            VStack {
                Spacer()
                approvalCard(for: viewModel)
            }
            .transition(.move(edge: .bottom))
        case .roleGated(let role):
            VStack {
                Spacer()
                roleGatedCard(role: role)
            }
        case .rejected:
            terminalCard(systemImage: "xmark.circle.fill", color: .red,
                          title: "Sign-in rejected",
                          message: "The browser session was not started.")
        case .succeeded:
            terminalCard(systemImage: "checkmark.circle.fill", color: .green,
                          title: "Browser signed in",
                          message: "dj.wxyc.org is now signed in.")
        case .error(let message):
            VStack {
                Spacer()
                errorCard(message: message, dismissAction: { viewModel.dismiss() })
            }
        }
    }

    private func approvalCard(for viewModel: QRSignInViewModel) -> some View {
        let isBusy: Bool
        switch viewModel.state {
        case .authenticating, .verifying: isBusy = true
        default: isBusy = false
        }
        return VStack(spacing: 14) {
            Capsule().fill(.gray).frame(width: 36, height: 5).opacity(0.4)
            HStack(spacing: 12) {
                Image(systemName: "globe")
                    .font(.title2)
                    .foregroundStyle(.white)
                    .frame(width: 46, height: 46)
                    .background(
                        LinearGradient(colors: [.blue, .cyan], startPoint: .topLeading, endPoint: .bottomTrailing),
                        in: .rect(cornerRadius: 12)
                    )
                VStack(alignment: .leading, spacing: 2) {
                    Text("dj.wxyc.org").font(.headline)
                    Text("Authorize browser sign-in")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            Divider()
            VStack(alignment: .leading, spacing: 6) {
                Label("Read library & flowsheet", systemImage: "checkmark")
                Label("Log plays during your show", systemImage: "checkmark")
                Label("Edit your personal bin", systemImage: "checkmark")
            }
            .font(.callout)
            .foregroundStyle(.primary)
            .labelStyle(.titleAndIcon)
            VStack(spacing: 10) {
                Button {
                    Task { await viewModel.approve() }
                } label: {
                    HStack {
                        if isBusy { ProgressView().tint(.white) }
                        Text(isBusy ? "Approving…" : "Approve")
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(isBusy)

                Button(role: .destructive) {
                    Task { await viewModel.reject() }
                } label: {
                    Text("Reject").frame(maxWidth: .infinity)
                }
                .disabled(isBusy)
            }
        }
        .padding(20)
        .background(.background, in: .rect(cornerRadius: 18))
        .padding(.horizontal, 12)
        .padding(.bottom, 16)
    }

    private func roleGatedCard(role: String?) -> some View {
        VStack(spacing: 12) {
            Capsule().fill(.gray).frame(width: 36, height: 5).opacity(0.4)
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.largeTitle)
                .foregroundStyle(.red)
            Text("Sign-in requires DJ role").font(.headline)
            Text("Your account doesn't have permission to authorize browser sign-in on the studio computer. Music Directors, DJs, and station staff can.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            if let role, !role.isEmpty {
                Text("Signed in as: \(role)")
                    .font(.caption.monospaced())
                    .foregroundStyle(.tertiary)
            }
            Button("Close") { dismiss() }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .padding(.top, 4)
        }
        .padding(20)
        .background(.background, in: .rect(cornerRadius: 18))
        .padding(.horizontal, 12)
        .padding(.bottom, 16)
    }

    private func terminalCard(systemImage: String, color: Color, title: String, message: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: systemImage)
                .font(.system(size: 64))
                .foregroundStyle(color)
            Text(title).font(.title2.weight(.semibold))
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.background.opacity(0.92))
    }

    private func errorCard(message: String, dismissAction: @escaping () -> Void) -> some View {
        VStack(spacing: 10) {
            Capsule().fill(.gray).frame(width: 36, height: 5).opacity(0.4)
            Image(systemName: "exclamationmark.octagon.fill")
                .font(.largeTitle)
                .foregroundStyle(.orange)
            Text("Couldn't complete sign-in").font(.headline)
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            HStack {
                Button("Try Again", action: dismissAction)
                    .buttonStyle(.bordered)
                Button("Close") { dismiss() }
                    .buttonStyle(.borderedProminent)
            }
            .controlSize(.large)
        }
        .padding(20)
        .background(.background, in: .rect(cornerRadius: 18))
        .padding(.horizontal, 12)
        .padding(.bottom, 16)
    }
}
