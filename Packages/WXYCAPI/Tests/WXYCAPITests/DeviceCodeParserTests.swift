//
//  DeviceCodeParserTests.swift
//  WXYCAPI
//
//  Created by Meira Volk on 8/7/26.
//

import Foundation
import Testing
@testable import WXYCAPI


@Suite("DeviceCodeParser")
struct DeviceCodeParserTests {
    //don't need async throws in function declaration like in APICLientTests since these stay within swift (I think)
    @Test func deviceParserUserCodeInURL() throws {
        //sample scanned URL
        let scanned = "https://dj.wxyc.org/device?user_code=ABCD-1234"
        
        let code = DeviceCodeParser.userCode(fromScanned: scanned)
        
        #expect(code == "ABCD-1234")
    }
    
    @Test func deviceParserScannedIsBareCode() throws {
        //sample scanned URL
        let scanned = "ABCD-1234"
        
        let code = DeviceCodeParser.userCode(fromScanned: scanned)
        
        #expect(code == nil)
    }
    @Test func deviceParserScannedIsURLWithNoUserCode() throws {
        //sample scanned URL
        let scanned = "https://dj.wxyc.org"
        
        let code = DeviceCodeParser.userCode(fromScanned: scanned)
        
        #expect(code == nil)
    }
    @Test func deviceParserScannedIsWhiteSpace() throws {
        //sample scanned URL
        let scanned = "     "
        
        let code = DeviceCodeParser.userCode(fromScanned: scanned)
        
        #expect(code == nil)
    }
}
