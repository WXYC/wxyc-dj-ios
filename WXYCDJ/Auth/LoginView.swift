//
//  LoginView.swift
//  WXYCDJ
//
//  Sign-in form: one identifier field (username or email, as dj.wxyc.org
//  accepts) plus a password. Delegates the call to LoginViewModel; surfaces
//  any AuthError inline.
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
                    formBody(viewModel: viewModel)
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
    private func formBody(viewModel: LoginViewModel) -> some View {
        @Bindable var viewModel = viewModel
        Form {
            Section {
                // One field for either credential, as dj.wxyc.org has: an
                // email routes to a different better-auth endpoint than a
                // username (issue #97), but that is AuthService's business.
                // The email keyboard puts `@` and `.` on the primary layer and
                // serves a username just as well.
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
                    } else {
                        Text("Sign In")
                            .frame(maxWidth: .infinity)
                            .bold()
                    }
                }
                .disabled(!viewModel.canSubmit)
            }
        }
    }
}
