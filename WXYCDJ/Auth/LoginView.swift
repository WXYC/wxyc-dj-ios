//
//  LoginView.swift
//  WXYCDJ
//
//  Sign-in screen. Leads with the mailed one-time code — one identifier field
//  and "Send login code" — and keeps the password form a tap away. Delegates
//  to LoginViewModel; surfaces failures inline, one per stage.
//
//  Created by Jake on 5/14/26.
//  Copyright © 2026 WXYC. All rights reserved.
//

import SwiftUI
import WXYCAPI

struct LoginView: View {
    @Environment(AuthService.self) private var auth
    @State private var viewModel: LoginViewModel?
    @FocusState private var focusedField: Field?

    private enum Field { case identifier, password }

    var body: some View {
        NavigationStack {
            Group {
                if let viewModel {
                    stage(viewModel: viewModel)
                } else {
                    ProgressView()
                }
            }
            .navigationTitle("WXYC DJ")
        }
        .onAppear {
            if viewModel == nil {
                viewModel = LoginViewModel(auth: auth)
            }
        }
    }

    @ViewBuilder
    private func stage(viewModel: LoginViewModel) -> some View {
        switch viewModel.stage {
        case .identifier:
            codeRequestForm(viewModel: viewModel)
        case .awaitingCode(_, let displayTarget):
            OTPCodeView(viewModel: viewModel, displayTarget: displayTarget)
        case .password:
            passwordForm(viewModel: viewModel)
        }
    }

    // MARK: - The path the screen leads with

    @ViewBuilder
    private func codeRequestForm(viewModel: LoginViewModel) -> some View {
        @Bindable var viewModel = viewModel
        Form {
            Section {
                // One field for either credential, as dj.wxyc.org has. The email
                // keyboard puts `@` and `.` on the primary layer and serves a
                // username just as well.
                TextField("Username or email", text: $viewModel.identifier)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .textContentType(.username)
                    .keyboardType(.emailAddress)
                    .submitLabel(.go)
                    .focused($focusedField, equals: .identifier)
                    .onSubmit { Task { await viewModel.requestCode() } }
            } header: {
                Text("Sign in to WXYC DJ")
            } footer: {
                Text("We'll send a 6-digit code to your registered email.")
            }

            // `sendLoginCode` never touches `auth.lastError` — it establishes no
            // session — so this stage renders the view model's own error and
            // nothing else.
            if let sendError = viewModel.sendError {
                Section {
                    Text(sendError)
                        .foregroundStyle(.red)
                }
            }

            Section {
                Button {
                    Task { await viewModel.requestCode() }
                } label: {
                    if viewModel.isSendingCode {
                        ProgressView()
                            .frame(maxWidth: .infinity)
                    } else {
                        Text("Send login code")
                            .frame(maxWidth: .infinity)
                            .bold()
                    }
                }
                .disabled(!viewModel.canRequestCode)

                Button("Sign in with password instead") {
                    viewModel.usePassword()
                }
                .frame(maxWidth: .infinity)
            }
        }
    }

    // MARK: - The secondary path

    @ViewBuilder
    private func passwordForm(viewModel: LoginViewModel) -> some View {
        @Bindable var viewModel = viewModel
        Form {
            Section {
                TextField("Username or email", text: $viewModel.identifier)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .textContentType(.username)
                    .keyboardType(.emailAddress)
                    .submitLabel(.next)
                    .focused($focusedField, equals: .identifier)
                    .onSubmit { focusedField = .password }
                SecureField("Password", text: $viewModel.password)
                    .textContentType(.password)
                    .submitLabel(.go)
                    .focused($focusedField, equals: .password)
                    .onSubmit { Task { await viewModel.submit() } }
            } header: {
                Text("dj.wxyc.org credentials")
            }

            if let error = auth.lastError {
                Section {
                    Text(error.localizedMessage)
                        .foregroundStyle(.red)
                }
            }

            Section {
                Button {
                    Task { await viewModel.submit() }
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
                .disabled(!viewModel.canSubmit)

                Button("Email me a code instead") {
                    viewModel.useCode()
                }
                .frame(maxWidth: .infinity)
            }
        }
    }
}
