//
//  FreeDOGameCore.swift
//  PVFreeDO
//
//  Created by Joseph Mattiello on 5/23/24.
//  Copyright © 2024 Provenance EMU. All rights reserved.
//

import Foundation

import PVEmulatorCore
import PVFreeDOGameCoreBridge
import PVFreeDOGameCoreOptions

@objc
@objcMembers
open class PVFreeDOGameCore : PVEmulatorCore, @unchecked Sendable {
    
    var _bridge: PVFreeDOGameCoreBridge = .init()
    
    @objc
    public required init() {
        super.init()
        self.bridge = _bridge as? any ObjCBridgedCoreBridge
    }
}

extension PVFreeDOGameCore: PV3DOSystemResponderClient {
    public func didPush(_ button: PVCoreBridge.PV3DOButton, forPlayer player: Int) {
        (_bridge as! PV3DOSystemResponderClient).didPush(button, forPlayer: player)
    }
    
    public func didRelease(_ button: PVCoreBridge.PV3DOButton, forPlayer player: Int) {
        (_bridge as! PV3DOSystemResponderClient).didRelease(button, forPlayer: player)
    }
}

extension PVFreeDOGameCore: CoreOptional {
    public static var options: [PVCoreBridge.CoreOption] {
        FreeDOGameCoreOptions.options
    }
}
