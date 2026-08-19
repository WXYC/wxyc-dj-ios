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

    /// What the DJ is told the code went to — **never** an address resolved
    /// from a username. `LoginCodeDestination` splits this from the address the
    /// verify call is keyed on precisely so this view cannot render the latter.
    let displayTarget: String

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

            // Coalesced deliberately. Rendering only `auth.lastError` here
            // swallowed every resend failure — and worse, made the error already
            // on screen disappear, since `sendLoginCode` clears `lastError` on
            // entry while its own failure lands in `sendError`.
            if let error = viewModel.displayedError {
                Section {
                    Text(error)
                        .foregroundStyle(.red)
                }
            }

            Section {
                Button {
                    Task { await viewModel.submitCode() }
                } label: {
                    if case .signingIn = auth.state {
                        ProgressView()
                            .frame(maxWidth: .infinity)
                    } else {
                        Text("Sign In")
                            .frame(maxWidth: .infinity)
                            .bold()
                    }
                }
                .disabled(!viewModel.canSubmitCode)

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
