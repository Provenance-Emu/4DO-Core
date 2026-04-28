//
//  FreeDOGameCore+RetroAchievements.swift
//  PVFreeDO
//
//  Conformance of PVFreeDOGameCore (3DO) to CoreRetroAchievements via the
//  shared PVRcheevosBridge default impl.
//
//  Memory map:
//    libfreedo lays out 2 MiB DRAM + 1 MiB VRAM contiguously starting at the
//    pointer returned by FDP_GETP_RAMS. We expose the full 3 MiB block at
//    rcheevos address 0x00000000 to match the 3DO physical address map.
//

import Foundation
import PVCoreBridge
import PVFreeDOGameCoreBridge
import PVRcheevos
import PVRcheevosBridge

extension PVFreeDOGameCore: CoreRetroAchievements {

    public func rcheevosRegions() -> [RcheevosRegion] {
        guard let ptr = _bridge.systemRAMPtr else { return [] }
        let byteCount = UInt32(_bridge.systemRAMSize)
        guard byteCount > 0 else { return [] }
        return [
            RcheevosRegion(
                rcAddress: 0x00000000,
                base: ptr,
                size: byteCount)
        ]
    }
}
