//
//  DeviceAuthView.swift
//  WXYCDJ
//
//  Renders the half-screen QR device authorization modal screen for approving or rejecting browser sign-ins.
//
//  Created by Meira Volk on 08/12/26.
//  Copyright © 2026 WXYC. All rights reserved.
//

import SwiftUI
import WXYCAPI

/// The half-height sheet a DJ sees after scanning a dj.wxyc.org sign-in QR:
/// a spinner while the code is verified, then the request card with
/// Approve / Reject, or an error card, or — after a successful approve — the
/// success card.
///
/// Presented by `SearchView` once `CameraView` hands back a scan. Which card
/// shows is decided by the pure `DeviceAuthViewModel.sheetContent(...)`; this
/// view only renders it. Approve keeps the sheet up and reports failure inline
/// (the DJ may need to act on it); Reject dismisses and reports through
/// `onDismissWithToast`.
struct DeviceAuthView: View {
    @Environment(AppDependencies.self) private var deps
    @Environment(AuthService.self) private var auth
    @Environment(\.dismiss) private var dismiss
    
    @State private var viewModel: DeviceAuthViewModel?
    /// The raw scan from `CameraView`; parsed once, in `onAppear`.
    @Binding var scannedCode: String?
    /// The parsed `user_code`, held for Approve/Reject. `nil` when the scan
    /// couldn't be parsed.
    @State private var userCode: String?
    /// Fallback copy for the error card when there is no `user_code` and the view
    /// model hasn't produced its own message yet.
    @State var message: String = "Unknown code"
    
    /// Called after Reject, just before the sheet dismisses, with the copy to show
    /// and a toast kind (`"red"`, `"amber"`, or `"ok"`) the presenter maps to a color.
    var onDismissWithToast: ((_ toastText: String, _ toastKind: String) -> Void)? = nil
    
    /// Seconds since verify confirmed the code, shown as "Requested Ns ago";
    /// refreshed by `timer` from `DeviceAuthViewModel.requestDate`.
    @State private var elapsedSeconds: Int = 4
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        Group {
            if let viewModel {
                switch DeviceAuthViewModel.sheetContent(
                    workflowState: viewModel.workflowState,
                    userCode: userCode,
                    approveError: viewModel.approveError,
                    fallbackMessage: message
                ) {
                case .approved(let toastMessage):
                    DeviceAuthSuccessView(
                       // username: viewModel.username,
                        toastMessage: toastMessage
                    )
                case .error(let errorText):
                    DeviceAuthErrorView(message: errorText)
                case .verifying:
                    ProgressView()
                case .request(let code, let approveError):
                    content(for: viewModel, with: code, approveError: approveError)
                }
            } else {
                ProgressView()
            }
        }
        .presentationDetents([.fraction(0.68)])
        .presentationDragIndicator(.visible)
        .onAppear {
            if viewModel == nil {
                let newViewModel = DeviceAuthViewModel(auth: auth)
                //Inserts user data (username & role into approve / deny screen)
                //TO-DO: remove any role variables (don't want to display to users)
                /*
                if case .signedIn(let payload) = auth.state {
                    let handle = payload?.email?.components(separatedBy: "@").first ?? payload?.sub
                    newViewModel.updateUserProfile(role: payload?.role, username: handle)
                }
                */
                viewModel = newViewModel
                userCode = newViewModel.processCode(scannedCode: scannedCode)
            }
        }
        .onReceive(timer) { _ in
            if let vm = viewModel {
                elapsedSeconds = max(1, Int(Date().timeIntervalSince(vm.requestDate)))
            }
        }
    }
        
    @ViewBuilder
    private func content(for viewModel: DeviceAuthViewModel, with userCode: String, approveError: String?) -> some View {
        VStack(spacing: 16) {
            // Top Header Section: Icon, Domain, and Context Metadata
            HStack(spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(LinearGradient(colors: [Color.blue, Color(red: 0.35, green: 0.78, blue: 0.98)], startPoint: .topLeading, endPoint: .bottomTrailing))
                        .frame(width: 48, height: 48)
                    
                    Image(systemName: "globe")
                        .font(.system(size: 24))
                        .foregroundStyle(.white)
                }
                
                VStack(alignment: .leading, spacing: 2) {
                    //ADD hostDomain later if there's a way to access that information
                   /*
                    Text(viewModel.hostDomain)
                        .font(.system(size: 19, weight: .bold))
                        .foregroundStyle(.primary)
                    */
                    //TO-DO: Add browser info, such as Macbook pro · Firefox"
                    Text("Requested \(elapsedSeconds)s ago")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                
                Spacer()
            }
            .padding(.top, 16)
            
            Divider()
            
            /*
            
            if viewModel.isMember {
                // Member Denial Card (Flow 3)
                VStack(spacing: 10) {
                    ZStack {
                        Circle()
                            .fill(Color.red.opacity(0.12))
                            .frame(width: 52, height: 52)
                        
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 24))
                            .foregroundStyle(.red)
                    }
                    
                    Text("Sign-in requires DJ role")
                        .font(.system(size: 17, weight: .bold))
                        .foregroundStyle(.primary)
                    
                    Text("Your account is a Member. Only DJs, Music Directors, and station staff can authorize browser sign-in on the control-room computer.")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 8)
                }
                .padding(14)
                .background(Color(uiColor: .systemBackground))
                .clipShape(.rect(cornerRadius: 14))
            }
            
            */
            //TO-DO:
            // User Profile Section
            /*
            HStack(spacing: 14) {
                ZStack {
                    Circle()
                        .fill(viewModel.isMember ? Color.gray : Color.blue)
                        .frame(width: 42, height: 42)
                    
                    //user data - TO-DO
                    /*
                    Text(viewModel.isMember ? "G" : String(viewModel.username.prefix(1)).uppercased())
                        .font(.system(size: 17, weight: .bold))
                        .foregroundStyle(.white)
                     */
                }
                
                VStack(alignment: .leading, spacing: 2) {
                    Text("SIGNING IN AS")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.tertiary)
                    
                    HStack(spacing: 6) {
                        Text(viewModel.username)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(.primary)
                        
                        Text(viewModel.userRole)
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(viewModel.isMember ? Color.gray : Color.blue)
                            .clipShape(.rect(cornerRadius: 4))
                    }
                }
                
                Spacer()
            }
            .padding(12)
            .background(Color(uiColor: .secondarySystemBackground))
            .clipShape(.rect(cornerRadius: 12))
            */
            
        //    if !viewModel.isMember {
                // Permissions Checklist Section
                VStack(spacing: 0) {
                    permissionRow(title: "Read library & flowsheet")
                    Divider()
                    permissionRow(title: "Log plays during your show")
                    Divider()
                    permissionRow(title: "Edit your personal bin")
                }
                .padding(.horizontal, 4)
           // }
            
            Spacer()
            
            // Approve failure: stays on screen rather than flashing as a
            // toast, since the DJ may need to act on it (re-scan, ask for a fresh
            // QR, sign in again). Cleared by the next Approve tap.
            if let approveError {
                approveFailureNote(approveError)
            }
            
            // Action Buttons Section
            VStack(spacing: 8) {
                    Button {
                        Task {
                            // The outcome is rendered from view-model state:
                            // success flips `workflowState` to `.approved`, and a
                            // failure sets `approveError`, shown above.
                            _ = await viewModel.approve(userCode: userCode)
                        }
                    } label: {
                        Text("Approve")
                            .font(.system(size: 17, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .frame(height: 50)
                            .background(Color.blue)
                            .clipShape(.rect(cornerRadius: 14))
                    }
                    
                    Button {
                        Task {
                            let result = await viewModel.deny(userCode: userCode)
                            onDismissWithToast?(result, "red")
                            dismiss()
                        }
                    } label: {
                        Text("Reject")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(.red)
                            .frame(maxWidth: .infinity)
                            .frame(height: 44)
                    }
            }
            .padding(.bottom, 16)
        }
        .padding(.horizontal, 20)
    }

    private func approveFailureNote(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 15))
                .foregroundStyle(.red)
            
            Text(text)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.primary)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
            
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(Color.red.opacity(0.10))
        .clipShape(.rect(cornerRadius: 12))
        .accessibilityElement(children: .combine)
    }

    private func permissionRow(title: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "checkmark")
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(Color.green)
            
            Text(title)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.primary)
            
            Spacer()
        }
        .padding(.vertical, 8)
    }
}

/// The error card: an unreadable QR, an invalid/expired/already-used code, or a
/// verify failure. Its only action is Dismiss — recovery is a fresh QR.
struct DeviceAuthErrorView: View {
    let message: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 20) {
            Spacer()

            ZStack {
                Circle()
                    .fill(Color.red.opacity(0.12))
                    .frame(width: 72, height: 72)
                
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 36))
                    .foregroundStyle(.red)
            }

            VStack(spacing: 8) {
                Text("Unable to Verify Code")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(.primary)

                Text(message)
                    .font(.system(size: 15, weight: .regular))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 16)
            }

            Spacer()

            Button {
                dismiss()
            } label: {
                Text("Dismiss")
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity)
                    .frame(height: 50)
                    .background(Color(uiColor: .systemGray5))
                    .clipShape(.rect(cornerRadius: 14))
            }
            .padding(.bottom, 16)
        }
        .padding(.horizontal, 24)
    }
}

/// The success card shown after Approve succeeds. The "12 hours" figure is the
/// QR-issued session lifetime ADR 0002 sets server-side; it is static copy here,
/// not read from the server, so it must change if that lifetime does.
struct DeviceAuthSuccessView: View {
    //let domain: String
    //var username: String
    let toastMessage: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            // Top Navigation Bar: Done Button
            HStack {
                Spacer()
                Button("Done") {
                    dismiss()
                }
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.blue)
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)

            Spacer()

            // Center Content: Checkmark, Headline, and Expiration Details
            VStack(spacing: 20) {
                ZStack {
                    Circle()
                        .fill(Color(red: 0.18, green: 0.80, blue: 0.44))
                        .frame(width: 80, height: 80)

                    Image(systemName: "checkmark")
                        .font(.system(size: 38, weight: .bold))
                        .foregroundStyle(.white)
                }

                VStack(spacing: 8) {
                    Text("Browser signed in")
                        .font(.system(size: 22, weight: .bold))
                        .foregroundStyle(.primary)
                    //Insert username here
                    /*
                    Text("\(domain) is now signed in as **\(username)** on your browser.")
                        .font(.system(size: 15))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)
                     */
                }

                // Expiration Pill Badge
                HStack(spacing: 6) {
                    Image(systemName: "clock")
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)

                    Text("Session expires in ")
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary) +
                    Text("12 hours")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(.primary)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(Color(uiColor: .systemGray6))
                .clipShape(Capsule())

                Text("You can sign out any time from your account menu.")
                    .font(.system(size: 13))
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }

            Spacer()

            // Bottom Toast Pill Banner
            HStack(spacing: 10) {
                Circle()
                    .fill(Color.green)
                    .frame(width: 8, height: 8)

                Text(toastMessage)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.white)

                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(Color(red: 0.17, green: 0.17, blue: 0.18))
            .clipShape(Capsule())
            .padding(.horizontal, 20)
            .padding(.bottom, 16)
        }
    }
}
