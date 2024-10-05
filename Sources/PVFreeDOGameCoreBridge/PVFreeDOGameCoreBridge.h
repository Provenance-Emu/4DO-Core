/*
 Copyright (c) 2014, OpenEmu Team
 

 Redistribution and use in source and binary forms, with or without
 modification, are permitted provided that the following conditions are met:
     * Redistributions of source code must retain the above copyright
       notice, this list of conditions and the following disclaimer.
     * Redistributions in binary form must reproduce the above copyright
       notice, this list of conditions and the following disclaimer in the
       documentation and/or other materials provided with the distribution.
     * Neither the name of the OpenEmu Team nor the
       names of its contributors may be used to endorse or promote products
       derived from this software without specific prior written permission.

 THIS SOFTWARE IS PROVIDED BY OpenEmu Team ''AS IS'' AND ANY
 EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
 WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
 DISCLAIMED. IN NO EVENT SHALL OpenEmu Team BE LIABLE FOR ANY
 DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
 (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
  LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND
 ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
 (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
  SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 */

@import PVCoreObjCBridge;
@import Foundation;
@import libcue;
@import libfreedo;

@protocol ObjCBridgedCoreBridge;
@protocol PV3DOSystemResponderClient;

struct VolumeHeader             // 132 bytes
{
    Byte recordType;            // 1 byte
    Byte syncBytes[5];          // 5 bytes
    Byte recordVersion;         // 1 byte
    Byte flags;                 // 1 byte
    Byte comment[32];           // 32 bytes
    Byte label[32];             // 32 bytes
    UInt32 id;                  // 4 bytes
    UInt32 blockSize;           // 4 bytes
    UInt32 blockCount;          // 4 bytes
    UInt32 rootDirId;           // 4 bytes
    UInt32 rootDirBlocks;       // 4 bytes
    UInt32 rootDirBlockSize;    // 4 bytes
    UInt32 lastRootDirCopy;     // 4 bytes
    UInt32 rootDirCopies[8];    // 32 bytes
};

unsigned char nvramhead[]=
{
    0x01,0x5a,0x5a,0x5a,0x5a,0x5a,0x02,0,0,0,0,0,0,0,0,0,
    0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,
    0,0,0,0,0,0,0,0,0x6e,0x76,0x72,0x61,0x6d,0,0,0,
    0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,
    0,0,0,0,0,0,0,0,0xff,0xff,0xff,0xff,0,0,0,1,
    0,0,0x80,0,0xff,0xff,0xff,0xfe,0,0,0,0,0,0,0,1,
    0,0,0,0,0,0,0,0x84,0,0,0,0,0,0,0,0,
    0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,
    0,0,0,0,0x85,0x5a,2,0xb6,0,0,0,0x98,0,0,0,0x98,
    0,0,0,0x14,0,0,0,0x14,0x7A,0xa5,0x65,0xbd,0,0,0,0x84,
    0,0,0,0x84,0,0,0x76,0x68,0,0,0,0x14
};

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Weverything" // Silence "Cannot find protocol definition" warning due to forward declaration.
@interface PVFreeDOGameCoreBridge: PVCoreObjCBridge <ObjCBridgedCoreBridge, PV3DOSystemResponderClient>
#pragma clang diagnostic pop

//@property (nonatomic, retain) NSString *romName;
//
//@property (nonatomic, assign)   unsigned char *biosRom1Copy;
//@property (nonatomic, assign)   unsigned char *biosRom2Copy;
//@property (nonatomic, assign)   VDLFrame *frame;
//
//@property (nonatomic, retain)   NSFileHandle *isoStream;
//@property (nonatomic, assign)   TrackMode isoMode;
//@property (nonatomic, assign)   int sectorCount;
//@property (nonatomic, assign)   unsigned long currentSector;
//@property (nonatomic, assign)   BOOL isSwapFrameSignaled;
//
////@property (nonatomic, assign)   uint32_t *videoBuffer;
////@property (nonatomic, assign)   uint32_t *videoBufferA;
////@property (nonatomic, assign)   uint32_t *videoBufferB ;
//
//@property (nonatomic, assign)   int videoWidth, videoHeight;
//@property (nonatomic, assign)   uintptr_t *sampleBuffer;
//@property (nonatomic, assign)   uint sampleCurrent;
//
//@property (nonatomic, copy) GCExtendedGamepadValueChangedHandler valueChangedHandler;
@end
