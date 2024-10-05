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

@objc
public final class FreeDOGameCoreOptions: NSObject, CoreOptions, Sendable {

    @objc
    @MainActor
    public static let freeDoConfig: FreeDoConfig = .init()
    
    public static var options: [CoreOption] {
        var options = [CoreOption]()

        let videoGroup = CoreOption.group(.init(title: "Video", description: nil),
                                          subOptions: Options.Video.allCases)


        options.append(videoGroup)

        return options
    }
    
    enum Options {
        enum Video: CaseIterable {

            static var highResMode: CoreOption { .bool(.init(title: "High resoltion mode", description: "Scales the resoltion of the game to 640x480", requiresRestart: true), defaultValue: false) }
            
            static var scalingAlgorithm: CoreOption { .enumeration(.init(title: "Scaling algorithm", description: "Scaling algorithm to use for high res mode", requiresRestart: true), values: [
                .init(title: "None", description: nil, value: 0),
                .init(title: "HQ2X", description: nil, value: 1),
                .init(title: "HQ3X", description: nil, value: 2),
                .init(title: "HQ4X", description: nil, value: 3)
            ], defaultValue: 0) }
            
            
            static var allCases: [CoreOption] { [Self.highResMode, Self.scalingAlgorithm] }
        }
    }
}

@objc extension FreeDOGameCoreOptions {
    @objc public static var highResMode     : Bool { valueForOption(Options.Video.highResMode) }
    @objc public static var scalingAlgorithm: ScalingAlgorithm  {
        let value: Int = valueForOption(Options.Video.scalingAlgorithm)
        return ScalingAlgorithm.init(rawValue: UInt32(value))
    }
}

@objc
@MainActor
public class FreeDoConfig: NSObject, @unchecked Sendable {
    @MainActor
    @objc static var highResMode: Bool  {
        get { (libfreedo.HightResMode != 0) }
        set { libfreedo.HightResMode = newValue ? 1 : 0 }
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
