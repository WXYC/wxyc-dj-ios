//
//  OTPCodeView.swift
//  WXYCDJ
//
//  The second step of code sign-in: enter the 6 digits WXYC just mailed, with
//  a cooldown-gated resend and a way back to fix a mistyped identifier.
//
//  Created by Jake on 08/18/26.
//  Copyright © 2026 WXYC. All rights reserved.
//

import SwiftUI
import WXYCAPI

struct OTPCodeView: View {
    @Environment(AuthService.self) private var auth
    let viewModel: LoginViewModel

    /// Where the code went. Only `typedEmail` is renderable — it is `nil` in
    /// exactly the case where showing the address would disclose one the DJ never
    /// typed, and this view supplies the wording for that case.
    let destination: LoginCodeDestination

    /// The `nil` case's copy lives here, in the layer that renders it, rather
    /// than in `WXYCAPI` — a second surface (a QR confirmation, a macOS target)
    /// can word it differently without editing the networking package.
    private var displayTarget: String {
        destination.typedEmail ?? "your registered email"
    }

    @FocusState private var codeFocused: Bool

    var body: some View {
        @Bindable var viewModel = viewModel
        Form {
            Section {
                TextField("000000", text: $viewModel.code)
                    .textContentType(.oneTimeCode)  // lets iOS offer the code from the mail notification
                    .keyboardType(.numberPad)       // the server's alphabet is digits only
                    .font(.system(.title2, design: .monospaced))
                    .multilineTextAlignment(.center)
                    .focused($codeFocused)
            } header: {
                Text("Enter your code")
            } footer: {
                // Naming the destination is the DJ's only way to catch a mistyped
                // email: the server answers "code sent" for an address matching no
                // account (`disableSignUp: true`), so nothing downstream can report
                // it. When the address was looked up from a username this reads
                // "your registered email" instead — see LoginCodeDestination.
                Text("Sent to \(displayTarget). It expires in 5 minutes.")
            }

            SignInErrorSection(message: viewModel.displayedError)

            Section {
                PrimaryActionButton(
                    title: "Sign In",
                    isBusy: auth.state == .signingIn,
                    isEnabled: viewModel.canSubmitCode
                ) { await viewModel.submitCode() }

                Button("Send a new code") {
                    Task { await viewModel.resendCode() }
                }
                .frame(maxWidth: .infinity)
                // Gated on a cooldown, not just politeness: better-auth allows 3
                // sends per 60s and Backend-Service 10 requests per 15 minutes
                // per *IP*, which the control room shares.
                .disabled(!viewModel.canResendCode)

                Button("Use a different account") {
                    viewModel.changeIdentifier()
                }
                .frame(maxWidth: .infinity)
            }
        }
        .onAppear { codeFocused = true }
    }
}
