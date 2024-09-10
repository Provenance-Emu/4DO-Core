//
//  CoreOptions.swift
//  PVFreeDOGameCoreSwift
//
//  Created by Joseph Mattiello on 9/19/21.
//  Copyright © 2021 Provenance Emu. All rights reserved.
//

import Foundation
import PVSupport
import PVCoreBridge
import PVEmulatorCore
import PVLogging
@preconcurrency import libfreedo

internal final class PVFreeDOGameCoreOptions: Sendable {

    @MainActor
    public static let freeDoConfig: FreeDoConfig = .init()
    
    public static var options: [CoreOption] {
        var options = [CoreOption]()

        let videoGroup = CoreOption.group(.init(title: "Video", description: nil),
                                         subOptions: [highResMode])

//        let hacksGroup = CoreOption.group(
//            .init(title: "Hacks",
//                  description: "Performance hacks that work with some games better than others."),
//            subOptions: [])

        options.append(videoGroup)
//        options.append(hacksGroup)

        return options
    }


    nonisolated(unsafe) static let highResMode: CoreOption = .bool(.init(title: "High resoltion mode", description: "Scales the resoltion of the game to 640x480", requiresRestart: true), defaultValue: false)
}

extension PVFreeDOGameCore: CoreOptional {
    public static var options: [PVCoreBridge.CoreOption] {
        PVFreeDOGameCoreOptions.options
    }
}

@objc 
public extension PVFreeDOGameCore {
    @MainActor
    @objc var freedo_high_res_mode: Bool {
        get {
            PVFreeDOGameCore.valueForOption(PVFreeDOGameCoreOptions.highResMode).asBool
        }
        set {
            PVFreeDOGameCore.setValue(newValue, forOption: PVFreeDOGameCoreOptions.highResMode)
            FreeDoConfig.highResMode = newValue
        }
    }
}

@MainActor
struct FreeDoConfig: @unchecked Sendable {
    @MainActor
    static var highResMode: Bool  {
        get { (libfreedo.HightResMode != 0) }
        set { libfreedo.HightResMode = newValue ? 1 : 0 }
    }
    
    init() {
    }
}

//
//extension PVJaguarGameCore: CoreActions {
//	public var coreActions: [CoreAction]? {
//		let bios = CoreAction(title: "Use Jaguar BIOS", options: nil)
//		let fastBlitter =  CoreAction(title: "Use fast blitter", options:nil)
//		return [bios, fastBlitter]
//	}
//
//	public func selected(action: CoreAction) {
//		DLOG("\(action.title), \(String(describing: action.options))")
//	}
//}
