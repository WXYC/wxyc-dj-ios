//
//  DeviceAuthView.swift
//  WXYCDJ
//
//  Created by Meira Volk on 8/12/26.
//

import SwiftUI
import WXYCAPI

struct DeviceAuthView: View {
    
    
    @Environment(AppDependencies.self) private var deps
    @State private var viewModel: DeviceAuthViewModel?
    @Binding var scannedCode: String?
    @State var userCode: String
    //Should I initilize userCode up here?
    
    var message: String
    
    //so this is just the viewModel, but you still need to add the view with the buttons and everything
    var body: some View {
        NavigationStack {
            Group {
                if let viewModel {
                    if let userCode = viewModel.processCode(scannedCode: scannedCode) {
                        content(for: viewModel, with: userCode)
                    }
                    else {
                        /*Insert a "Unrecognized code pop up here"*/
                    }
                } else {
                    ProgressView()
                }
                    
            }
      //      .navigationTitle("WXYC DJ")
        }
        .onAppear {
            if viewModel == nil {
                viewModel = DeviceAuthViewModel(api: deps.api)
            }
        }
        .onChange(of: message) {
            if message != nil { // for now we'll just display a view with the message and an x button
                SigninSuccessView()
            }
        }
    }
    
    @ViewBuilder
    private func content(for viewModel: DeviceAuthViewModel, with userCode: String) -> some View {
       // switch viewModel.state {
       // case .valid:
        Section {
            HStack {
                Image(systemName: "globe")
                    .font(.largeTitle)
                    .foregroundColor(.white)
                    .padding()
                    .background(Color.blue)
                    .cornerRadius(12)
                
                VStack(alignment: .leading) {
                    Text("dj.wxyc.org").bold()
                    //add actual stopwatch thing for the secondes
                    Text("Studio computer • Chrome • Requested 18s ago")
                        .font(.caption)
                        .foregroundColor(.gray)
                }
            }
            
            Divider()
            
            // ... Add the rest of your custom layout here (User info, checklist) ...
            
            Spacer()
        }
            Section {
                Button {
                    Task { await viewModel.approve(userCode: userCode) }
                } label: {
             Text("Approve")
                 .bold()
                 .frame(maxWidth: .infinity)
                 .padding()
                 .background(Color.blue)
                 .foregroundColor(.white)
                 .cornerRadius(12)
                    }
                .disabled(!viewModel.canSubmit) //need to find an equivalent way to disable buttons after pressing, don't want1s users to be able to spam calls to service?
                Button {
                    Task { await viewModel.deny() }
                } label: {
             Text("Reject")
                 .frame(maxWidth: .infinity)
                 .padding()
                 .foregroundColor(.red)
                    }
                .disabled(!viewModel.canSubmit)
                }
            }
        //add a message variable or a message code tuple, and pull up a screen w/ the message
        
        
        //other cases if we choose to go with cases
        /*
        case .loading:
            List {
                HStack {
                    ProgressView()
                    Text("Loading…").foregroundStyle(.secondary)
                }
            }
        
        case .invalid:
            if viewModel.source == .local {
                // The offline FTS clone (or a failed live request falling back to
                // it) found nothing. Frame it as the saved library so a miss here
                // doesn't read as a confirmed "not in the WXYC library" — the live
                // catalog wasn't consulted (issue #58).
                ContentUnavailableView {
                    Label("No saved matches", systemImage: "wifi.slash")
                } description: {
                    Text("Nothing in the saved library matches \u{201C}\(viewModel.query)\u{201D}.")
                }
            } else {
                ContentUnavailableView.search(text: viewModel.query)
            }
        */
}

//A purely swiftUI gemini-made mock-up of the device auth view

struct SigninSuccessView: View {
    var body: some View {
        //Insert a screen with a checkmark and an exit button
        Text
    }
}
