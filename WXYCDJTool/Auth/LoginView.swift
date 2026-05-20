//
//  LoginView.swift
//  WXYCDJTool
//
//  Username + password sign-in form. Delegates the call to AuthService;
//  surfaces any AuthError inline.
//
//  Created by Jake on 5/14/26.
//  Copyright © 2026 WXYC. All rights reserved.
//

import SwiftUI
import WXYCAPI

struct LoginView: View {
    @Environment(AuthService.self) private var auth
    @State private var username: String = ""
    @State private var password: String = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Username", text: $username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .textContentType(.username)
                    SecureField("Password", text: $password)
                        .textContentType(.password)
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
                        // Trim whitespace on username only — keyboards (and
                        // password managers) routinely emit a trailing space
                        // on autofill and the server would 401. Password
                        // intentionally untrimmed; whitespace in a password
                        // is significant.
                        let trimmed = username.trimmingCharacters(in: .whitespacesAndNewlines)
                        Task { await auth.signIn(username: trimmed, password: password) }
                    } label: {
                        if case .signingIn = auth.state {
                            ProgressView()
                        } else {
                            Text("Sign In")
                                .frame(maxWidth: .infinity)
                                .bold()
                        }
                    }
                    .disabled(username.isEmpty || password.isEmpty || auth.state == .signingIn)
                }
            }
            .navigationTitle("WXYC DJ Tool")
        }
    }
}
