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

#import "PVFreeDOGameCoreBridge.h"

@import PVSupport;
@import PVEmulatorCore;
@import PVCoreBridge;
@import PVCoreObjCBridge;
@import PVAudio;
@import PVLoggingObjC;
@import PVFreeDOGameCoreOptions;
@import libfreedo;

#import <libchdr/chd.h>
#import <stdint.h>
#import <strings.h>

#if __has_include(<OpenGLES/ES3/gl.h>)
#import <OpenGLES/ES3/gl.h>
#import <OpenGLES/ES3/glext.h>
#else
#import <OpenGL/OpenGL.h>
#import <GLUT/GLUT.h>
#endif

#define TEMP_BUFFER_SIZE 5512
#define ROM1_SIZE 1 * 1024 * 1024
#define ROM2_SIZE 933636 //was 1 * 1024 * 1024,
#define NVRAM_SIZE 32 * 1024

#define INPUTBUTTONL     (1<<4)
#define INPUTBUTTONR     (1<<5)
#define INPUTBUTTONX     (1<<6)
#define INPUTBUTTONP     (1<<7)
#define INPUTBUTTONC     (1<<8)
#define INPUTBUTTONB     (1<<9)
#define INPUTBUTTONA     (1<<10)
#define INPUTBUTTONLEFT  (1<<11)
#define INPUTBUTTONRIGHT (1<<12)
#define INPUTBUTTONUP    (1<<13)
#define INPUTBUTTONDOWN  (1<<14)

typedef struct{
    int buttons; // buttons bitfield
}inputState;

inputState internal_input_state[6];

@interface PVFreeDOGameCoreBridge ()
{
    NSString *romName;

    unsigned char *biosRom1Copy;
    unsigned char *biosRom2Copy;
    VDLFrame *frame;

    NSFileHandle *isoStream;
    TrackMode isoMode;
    int sectorCount;
    int currentSector;
    BOOL isSwapFrameSignaled;

    uint32_t *videoBuffer;
    uint32_t *videoBufferA;
    uint32_t *videoBufferB ;

    int videoWidth, videoHeight;
    //uintptr_t sampleBuffer[TEMP_BUFFER_SIZE];
    int32_t sampleBuffer[TEMP_BUFFER_SIZE];
    uint sampleCurrent;

    /// CHD (libchdr) disc access; when non-NULL, `isoStream` is nil and sectors are read via `chd_read`.
    chd_file *chdFile;
    uint8_t *chdHunkBuffer;
    int64_t chdCachedHunkIndex;
    uint32_t chdBytesPerHunk;
    uint32_t chdBytesPerFrame;
    uint32_t chdFramesPerHunk;
    int32_t chdTotalFrames;
    int32_t chdTrackLBA;
    int32_t chdTrackFileOffset;
    /// Bytes per linear disc frame for hack offset reads (2352/2048 for ISO; CHD `unitbytes`).
    uint32_t discLinearFrameSize;
}
@property (nonatomic, assign) BOOL loaded;
@end

/// Parses CD-ROM track metadata; requires a single non-audio track (same constraint as one-track CUE).
static BOOL ParseCHDTrackLayout(chd_file *chd, const chd_header *hd, uint32_t bpf, uint32_t fph, int32_t *outTrackLBA, int32_t *outFileOffset, int32_t *outTotalFrames, NSError **error) {
    /// Width-limited scans (metadata strings are untrusted; avoid sscanf %s overflow vs `type`/`subtype`/gap buffers).
    static const char * const kCHDMeta2Scan = "TRACK:%d TYPE:%63s SUBTYPE:%31s FRAMES:%d PREGAP:%d PGTYPE:%31s PGSUB:%31s POSTGAP:%d";
    static const char * const kCHDMetaScan = "TRACK:%d TYPE:%63s SUBTYPE:%31s FRAMES:%d";

    typedef struct {
        int trackno;
        int32_t lba;
        int32_t file_offset;
        BOOL is_audio;
    } ParsedRow;

    ParsedRow rows[100];
    int rowCount = 0;
    BOOL anyMode2 = NO;

    int32_t plba = -150;
    int32_t file_offset_run = 0;
    uint32_t metaIndex = 0;

    while (1) {
        char meta[256];
        chd_error merr;
        int trackno = 0, frames = 0, pregap = 0, postgap = 0;
        char type[64] = {0};
        char subtype[32] = {0};
        char pgtype[32] = {0};
        char pgsub[32] = {0};

        merr = chd_get_metadata(chd, CDROM_TRACK_METADATA2_TAG, metaIndex, meta, sizeof(meta), NULL, NULL, NULL);
        if (merr == CHDERR_NONE) {
            if (sscanf(meta, kCHDMeta2Scan, &trackno, type, subtype, &frames, &pregap, pgtype, pgsub, &postgap) < 4) {
                break;
            }
        } else {
            merr = chd_get_metadata(chd, CDROM_TRACK_METADATA_TAG, metaIndex, meta, sizeof(meta), NULL, NULL, NULL);
            if (merr != CHDERR_NONE) {
                break;
            }
            if (sscanf(meta, kCHDMetaScan, &trackno, type, subtype, &frames) < 4) {
                break;
            }
            pregap = 0;
            postgap = 0;
            pgtype[0] = '\0';
            pgsub[0] = '\0';
        }

        if (pregap < 0) {
            pregap = 0;
        }
        if (postgap < 0) {
            postgap = 0;
        }

        if (trackno < 1 || trackno > 99) {
            metaIndex++;
            continue;
        }

        if (frames <= 0) {
            metaIndex++;
            continue;
        }

        int32_t pregap_fixed = (trackno == 1) ? 150 : ((pgtype[0] == 'V') ? 0 : pregap);
        int32_t pregap_dv = (pgtype[0] == 'V') ? pregap : 0;

        if (pregap_dv > frames) {
            if (error) {
                *error = [NSError errorWithDomain:CoreError.PVEmulatorCoreErrorDomain
                                             code:PVEmulatorCoreErrorCodeCouldNotLoadRom
                                         userInfo:@{NSLocalizedDescriptionKey: @"Invalid CHD track metadata (variable pregap exceeds track frames)."}];
            }
            return NO;
        }

        plba += pregap_fixed;

        BOOL is_audio = (strcasecmp(type, "AUDIO") == 0);
        if (strcasestr(type, "MODE2") != NULL) {
            anyMode2 = YES;
        }

        rows[rowCount].trackno = trackno;
        rows[rowCount].lba = plba;
        rows[rowCount].file_offset = file_offset_run + pregap_dv;
        rows[rowCount].is_audio = is_audio;
        rowCount++;
        if (rowCount >= 99) {
            if (error) {
                *error = [NSError errorWithDomain:CoreError.PVEmulatorCoreErrorDomain
                                             code:PVEmulatorCoreErrorCodeCouldNotLoadRom
                                         userInfo:@{NSLocalizedDescriptionKey: @"CHD has too many track metadata entries to load safely."}];
            }
            return NO;
        }

        file_offset_run += pregap_dv;
        file_offset_run += frames - pregap_dv;
        file_offset_run += postgap;
        int pad = ((frames + 3) & ~3) - frames;
        file_offset_run += pad;

        plba += (frames - pregap_dv);
        plba += postgap;

        metaIndex++;
    }

    if (rowCount == 0) {
        *outTrackLBA = 0;
        *outFileOffset = 0;
        if (hd->logicalbytes > 0) {
            *outTotalFrames = (int32_t)(hd->logicalbytes / (uint64_t)bpf);
        } else {
            *outTotalFrames = (int32_t)((uint64_t)hd->totalhunks * (uint64_t)fph);
        }
        return YES;
    }

    if (rowCount > 1) {
        if (error) {
            *error = [NSError errorWithDomain:CoreError.PVEmulatorCoreErrorDomain
                                         code:PVEmulatorCoreErrorCodeCouldNotLoadRom
                                     userInfo:@{NSLocalizedDescriptionKey: @"This CHD has multiple tracks; FreeDO expects a single data track (same as one-track CUE/ISO)."}];
        }
        return NO;
    }

    if (rows[0].is_audio) {
        if (error) {
            *error = [NSError errorWithDomain:CoreError.PVEmulatorCoreErrorDomain
                                         code:PVEmulatorCoreErrorCodeCouldNotLoadRom
                                     userInfo:@{NSLocalizedDescriptionKey: @"CHD track is audio-only; a Mode 1 data track is required."}];
        }
        return NO;
    }

    if (anyMode2) {
        if (error) {
            *error = [NSError errorWithDomain:CoreError.PVEmulatorCoreErrorDomain
                                         code:PVEmulatorCoreErrorCodeCouldNotLoadRom
                                     userInfo:@{NSLocalizedDescriptionKey: @"Mode 2 / XA tracks in CHD are not supported for FreeDO (use Mode 1 CUE/ISO-style images)."}];
        }
        return NO;
    }

    *outTrackLBA = rows[0].lba;
    *outFileOffset = rows[0].file_offset;
    if (hd->logicalbytes > 0) {
        *outTotalFrames = (int32_t)(hd->logicalbytes / (uint64_t)bpf);
    } else {
        *outTotalFrames = plba;
    }
    return YES;
}

static __weak PVFreeDOGameCoreBridge * _Nonnull _current;

@implementation PVFreeDOGameCoreBridge

// libfreedo callback
static void *fdcCallback(int procedure, void *data)
{
    __strong PVFreeDOGameCoreBridge * current = _current;
    if (current == nil) {
        if (procedure == EXT_READ2048 && data != NULL) {
            memset(data, 0, 2048);
        }
        return (void *)0;
    }
    switch(procedure)
    {
        case EXT_READ_ROMS:
        {
            if (data != NULL && current->biosRom1Copy != NULL) {
                memcpy(data, current->biosRom1Copy, ROM1_SIZE);
            }
            //void *biosRom2Dest = (void*)((intptr_t)data + ROM2_SIZE);
            //memcpy(biosRom2Dest, current->biosRom2Copy, ROM2_SIZE);

            break;
        }
        case EXT_READ_NVRAM:
            break;
        case EXT_WRITE_NVRAM:
            break;
        case EXT_SWAPFRAME:
        {
            current->isSwapFrameSignaled = YES;
            return current->frame;
        }
        case EXT_PUSH_SAMPLE:
        {
            current->sampleBuffer[current->sampleCurrent] = (uintptr_t)data;
            current->sampleCurrent++;
            if(current->sampleCurrent >= TEMP_BUFFER_SIZE)
            {
                current->sampleCurrent = 0;
                [[current ringBufferAtIndex:0] write:current->sampleBuffer size:sizeof(int32_t) * TEMP_BUFFER_SIZE];
                memset(current->sampleBuffer, 0, sizeof(int32_t) * TEMP_BUFFER_SIZE);
            }

            break;
        }
        case EXT_GET_PBUSLEN:
            return (void*)16;
        case EXT_GETP_PBUSDATA:
        {
            // Set up raw data to return
            unsigned char *pbusData;
            pbusData = (unsigned char *)malloc(sizeof(unsigned char)*16);
            if (pbusData == NULL) {
                return (void *)0;
            }

            pbusData[0x0] = 0x00;
            pbusData[0x1] = 0x48;
            pbusData[0x2] = CalculateDeviceLowByte(0);
            pbusData[0x3] = CalculateDeviceHighByte(0);
            pbusData[0x4] = CalculateDeviceLowByte(2);
            pbusData[0x5] = CalculateDeviceHighByte(2);
            pbusData[0x6] = CalculateDeviceLowByte(1);
            pbusData[0x7] = CalculateDeviceHighByte(1);
            pbusData[0x8] = CalculateDeviceLowByte(4);
            pbusData[0x9] = CalculateDeviceHighByte(4);
            pbusData[0xA] = CalculateDeviceLowByte(3);
            pbusData[0xB] = CalculateDeviceHighByte(3);
            pbusData[0xC] = 0x00;
            pbusData[0xD] = 0x80;
            pbusData[0xE] = CalculateDeviceLowByte(5);
            pbusData[0xF] = CalculateDeviceHighByte(5);

            return pbusData;
        }
        case EXT_KPRINT:
            break;
        case EXT_FRAMETRIGGER_MT:
        {
            current->isSwapFrameSignaled = YES;
            _freedo_Interface(FDP_DO_FRAME_MT, current->frame);

            break;
        }
        case EXT_READ2048:
            [current readSector:current->currentSector toBuffer:(uint8_t*)data];
            break;
        case EXT_GET_DISC_SIZE:
            return (void *)(intptr_t)current->sectorCount;
        case EXT_ON_SECTOR:
            current->currentSector = (intptr_t)data;
            break;
        case EXT_ARM_SYNC:
            //[current fdcCallbackArmSync:(intptr_t)data];
            WLOG(@"fdcCallback EXT_ARM_SYNC not implimented");
            break;

        default:
            break;
    }
    return (void*)0;
}

static void loadSaveFile(const char* path)
{
    FILE *file;

    file = fopen(path, "rb");
    if ( !file )
    {
        return;
    }

    size_t size = NVRAM_SIZE;
    void *data = _freedo_Interface(FDP_GETP_NVRAM, (void*)0);

    if (size == 0 || !data)
    {
        fclose(file);
        return;
    }

    size_t rc = fread(data, sizeof(uint8_t), size, file);
    if ( rc != size )
    {
        ELOG(@"Couldn't load save file.");
    }

    ILOG(@"Loaded save file: %s", path);

    fclose(file);
}

static void writeSaveFile(const char* path)
{
    size_t size = NVRAM_SIZE;
    void *data = _freedo_Interface(FDP_GETP_NVRAM, (void*)0);

    if(data != NULL && size > 0)
    {
        FILE *file = fopen(path, "wb");
        if(file != NULL)
        {
            ILOG(@"Saving NVRAM %s. Size: %d bytes.", path, (int)size);
            if(fwrite(data, sizeof(uint8_t), size, file) != size)
                ELOG(@"Did not save file properly.");
            fclose(file);
        }
    }
}

- (instancetype)init {
    if((self = [super init])) {
        _current = self;
        _current = self;
        videoBufferA = (uint32_t*)malloc(videoWidth * videoHeight * 4);
        videoBufferB = (uint32_t*)malloc(videoWidth * videoHeight * 4);
        chdFile = NULL;
        chdHunkBuffer = NULL;
        chdCachedHunkIndex = -1;
//        sampleBuffer = (uintptr_t *)malloc(sizeof(uintptr_t) * TEMP_BUFFER_SIZE);
    }

    return self;
}

- (void)dealloc {
    if (chdFile) {
        chd_close(chdFile);
        chdFile = NULL;
    }
    if (chdHunkBuffer) {
        free(chdHunkBuffer);
        chdHunkBuffer = NULL;
    }
    if (isoStream) {
        [isoStream closeFile];
        isoStream = nil;
    }
    if (self->videoBufferA) {
        free(self->videoBufferA);
        self->videoBufferA = nil;
    }
    if (self->videoBufferB) {
        free(self->videoBufferB);
        self->videoBufferB = nil;
    }
}

#pragma mark Execution

/// Opens a CD-ROM CHD via libchdr and configures track layout (single data track only).
- (BOOL)prepareCHDDiscAtPath:(NSString *)path error:(NSError **)error {
    if (path.length == 0) {
        if (error) {
            *error = [NSError errorWithDomain:CoreError.PVEmulatorCoreErrorDomain
                                         code:PVEmulatorCoreErrorCodeCouldNotLoadRom
                                     userInfo:@{NSLocalizedDescriptionKey: @"CHD path is empty."}];
        }
        return NO;
    }
    if (chdFile) {
        chd_close(chdFile);
        chdFile = NULL;
    }
    if (chdHunkBuffer) {
        free(chdHunkBuffer);
        chdHunkBuffer = NULL;
    }
    chdCachedHunkIndex = -1;

    chd_error cerr = chd_open(path.fileSystemRepresentation, CHD_OPEN_READ, NULL, &chdFile);
    if (cerr != CHDERR_NONE || chdFile == NULL) {
        if (error) {
            NSString *msg = [NSString stringWithFormat:@"Could not open CHD: %s", chd_error_string(cerr)];
            *error = [NSError errorWithDomain:CoreError.PVEmulatorCoreErrorDomain
                                         code:PVEmulatorCoreErrorCodeCouldNotLoadRom
                                     userInfo:@{NSLocalizedDescriptionKey: msg}];
        }
        if (chdFile) {
            chd_close(chdFile);
            chdFile = NULL;
        }
        return NO;
    }

    const chd_header *hd = chd_get_header(chdFile);
    if (hd == NULL) {
        chd_close(chdFile);
        chdFile = NULL;
        if (error) {
            *error = [NSError errorWithDomain:CoreError.PVEmulatorCoreErrorDomain
                                         code:PVEmulatorCoreErrorCodeCouldNotLoadRom
                                     userInfo:@{NSLocalizedDescriptionKey: @"CHD header could not be read."}];
        }
        return NO;
    }

    chdBytesPerHunk = hd->hunkbytes;
    if (hd->unitbytes == 2352u || hd->unitbytes == 2448u || hd->unitbytes == 2048u) {
        chdBytesPerFrame = hd->unitbytes;
    } else if (chdBytesPerHunk % 2448u == 0u) {
        chdBytesPerFrame = 2448u;
    } else if (chdBytesPerHunk % 2352u == 0u) {
        chdBytesPerFrame = 2352u;
    } else {
        chd_close(chdFile);
        chdFile = NULL;
        if (error) {
            *error = [NSError errorWithDomain:CoreError.PVEmulatorCoreErrorDomain
                                         code:PVEmulatorCoreErrorCodeCouldNotLoadRom
                                     userInfo:@{NSLocalizedDescriptionKey: @"Unsupported CHD layout (expected CD frame sizes 2048/2352/2448)."}];
        }
        return NO;
    }

    if (chdBytesPerFrame == 0u || chdBytesPerHunk % chdBytesPerFrame != 0u) {
        chd_close(chdFile);
        chdFile = NULL;
        if (error) {
            *error = [NSError errorWithDomain:CoreError.PVEmulatorCoreErrorDomain
                                         code:PVEmulatorCoreErrorCodeCouldNotLoadRom
                                     userInfo:@{NSLocalizedDescriptionKey: @"Invalid CHD hunk/frame geometry."}];
        }
        return NO;
    }

    chdFramesPerHunk = chdBytesPerHunk / chdBytesPerFrame;

    if (!ParseCHDTrackLayout(chdFile, hd, chdBytesPerFrame, chdFramesPerHunk, &chdTrackLBA, &chdTrackFileOffset, &chdTotalFrames, error)) {
        chd_close(chdFile);
        chdFile = NULL;
        return NO;
    }

    if (chdTotalFrames <= 0) {
        chd_close(chdFile);
        chdFile = NULL;
        if (error) {
            *error = [NSError errorWithDomain:CoreError.PVEmulatorCoreErrorDomain
                                         code:PVEmulatorCoreErrorCodeCouldNotLoadRom
                                     userInfo:@{NSLocalizedDescriptionKey: @"CHD reports zero frames."}];
        }
        return NO;
    }

    chdHunkBuffer = (uint8_t *)malloc(chdBytesPerHunk);
    if (chdHunkBuffer == NULL) {
        chd_close(chdFile);
        chdFile = NULL;
        if (error) {
            *error = [NSError errorWithDomain:CoreError.PVEmulatorCoreErrorDomain
                                         code:PVEmulatorCoreErrorCodeCouldNotLoadRom
                                     userInfo:@{NSLocalizedDescriptionKey: @"Out of memory loading CHD hunk buffer."}];
        }
        return NO;
    }

    /// Apply track mode only after CHD + hunk buffer succeed so OOM (or any prior failure) cannot desync `isoMode` / `discLinearFrameSize` from a still-open ISO.
    isoMode = (chdBytesPerFrame == 2048u) ? MODE_MODE1 : MODE_MODE1_RAW;
    discLinearFrameSize = chdBytesPerFrame;

    /// CHD is fully usable; release any prior file-based disc handle (only after success so a bad CHD does not orphan a working ISO session).
    if (isoStream) {
        [isoStream closeFile];
        isoStream = nil;
    }

    ILOG(@"CHD opened: frames=%d bpf=%u trackLBA=%d fileOffset=%d", chdTotalFrames, chdBytesPerFrame, chdTrackLBA, chdTrackFileOffset);
    return YES;
}

/// Reads one decompressed CD frame (full `chdBytesPerFrame` bytes) at CHD CAD index `cad`.
- (chd_error)readCHDFrameAtCAD:(uint32_t)cad buffer:(uint8_t *)frameBuf {
    if (frameBuf == NULL) {
        return CHDERR_INVALID_PARAMETER;
    }
    if (chdFile == NULL || chdHunkBuffer == NULL || chdBytesPerFrame == 0u || chdFramesPerHunk == 0u) {
        /// Callers use at least 2448 bytes (`readSector` / `readDiscBytesAtOffset` stack frames).
        memset(frameBuf, 0, 2448);
        return CHDERR_INVALID_STATE;
    }
    if (chdTotalFrames <= 0 || (uint64_t)cad >= (uint64_t)chdTotalFrames) {
        memset(frameBuf, 0, chdBytesPerFrame);
        return CHDERR_NONE;
    }
    uint32_t hunknum = cad / chdFramesPerHunk;
    uint32_t hunkofs = (cad % chdFramesPerHunk) * chdBytesPerFrame;
    if ((uint64_t)hunkofs + (uint64_t)chdBytesPerFrame > (uint64_t)chdBytesPerHunk) {
        memset(frameBuf, 0, chdBytesPerFrame);
        return CHDERR_INVALID_DATA;
    }
    if (chdCachedHunkIndex != (int64_t)hunknum) {
        chd_error rerr = chd_read(chdFile, hunknum, chdHunkBuffer);
        if (rerr != CHDERR_NONE) {
            memset(frameBuf, 0, chdBytesPerFrame);
            return rerr;
        }
        chdCachedHunkIndex = (int64_t)hunknum;
    }
    memcpy(frameBuf, chdHunkBuffer + hunkofs, chdBytesPerFrame);
    return CHDERR_NONE;
}

/// Copies linear disc bytes (ISO/BIN or CHD logical layout) starting at `offset`.
- (BOOL)readDiscBytesAtOffset:(uint64_t)offset length:(NSUInteger)length into:(void *)dst error:(NSError **)error {
    if (length > 0 && dst == NULL) {
        if (error) {
            *error = [NSError errorWithDomain:CoreError.PVEmulatorCoreErrorDomain
                                         code:PVEmulatorCoreErrorCodeCouldNotLoadRom
                                     userInfo:@{NSLocalizedDescriptionKey: @"Disc read destination buffer is null."}];
        }
        return NO;
    }
    uint8_t *out = (uint8_t *)dst;
    uint64_t remain = length;
    uint64_t pos = offset;
    uint32_t fs = discLinearFrameSize;
    if (fs == 0u) {
        if (error) {
            *error = [NSError errorWithDomain:CoreError.PVEmulatorCoreErrorDomain
                                         code:PVEmulatorCoreErrorCodeCouldNotLoadRom
                                     userInfo:@{NSLocalizedDescriptionKey: @"Disc frame size is unset."}];
        }
        return NO;
    }
    while (remain > 0) {
        uint64_t fi64 = pos / fs;
        if (fi64 > UINT32_MAX) {
            if (error) {
                *error = [NSError errorWithDomain:CoreError.PVEmulatorCoreErrorDomain
                                             code:PVEmulatorCoreErrorCodeCouldNotLoadRom
                                         userInfo:@{NSLocalizedDescriptionKey: @"Disc read offset out of range."}];
            }
            return NO;
        }
        uint32_t fi = (uint32_t)fi64;
        uint32_t inner = (uint32_t)(pos % fs);
        uint8_t frame[2448];
        if (chdFile) {
            chd_error ce = [self readCHDFrameAtCAD:fi buffer:frame];
            if (ce != CHDERR_NONE) {
                if (error) {
                    NSString *msg = [NSString stringWithFormat:@"CHD read failed: %s", chd_error_string(ce)];
                    *error = [NSError errorWithDomain:CoreError.PVEmulatorCoreErrorDomain
                                                 code:PVEmulatorCoreErrorCodeCouldNotLoadRom
                                             userInfo:@{NSLocalizedDescriptionKey: msg}];
                }
                return NO;
            }
        } else {
            if (isoStream == nil) {
                if (error) {
                    *error = [NSError errorWithDomain:CoreError.PVEmulatorCoreErrorDomain
                                                 code:PVEmulatorCoreErrorCodeCouldNotLoadRom
                                             userInfo:@{NSLocalizedDescriptionKey: @"Disc file handle is not open."}];
                }
                return NO;
            }
            uint32_t readLen = (isoMode == MODE_MODE1_RAW) ? 2352u : 2048u;
            if (isoMode == MODE_MODE1_RAW) {
                [isoStream seekToFileOffset:(unsigned long long)(2352ull * fi)];
            } else {
                [isoStream seekToFileOffset:(unsigned long long)(2048ull * fi)];
            }
            NSData *chunk = [isoStream readDataOfLength:readLen];
            if ((NSUInteger)chunk.length < readLen || chunk.bytes == NULL) {
                if (error) {
                    *error = [NSError errorWithDomain:CoreError.PVEmulatorCoreErrorDomain
                                                 code:PVEmulatorCoreErrorCodeCouldNotLoadRom
                                             userInfo:@{NSLocalizedDescriptionKey: @"Short read from disc image."}];
                }
                return NO;
            }
            memcpy(frame, chunk.bytes, readLen);
            if (readLen < sizeof(frame)) {
                memset(frame + readLen, 0, sizeof(frame) - readLen);
            }
        }
        size_t avail = (size_t)fs - (size_t)inner;
        size_t take = remain < (uint64_t)avail ? (size_t)remain : avail;
        memcpy(out, frame + inner, take);
        out += take;
        remain -= take;
        pos += take;
    }
    return YES;
}

- (BOOL)loadFileAtPath:(NSString *)path error:(NSError **)error {
    /// Tear down a running session before replacing disc/core state (avoids e.g. closing the old CHD in `prepareCHDDiscAtPath` while libfreedo is still active).
    if (self.loaded) {
        [self stopEmulation];
    }

    /// Initial file I/O
    self.romName = [path copy];

    NSString *isoPath = nil;
    NSString *cuePath = nil;
    NSString *lowerExtension = [[path pathExtension] lowercaseString];

    if ([lowerExtension isEqualToString:@"chd"]) {
        if (![self prepareCHDDiscAtPath:path error:error]) {
            return NO;
        }
    } else {
    /// Dropping CHD state when loading a file-based image (otherwise `readSector` would keep using the old CHD and handles leak).
    if (chdFile) {
        chd_close(chdFile);
        chdFile = NULL;
    }
    if (chdHunkBuffer) {
        free(chdHunkBuffer);
        chdHunkBuffer = NULL;
    }
    chdCachedHunkIndex = -1;
    if (isoStream) {
        [isoStream closeFile];
        isoStream = nil;
    }

    /// Prefer a cue file when provided or when a sibling exists
    if ([lowerExtension isEqualToString:@"cue"]) {
        cuePath = path;
    } else {
        NSString *siblingCue = [[path stringByDeletingPathExtension] stringByAppendingPathExtension:@"cue"];
        if ([[NSFileManager defaultManager] fileExistsAtPath:siblingCue]) {
            cuePath = siblingCue;
        }
    }

    if (cuePath) {
        NSStringEncoding usedEncoding = NSUTF8StringEncoding;
        NSError *errorCue = nil;
        NSString *cue = [NSString stringWithContentsOfFile:cuePath usedEncoding:&usedEncoding error:&errorCue];

        if (!cue && errorCue) {
            cue = [NSString stringWithContentsOfFile:cuePath encoding:NSISOLatin1StringEncoding error:&errorCue];
        }

        if(!cue) {
            if (error) {
                *error = [NSError errorWithDomain:CoreError.PVEmulatorCoreErrorDomain
                                             code:PVEmulatorCoreErrorCodeCouldNotLoadRom
                                         userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"Error reading cue: %@", errorCue.localizedDescription]}];
            }
            return NO;
        }

        /// Cue loaded -- process it
        const char *cueCString = [cue UTF8String];
        Cd *cd = cue_parse_string(cueCString);
        if (!cd) {
            if (error) {
                *error = [NSError errorWithDomain:CoreError.PVEmulatorCoreErrorDomain
                                             code:PVEmulatorCoreErrorCodeCouldNotLoadRom
                                         userInfo:@{NSLocalizedDescriptionKey: @"Cue file could not be parsed."}];
            }
            return NO;
        }
        ILOG(@"CUE file found and parsed");
        if (cd_get_ntrack(cd)!=1) {
            ELOG(@"Cue file found, but the number of tracks within was not 1.");
            cd_delete(cd);
            if (error) {
                *error = [NSError errorWithDomain:CoreError.PVEmulatorCoreErrorDomain
                                             code:PVEmulatorCoreErrorCodeCouldNotLoadRom
                                         userInfo:@{NSLocalizedDescriptionKey: @"Cue file found, but the number of tracks within was not 1."}];
            }
            return NO;
        }

        /// Check validity of CD Image mode from cue
        Track *track = cd_get_track(cd, 1);
        self->isoMode = (TrackMode)track_get_mode(track);

        if ((self->isoMode!=MODE_MODE1&&self->isoMode!=MODE_MODE1_RAW)) {
            ELOG(@"Cue file found, but the track within was not in the right format (should be BINARY and Mode1+2048 or Mode1+2352)");
            cd_delete(cd);
            if (error) {
                *error = [NSError errorWithDomain:CoreError.PVEmulatorCoreErrorDomain
                                             code:PVEmulatorCoreErrorCodeCouldNotLoadRom
                                         userInfo:@{NSLocalizedDescriptionKey: @"Cue file found, but the track within was not in the right format (should be BINARY and Mode1+2048 or Mode1+2352)"}];
            }
            return NO;
        }

        NSString *isoTrack = [NSString stringWithUTF8String:track_get_filename(track)];
        isoPath = [[cuePath stringByDeletingLastPathComponent] stringByAppendingPathComponent:isoTrack];
        cd_delete(cd);
    } else {
        /// No cue available, assume a single data track
        isoPath = path;
        self->isoMode = [lowerExtension isEqualToString:@"bin"] ? MODE_MODE1_RAW : MODE_MODE1;
    }

    self->isoStream = [NSFileHandle fileHandleForReadingAtPath:isoPath];
    if (!self->isoStream) {
        if (error) {
            *error = [NSError errorWithDomain:CoreError.PVEmulatorCoreErrorDomain
                                         code:PVEmulatorCoreErrorCodeCouldNotLoadRom
                                     userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"Could not open disc image at path %@", isoPath]}];
        }
        return NO;
    }

    discLinearFrameSize = (isoMode == MODE_MODE1_RAW) ? 2352u : 2048u;
    }

    uint8_t sectorZero[2048];
    [self readSector:0 toBuffer:sectorZero];
    VolumeHeader *header = (VolumeHeader*)sectorZero;
    self->sectorCount = (int)reverseBytes(header->blockCount);
    VLOG(@"Sector count is %d", self.sectorCount);

    /// init libfreedo
    [self loadBIOSes];
    [self initVideo];

    videoBufferA = (uint32_t*)malloc(videoWidth * videoHeight * 4);
    videoBufferB = (uint32_t*)malloc(videoWidth * videoHeight * 4);
    videoBuffer = self->videoBufferA;

    currentSector = 0;
    sampleCurrent = 0;

    memset(sampleBuffer, 0, sizeof(int32_t) * TEMP_BUFFER_SIZE);

    _freedo_Interface(FDP_INIT, (void*)*fdcCallback);

    self.loaded = true;
    /// init NVRAM
    memcpy(_freedo_Interface(FDP_GETP_NVRAM, (void*)0), nvramhead, sizeof(nvramhead));

    /// load NVRAM save file
    NSString *extensionlessFilename = [[path lastPathComponent] stringByDeletingPathExtension];
    NSString *batterySavesDirectory = [self batterySavesPath];

    if([batterySavesDirectory length] != 0) {
        [[NSFileManager defaultManager] createDirectoryAtPath:batterySavesDirectory withIntermediateDirectories:YES attributes:nil error:NULL];

        NSString *filePath = [batterySavesDirectory stringByAppendingPathComponent:[extensionlessFilename stringByAppendingPathExtension:@"sav"]];

        loadSaveFile([filePath UTF8String]);
    }

    /// Begin per-game hacks
    /// First check if we find these bytes at offset 0x0 found in some dumps
    const uint8_t bytes[] = { 0x00, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0x00, 0x00, 0x02, 0x00, 0x01 };
    uint8_t prefixScratch[16];
    if (![self readDiscBytesAtOffset:0 length:sizeof(prefixScratch) into:prefixScratch error:NULL]) {
        memset(prefixScratch, 0, sizeof(prefixScratch));
        ELOG(@"Could not read disc prefix for game hack detection");
    }
    NSData *dataTrackBuffer = [NSData dataWithBytes:prefixScratch length:sizeof(prefixScratch)];
    NSData *dataCompare = [[NSData alloc] initWithBytes:bytes length:sizeof(bytes)];
    BOOL bytesFound = [dataTrackBuffer isEqualToData:dataCompare];

    // Read disc header, these 8 bytes seem to be unique for each game
    uint8_t idScratch[8];
    uint64_t idOff = bytesFound ? 0x60ull : 0x50ull;
    if (![self readDiscBytesAtOffset:idOff length:sizeof(idScratch) into:idScratch error:NULL]) {
        memset(idScratch, 0, sizeof(idScratch));
        ELOG(@"Could not read disc ID bytes for game hack detection");
    }
    dataTrackBuffer = [NSData dataWithBytes:idScratch length:sizeof(idScratch)];

    // Check if game requires hacks
    NSDictionary *checkBytes = @{
                                 //@"0004b0002fbc0678" : @(FIX_BIT_TIMING_1), // Crash 'n Burn (JP)
                                 @"0004b0000d2cd096" : @(FIX_BIT_TIMING_1), // Crash 'n Burn (US) - fixes freeze after Total Eclipse preview
                                 @"000320003c0f4cd6" : @(FIX_BIT_TIMING_1), // Space Hulk - Vengeance of the Blood Angels (EU-US) - fixes boot freeze
                                 @"000384001bed10f4" : @(FIX_BIT_TIMING_1), // Blood Angels - Space Hulk (JP) - fixes in-game freezes but makes audio choppy
                                 @"0004d40020aabe16" : @(FIX_BIT_TIMING_1), // Tsuukai Gameshow - Twisted (JP) - fixes boot freeze
                                 @"0004d80009839b53" : @(FIX_BIT_TIMING_1), // Twisted - The Game Show (US) - fixes boot freeze, but has very long boot (a matter of minutes)
                                 //@"0004fc0013222dcd" : @(FIX_BIT_TIMING_2), // Lost Eden (US) - makes FMV choppy, unneeded?
                                 @"0002ae001f1638aa" : @(FIX_BIT_TIMING_2), // Microcosm (JP) - fixes boot freeze
                                 @"0002ae00040de795" : @(FIX_BIT_TIMING_2), // Microcosm (US) - fixes boot freeze
                                 //@"0004c2003e1c60f9" : @(FIX_BIT_TIMING_2), // Nova-Storm (JP) - unneeded?
                                 //@"0004c4000930071d" : @(FIX_BIT_TIMING_2), // Novastorm (US) - unneeded?
                                 //@"000320001195ead8" : @(FIX_BIT_TIMING_3), // Scramble Cobra (demo) (JP) - unneeded?
                                 //@"0004f600394ba195" : @(FIX_BIT_TIMING_3), // Scramble Cobra (JP) - unneeded?
                                 //@"0004f600304ef0ef" : @(FIX_BIT_TIMING_3), // Scramble Cobra (EU) - unneeded?
                                 //@"0004f600207b64da" : @(FIX_BIT_TIMING_3), // Scramble Cobra (US) - unneeded?
                                 @"0004d800207a1ec6" : @(FIX_BIT_TIMING_4), // Twisted - The Game Show (EU) - fixes boot freeze
                                 @"0003e8001f84ae3b" : @(FIX_BIT_TIMING_4), // Virtual Quest - Pharaoh no Fuuin aka Seal of the Pharaoh (JP) - fixes load screen freeze, but has very long boot (a matter of minutes)
                                 @"0003e80038575ddf" : @(FIX_BIT_TIMING_4), // Seal of the Pharaoh (US) - fixes load screen freeze
                                 //@"000509102e0a80f4" : @(FIX_BIT_TIMING_5), // Immercenary (EU-US) - unneeded?
                                 @"0004100000478a28" : @(FIX_BIT_TIMING_5), // Olympic Summer Games (US) - fixes boot freeze
                                 @"0004b00017ff5284" : @(FIX_BIT_TIMING_5), // Phoenix 3 (EU-US) - fixes load screen freeze
                                 //@"0002500017fab0ba" : @(FIX_BIT_TIMING_5), // Super Street Fighter II Turbo (EU) - unneeded?
                                 //@"0002500007772ee0" : @(FIX_BIT_TIMING_5), // Super Street Fighter II X - Grand Master Challenge (JP) - unneeded?
                                 //@"000250001c0e266b" : @(FIX_BIT_TIMING_5), // Super Street Fighter II Turbo (US) [FZSM3851] - unneeded?
                                 //@"000250001023b13a" : @(FIX_BIT_TIMING_5), // Super Street Fighter II Turbo (CA-US) (RE1) - unneeded?
                                 //@"000500003f03c29f" : @(FIX_BIT_TIMING_6), // Wing Commander III (EU-US) (Disc 1 of 4)
                                 //@"000500001694a8a7" : @(FIX_BIT_TIMING_6), // Wing Commander III (US) (Disc 1 of 4)
                                 //@"000500003b4f0a74" : @(FIX_BIT_TIMING_6), // Wing Commander III (EU-US) (Disc 2 of 4)
                                 //@"0005000017992121" : @(FIX_BIT_TIMING_6), // Wing Commander III (US) (Disc 2 of 4)
                                 //@"000500001aefec8b" : @(FIX_BIT_TIMING_6), // Wing Commander III (EU-US) (Disc 3 of 4)
                                 //@"000500003d7875f5" : @(FIX_BIT_TIMING_6), // Wing Commander III (US) (Disc 3 of 4)
                                 //@"000500001c8fab6a" : @(FIX_BIT_TIMING_6), // Wing Commander III (EU-US) (Disc 4 of 4)
                                 //@"000500002f517924" : @(FIX_BIT_TIMING_6), // Wing Commander III (US) (Disc 4 of 4)
                                 //@"000500000d073a51" : @(FIX_BIT_TIMING_7), // The Horde (EU-US) - hack seems to make things worse, audio skips but FMV is smooth
                                 //@"000500001cdf59f6" : @(FIX_BIT_TIMING_7), // The Horde (JP) - hack seems to make things worse, audio skips but FMV is smooth
                                 //@"00050000148ac2b2" : @(FIX_BIT_TIMING_7), // The Horde (US) - hack seems to make things worse, audio skips but FMV is smooth
                                 //@"00042c002fee388c" : @(FIX_BIT_GRAPHICS_STEP_Y), // Samurai Shodown (JP) - unneeded?
                                 @"0003b6003b6ab18c" : @(FIX_BIT_GRAPHICS_STEP_Y) // Samurai Shodown (EU-US) - fixes backgrounds
                                  };

    for (id hex in checkBytes) {
        /// Convert string of hex to byte array
        char buf[3];
        buf[2] = '\0';
        unsigned char *bytes = (unsigned char *)malloc([hex length]/2);
        unsigned char *bp = bytes;
        for (int i = 0; i < [hex length]; i += 2) {
            buf[0] = [hex characterAtIndex:i];
            buf[1] = [hex characterAtIndex:i+1];
            *bp++ = strtol(buf, NULL, 16);
        }

        dataCompare = [NSData dataWithBytesNoCopy:bytes length:[hex length]/2 freeWhenDone:YES];

        /// Apply found FIX_BIT_* hack
        if ([dataTrackBuffer isEqualToData:dataCompare])
            _freedo_Interface(FDP_SET_FIX_MODE, (void*)[checkBytes[hex] integerValue]);
    }

    return YES;
}

- (void)executeFrame
{
    _freedo_Interface(FDP_DO_EXECFRAME, frame); // FDP_DO_EXECFRAME_MT ?
}

- (void)resetEmulation
{
    // looks like libfreedo cannot do this :|
}

- (void)stopEmulation
{
    if(self.loaded) {
        // save NVRAM file
        NSString *extensionlessFilename = [[self.romName lastPathComponent] stringByDeletingPathExtension];
        NSString *batterySavesDirectory = [self batterySavesPath];

        if([batterySavesDirectory length] != 0) {
            [[NSFileManager defaultManager] createDirectoryAtPath:batterySavesDirectory
                                      withIntermediateDirectories:YES
                                                       attributes:nil
                                                            error:NULL];

            NSString *fileName = [extensionlessFilename stringByAppendingPathExtension:@"sav"];
            NSString *filePath = [batterySavesDirectory stringByAppendingPathComponent:fileName];

            writeSaveFile([filePath UTF8String]);
        }

        _freedo_Interface(FDP_DESTROY, (void*)0);
        self.loaded = NO;
    }
    if (chdFile) {
        chd_close(chdFile);
        chdFile = NULL;
    }
    if (chdHunkBuffer) {
        free(chdHunkBuffer);
        chdHunkBuffer = NULL;
    }
    chdCachedHunkIndex = -1;
    if (isoStream) {
        [isoStream closeFile];
        isoStream = nil;
    }
    [super stopEmulation];
}

- (NSTimeInterval)frameInterval
{
    return 60;
}

- (void)readSector:(uint)sectorNumber toBuffer:(uint8_t*)buffer
{
    if (buffer == NULL) {
        return;
    }
    if (chdFile) {
        int64_t rel = (int64_t)sectorNumber - (int64_t)chdTrackLBA + (int64_t)chdTrackFileOffset;
        if (rel < 0 || rel >= (int64_t)chdTotalFrames || rel > (int64_t)UINT32_MAX) {
            memset(buffer, 0, 2048);
            return;
        }
        uint8_t frame[2448];
        chd_error ce = [self readCHDFrameAtCAD:(uint32_t)rel buffer:frame];
        if (ce != CHDERR_NONE) {
            memset(buffer, 0, 2048);
            return;
        }
        if (isoMode == MODE_MODE1_RAW) {
            memcpy(buffer, frame + 16, 2048);
        } else {
            memcpy(buffer, frame, 2048);
        }
        return;
    }
    if (isoStream == nil) {
        memset(buffer, 0, 2048);
        return;
    }
    if(isoMode==MODE_MODE1_RAW)
    {
        [isoStream seekToFileOffset:2352 * sectorNumber + 0x10];
    }
    else
    {
        [isoStream seekToFileOffset:2048 * sectorNumber];
    }
    NSData *data = [isoStream readDataOfLength:2048];
    if (data.length < 2048 || data.bytes == NULL) {
        memset(buffer, 0, 2048);
        return;
    }
    memcpy(buffer, [data bytes], 2048);
}

#pragma mark Video
- (void *)getVideoBufferWithHint:(void *)hint
{
    if(!hint) {
        hint = videoBuffer;
    }

    if(isSwapFrameSignaled)
    {
        isSwapFrameSignaled = NO;
        struct BitmapCrop bmpcrop;
        #warning("TODO: Expose this as a core option")
        ScalingAlgorithm sca = FreeDOGameCoreOptions.scalingAlgorithm;
        int rw, rh;
        Get_Frame_Bitmap((VDLFrame *)frame, hint, 0, &bmpcrop, videoWidth, videoHeight, false, true, false, sca, &rw, &rh);
    }
    return videoBuffer;
}

- (void)swapBuffers {
    if (self->videoBuffer == self->videoBufferA) {
        self->videoBuffer = self->videoBufferB;
    } else {
        self->videoBuffer = self->videoBufferA;
    }
}

-(BOOL)isDoubleBuffered {
    return NO;
}

- (CGRect)screenRect {
    return CGRectMake(0, 0, videoWidth, videoHeight);
}

- (CGSize)aspectSize {
    return CGSizeMake(videoWidth, videoHeight);
}

- (CGSize)bufferSize {
    return CGSizeMake(videoWidth, videoHeight);
}

- (GLenum)pixelFormat {
    return GL_RGBA;
}

- (GLenum)internalPixelFormat {
    return GL_RGBA;
}

- (GLenum)pixelType {
    return GL_UNSIGNED_BYTE;
}

- (void *)videoBuffer {
    return [self getVideoBufferWithHint:nil];
}

#pragma mark - Audio
- (double)audioSampleRate {
    return 44100;
}

- (NSUInteger)channelCount {
    return 2;
}

#pragma mark - Save States

- (void)saveStateToFileAtPath:(NSString *)fileName completionHandler:(void (^)(NSError * __nullable))block {
    size_t size = (uintptr_t)_freedo_Interface(FDP_GET_SAVE_SIZE, (void*)0);

    NSMutableData *data = [NSMutableData dataWithLength:size];
    _freedo_Interface(FDP_DO_SAVE, data.mutableBytes);
    ILOG(@"Game saved, length in bytes: %lu", data.length);

    NSError *error;
    BOOL didSucceed = [data writeToFile:fileName options:0 error:&error];
    if (error) {
        block(error);
    } else {
        block(nil);
    }
}

- (void)loadStateFromFileAtPath:(NSString *)fileName completionHandler:(void (^)(NSError * __nullable))block {
    NSError *error;
    NSData *saveData = [NSData dataWithContentsOfFile:fileName
                                              options:0 error:&error];
    if(error) {
        block(error);
    }

    if (!saveData) {
        NSError *error = [NSError errorWithDomain:CoreError.PVEmulatorCoreErrorDomain
                                             code:PVEmulatorCoreErrorCodeCouldNotLoadState
                                         userInfo:@{NSLocalizedDescriptionKey: @"Save data was empty or unreadable."}];

        block(error);
        return;
    }

    BOOL succeeded = (_freedo_Interface(FDP_DO_LOAD, (void *)saveData.bytes) != NULL);

    if(!succeeded) {
        NSError *error = [NSError errorWithDomain:CoreError.PVEmulatorCoreErrorDomain
                                             code:PVEmulatorCoreErrorCodeCouldNotLoadState
                                         userInfo:@{NSLocalizedDescriptionKey: @"FreeDo could not load the save state."}];
        block(error);
    } else {
        block(nil);
    }
}

#pragma mark - Input

- (void)updateControllers
{
    if ([self.controller1 extendedGamepad])
    {
        GCExtendedGamepad *gamepad = [self.controller1 extendedGamepad];
        GCControllerDirectionPad *dpad = [gamepad dpad];

        (dpad.up.isPressed || gamepad.leftThumbstick.up.isPressed) ? internal_input_state[0].buttons|=INPUTBUTTONUP : internal_input_state[0].buttons&=~INPUTBUTTONUP;
        (dpad.down.isPressed || gamepad.leftThumbstick.down.isPressed) ? internal_input_state[0].buttons|=INPUTBUTTONDOWN : internal_input_state[0].buttons&=~INPUTBUTTONDOWN;
        (dpad.left.isPressed || gamepad.leftThumbstick.left.isPressed) ? internal_input_state[0].buttons|=INPUTBUTTONLEFT : internal_input_state[0].buttons&=~INPUTBUTTONLEFT;
        (dpad.right.isPressed || gamepad.leftThumbstick.right.isPressed) ? internal_input_state[0].buttons|=INPUTBUTTONRIGHT : internal_input_state[0].buttons&=~INPUTBUTTONRIGHT;

        (gamepad.buttonA.isPressed) ? internal_input_state[0].buttons|=INPUTBUTTONA : internal_input_state[0].buttons&=~INPUTBUTTONA;
        (gamepad.buttonB.isPressed) ? internal_input_state[0].buttons|=INPUTBUTTONB : internal_input_state[0].buttons&=~INPUTBUTTONB;
        (gamepad.buttonY.isPressed) ? internal_input_state[0].buttons|=INPUTBUTTONC : internal_input_state[0].buttons&=~INPUTBUTTONC;

        (gamepad.leftShoulder.isPressed) ? internal_input_state[0].buttons|=INPUTBUTTONL : internal_input_state[0].buttons&=~INPUTBUTTONL;
        (gamepad.rightShoulder.isPressed) ? internal_input_state[0].buttons|=INPUTBUTTONR : internal_input_state[0].buttons&=~INPUTBUTTONR;

        (gamepad.leftTrigger.isPressed) ? internal_input_state[0].buttons|=INPUTBUTTONX : internal_input_state[0].buttons&=~INPUTBUTTONX;
        (gamepad.rightTrigger.isPressed) ? internal_input_state[0].buttons|=INPUTBUTTONP : internal_input_state[0].buttons&=~INPUTBUTTONP;

    }
}
- (void)didPush3DOButton:(PV3DOButton)button forPlayer:(NSInteger)player {
    player--;

    switch(button)
    {
        case PV3DOButtonA:
            internal_input_state[0].buttons|=INPUTBUTTONA;
            break;
        case PV3DOButtonB:
            internal_input_state[0].buttons|=INPUTBUTTONB;
            break;
        case PV3DOButtonC:
            internal_input_state[0].buttons|=INPUTBUTTONC;
            break;
        case PV3DOButtonX:
            internal_input_state[0].buttons|=INPUTBUTTONX;
            break;
        case PV3DOButtonP:
            internal_input_state[0].buttons|=INPUTBUTTONP;
            break;
        case PV3DOButtonLeft:
            internal_input_state[0].buttons|=INPUTBUTTONLEFT;
            break;
        case PV3DOButtonRight:
            internal_input_state[0].buttons|=INPUTBUTTONRIGHT;
            break;
        case PV3DOButtonUp:
            internal_input_state[0].buttons|=INPUTBUTTONUP;
            break;
        case PV3DOButtonDown:
            internal_input_state[0].buttons|=INPUTBUTTONDOWN;
            break;
        case PV3DOButtonL:
            internal_input_state[0].buttons|=INPUTBUTTONL;
            break;
        case PV3DOButtonR:
            internal_input_state[0].buttons|=INPUTBUTTONR;
            break;

        default:
            break;
    }
}

- (void)didRelease3DOButton:(PV3DOButton)button forPlayer:(NSInteger)player {
    player--;

    switch(button)
    {
        case PV3DOButtonA:
            internal_input_state[0].buttons&=~INPUTBUTTONA;
            break;
        case PV3DOButtonB:
            internal_input_state[0].buttons&=~INPUTBUTTONB;
            break;
        case PV3DOButtonC:
            internal_input_state[0].buttons&=~INPUTBUTTONC;
            break;
        case PV3DOButtonX:
            internal_input_state[0].buttons&=~INPUTBUTTONX;
            break;
        case PV3DOButtonP:
            internal_input_state[0].buttons&=~INPUTBUTTONP;
            break;
        case PV3DOButtonLeft:
            internal_input_state[0].buttons&=~INPUTBUTTONLEFT;
            break;
        case PV3DOButtonRight:
            internal_input_state[0].buttons&=~INPUTBUTTONRIGHT;
            break;
        case PV3DOButtonUp:
            internal_input_state[0].buttons&=~INPUTBUTTONUP;
            break;
        case PV3DOButtonDown:
            internal_input_state[0].buttons&=~INPUTBUTTONDOWN;
            break;
        case PV3DOButtonL:
            internal_input_state[0].buttons&=~INPUTBUTTONL;
            break;
        case PV3DOButtonR:
            internal_input_state[0].buttons&=~INPUTBUTTONR;
            break;

        default:
            break;
    }
}

#pragma mark - FreeDoInterface
//TODO: investigate these
//-(void*)fdcGetPointerRAM
//{
//    return [self _freedoActionWithInterfaceFunction:FDP_GETP_RAMS datum:(void*)0];
//}
//
//-(void*)fdcGetPointerROM
//{
//    return [self _freedoActionWithInterfaceFunction:FDP_GETP_ROMS datum:(void*)0];
//}
//
//-(void*)fdcGetPointerProfile
//{
//    return [self _freedoActionWithInterfaceFunction:FDP_GETP_PROFILE datum:(void*)0];
//}
//
//-(void)fdcDoExecuteFrameMultitask:(void*)vdlFrame
//{
//    [self _freedoActionWithInterfaceFunction:FDP_DO_EXECFRAME_MT datum:vdlFrame];
//}
//
//-(void*)fdcSetArmClock:(int)clock
//{
//    //untested!
//    return [self _freedoActionWithInterfaceFunction:FDP_SET_ARMCLOCK datum:(void*) clock];
//}
//
//-(void*)fdcSetFixMode:(int)fixMode
//{
//    return [self _freedoActionWithInterfaceFunction:FDP_SET_FIX_MODE datum:(void*) fixMode];
//}

#pragma mark - Helpers

- (void)initVideo {
    //HightResMode = 1;
    videoWidth = 320;
    videoHeight = 240;
    frame = (VDLFrame*)malloc(sizeof(VDLFrame));
    memset(frame, 0, sizeof(VDLFrame));
}

- (void)loadBIOSes {
    NSString *rom1Path = [[self BIOSPath] stringByAppendingPathComponent:@"panafz10.bin"];
    NSData *data = [NSData dataWithContentsOfFile:rom1Path];
    NSUInteger len = [data length];
    assert(len==ROM1_SIZE);
    biosRom1Copy = (unsigned char *)malloc(len);
    memcpy(biosRom1Copy, [data bytes], len);

    //there's supposed to be a 3rd BIOS here, so add that later

    // "ROM 2 Japanese Character ROM" / Set it if we find it. It's not requiered for some JPN games. We still have to init the memory tho
    NSString *rom2Path = [[self BIOSPath] stringByAppendingPathComponent:@"rom2.rom"];
    data = [NSData dataWithContentsOfFile:rom2Path];
    if(data) {
        len = [data length];
        assert(len==ROM2_SIZE);
        biosRom2Copy = (unsigned char *)malloc(len);
        memcpy(biosRom2Copy, [data bytes], len);
    } else {
        biosRom2Copy = (unsigned char *)malloc(len);
        memset(biosRom2Copy, 0, len);
    }
}

int CheckDownButton(int deviceNumber,int button) {
    if(internal_input_state[deviceNumber].buttons&button)
        return 1;
    else
        return 0;
}

char CalculateDeviceLowByte(int deviceNumber) {
    char returnValue = 0;

    returnValue |= 0x01 & 0; // unknown
    returnValue |= 0x02 & 0; // unknown
    returnValue |= CheckDownButton(deviceNumber, INPUTBUTTONL) ? (char)0x04 : (char)0;
    returnValue |= CheckDownButton(deviceNumber, INPUTBUTTONR) ? (char)0x08 : (char)0;
    returnValue |= CheckDownButton(deviceNumber, INPUTBUTTONX) ? (char)0x10 : (char)0;
    returnValue |= CheckDownButton(deviceNumber, INPUTBUTTONP) ? (char)0x20 : (char)0;
    returnValue |= CheckDownButton(deviceNumber, INPUTBUTTONC) ? (char)0x40 : (char)0;
    returnValue |= CheckDownButton(deviceNumber, INPUTBUTTONB) ? (char)0x80 : (char)0;

    return returnValue;
}

char CalculateDeviceHighByte(int deviceNumber)
{
    char returnValue = 0;

    returnValue |= CheckDownButton(deviceNumber, INPUTBUTTONA)     ? (char)0x01 : (char)0;
    returnValue |= CheckDownButton(deviceNumber, INPUTBUTTONLEFT)  ? (char)0x02 : (char)0;
    returnValue |= CheckDownButton(deviceNumber, INPUTBUTTONRIGHT) ? (char)0x04 : (char)0;
    returnValue |= CheckDownButton(deviceNumber, INPUTBUTTONUP)    ? (char)0x08 : (char)0;
    returnValue |= CheckDownButton(deviceNumber, INPUTBUTTONDOWN)  ? (char)0x10 : (char)0;
    returnValue |= 0x20 & 0; // unknown
    returnValue |= 0x40 & 0; // unknown
    returnValue |= 0x80; // This last bit seems to indicate power and/or connectivity.

    return returnValue;
}

static uint32_t reverseBytes(uint32_t value) {
    return (value & 0x000000FFU) << 24 | (value & 0x0000FF00U) << 8 | (value & 0x00FF0000U) >> 8 | (value & 0xFF000000U) >> 24;
}

@end

@interface PVFreeDOGameCoreBridge (PV3DOSystemResponderClient) <PV3DOSystemResponderClient>
@end
@implementation PVFreeDOGameCoreBridge (PV3DOSystemResponderClient)

#pragma mark - Input
- (void)didPush3DOButton:(PV3DOButton)button forPlayer:(NSInteger)player {
    player--;

    switch(button)
    {
        case PV3DOButtonA:
            internal_input_state[0].buttons|=INPUTBUTTONA;
            break;
        case PV3DOButtonB:
            internal_input_state[0].buttons|=INPUTBUTTONB;
            break;
        case PV3DOButtonC:
            internal_input_state[0].buttons|=INPUTBUTTONC;
            break;
        case PV3DOButtonX:
            internal_input_state[0].buttons|=INPUTBUTTONX;
            break;
        case PV3DOButtonP:
            internal_input_state[0].buttons|=INPUTBUTTONP;
            break;
        case PV3DOButtonLeft:
            internal_input_state[0].buttons|=INPUTBUTTONLEFT;
            break;
        case PV3DOButtonRight:
            internal_input_state[0].buttons|=INPUTBUTTONRIGHT;
            break;
        case PV3DOButtonUp:
            internal_input_state[0].buttons|=INPUTBUTTONUP;
            break;
        case PV3DOButtonDown:
            internal_input_state[0].buttons|=INPUTBUTTONDOWN;
            break;
        case PV3DOButtonL:
            internal_input_state[0].buttons|=INPUTBUTTONL;
            break;
        case PV3DOButtonR:
            internal_input_state[0].buttons|=INPUTBUTTONR;
            break;

        default:
            break;
    }
}

- (void)didRelease3DOButton:(PV3DOButton)button forPlayer:(NSInteger)player {
    player--;

    switch(button)
    {
        case PV3DOButtonA:
            internal_input_state[0].buttons&=~INPUTBUTTONA;
            break;
        case PV3DOButtonB:
            internal_input_state[0].buttons&=~INPUTBUTTONB;
            break;
        case PV3DOButtonC:
            internal_input_state[0].buttons&=~INPUTBUTTONC;
            break;
        case PV3DOButtonX:
            internal_input_state[0].buttons&=~INPUTBUTTONX;
            break;
        case PV3DOButtonP:
            internal_input_state[0].buttons&=~INPUTBUTTONP;
            break;
        case PV3DOButtonLeft:
            internal_input_state[0].buttons&=~INPUTBUTTONLEFT;
            break;
        case PV3DOButtonRight:
            internal_input_state[0].buttons&=~INPUTBUTTONRIGHT;
            break;
        case PV3DOButtonUp:
            internal_input_state[0].buttons&=~INPUTBUTTONUP;
            break;
        case PV3DOButtonDown:
            internal_input_state[0].buttons&=~INPUTBUTTONDOWN;
            break;
        case PV3DOButtonL:
            internal_input_state[0].buttons&=~INPUTBUTTONL;
            break;
        case PV3DOButtonR:
            internal_input_state[0].buttons&=~INPUTBUTTONR;
            break;

        default:
            break;
    }
}

@end
