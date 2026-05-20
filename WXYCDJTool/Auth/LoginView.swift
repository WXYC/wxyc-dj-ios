//
//  LoginView.swift
//  WXYCDJTool
//
//  Username + password sign-in form. Delegates the call to LoginViewModel;
//  surfaces any AuthError inline.
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

    private enum Field { case username, password }

    var body: some View {
        NavigationStack {
            Group {
                if let viewModel {
                    formBody(viewModel: viewModel)
                } else {
                    ProgressView()
                }
            }
            .navigationTitle("WXYC DJ Tool")
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
                TextField("Username", text: $viewModel.username)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .textContentType(.username)
                    .submitLabel(.next)
                    .focused($focusedField, equals: .username)
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
