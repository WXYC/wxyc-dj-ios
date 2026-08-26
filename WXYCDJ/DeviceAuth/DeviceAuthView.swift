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
    @Environment(AuthService.self) private var auth
    @State private var viewModel: DeviceAuthViewModel?
    @Binding var scannedCode: String?
    //@State var userCode: String
    //Should I initilize userCode up here?

    @State var message: String = "Unknown code"
    
    //so this is just the viewModel, but you still need to add the view with the buttons and everything
    var body: some View {
        Group {
            if let viewModel {
                // This safely checks AND extracts the userCode in one line!
                if let userCode = viewModel.processCode(scannedCode: scannedCode) {
                    content(for: viewModel, with: userCode)
                } else {
                    // Note: Make sure to pass your binding here!
                    UpdateView(message: $message)
                }
            } else {
                ProgressView()
            }
        }
      //      .navigationTitle("WXYC DJ")
        .onAppear {
            if viewModel == nil {
                viewModel = DeviceAuthViewModel(api: deps.api)
            }
        }
    }
        

    
    @ViewBuilder
    private func content(for viewModel: DeviceAuthViewModel, with userCode: String) -> some View {
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
                    Task { await message = viewModel.approve(userCode: userCode) }
                } label: {
             Text("Approve")
                 .bold()
                 .frame(maxWidth: .infinity)
                 .padding()
                 .background(Color.blue)
                 .foregroundColor(.white)
                 .cornerRadius(12)
                    }
                //need to find an equivalent way to disable buttons after pressing, don't want1s users to be able to spam calls to service?
                Button {
                    Task { await message = viewModel.deny(userCode: userCode) }
                } label: {
             Text("Reject")
                 .frame(maxWidth: .infinity)
                 .padding()
                 .foregroundColor(.red)
                    }
                }
            }

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

struct UpdateView: View {
    @Binding var message: String
    var body: some View {
        //Insert a screen with a checkmark and an exit button
        VStack{
            Text(message)
            Button("Dismiss") {
                .onDismiss()
            }
        }
    }
}
 

