//
//  SystemAudio.m
//  System Audio
//
//  Created by Theodore Dubois on 4/29/21.
//

#import <CoreAudio/AudioServerPlugIn.h>
#import <CoreAudio/AudioHardware.h>
#import <Foundation/Foundation.h>
#import <Accelerate/Accelerate.h>
#import <stdatomic.h>
#import "SystemAudio.h"
#import "AudioContext.h"

#define FourCCToCString(c) (char[]){ (char)((c)>>24), (char)((c)>>16), (char)((c)>>8), (char)(c), 0 }

static HRESULT SystemAudio_QueryInterface(void *inDriver, REFIID inUUID, LPVOID *outInterface);
static ULONG SystemAudio_AddRef(void *inDriver);
static ULONG SystemAudio_Release(void *inDriver);
static OSStatus SystemAudio_Initialize(AudioServerPlugInDriverRef inDriver, AudioServerPlugInHostRef inHost);
static OSStatus SystemAudio_CreateDevice(AudioServerPlugInDriverRef inDriver, CFDictionaryRef inDescription, const AudioServerPlugInClientInfo *inClientInfo, AudioObjectID *outDeviceObjectID);
static OSStatus SystemAudio_DestroyDevice(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID);
static OSStatus SystemAudio_AddDeviceClient(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, const AudioServerPlugInClientInfo *inClientInfo);
static OSStatus SystemAudio_RemoveDeviceClient(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, const AudioServerPlugInClientInfo *inClientInfo);
static OSStatus SystemAudio_PerformDeviceConfigurationChange(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt64 inChangeAction, void *inChangeInfo);
static OSStatus SystemAudio_AbortDeviceConfigurationChange(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt64 inChangeAction, void *inChangeInfo);
static Boolean SystemAudio_HasProperty(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress *inAddress);
static OSStatus SystemAudio_IsPropertySettable(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress *inAddress, Boolean *outIsSettable);
static OSStatus SystemAudio_GetPropertyDataSize(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress *inAddress, UInt32 inQualifierDataSize, const void *inQualifierData, UInt32 *outDataSize);
static OSStatus SystemAudio_GetPropertyData(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress *inAddress, UInt32 inQualifierDataSize, const void *inQualifierData, UInt32 inDataSize, UInt32 *outDataSize, void *outData);
static OSStatus SystemAudio_SetPropertyData(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress *inAddress, UInt32 inQualifierDataSize, const void *inQualifierData, UInt32 inDataSize, const void *inData);
static OSStatus SystemAudio_StartIO(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID);
static OSStatus SystemAudio_StopIO(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID);
static OSStatus SystemAudio_GetZeroTimeStamp(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID, Float64 *outSampleTime, UInt64 *outHostTime, UInt64 *outSeed);
static OSStatus SystemAudio_WillDoIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID, UInt32 inOperationID, Boolean *outWillDo, Boolean *outWillDoInPlace);
static OSStatus SystemAudio_BeginIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID, UInt32 inOperationID, UInt32 inIOBufferFrameSize, const AudioServerPlugInIOCycleInfo *inIOCycleInfo);
static OSStatus SystemAudio_DoIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, AudioObjectID inStreamObjectID, UInt32 inClientID, UInt32 inOperationID, UInt32 inIOBufferFrameSize, const AudioServerPlugInIOCycleInfo *inIOCycleInfo, void *ioMainBuffer, void *ioSecondaryBuffer);
static OSStatus SystemAudio_EndIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID, UInt32 inOperationID, UInt32 inIOBufferFrameSize, const AudioServerPlugInIOCycleInfo *inIOCycleInfo);
static AudioServerPlugInDriverInterface vtable = {
    NULL,
    SystemAudio_QueryInterface,
    SystemAudio_AddRef,
    SystemAudio_Release,
    SystemAudio_Initialize,
    SystemAudio_CreateDevice,
    SystemAudio_DestroyDevice,
    SystemAudio_AddDeviceClient,
    SystemAudio_RemoveDeviceClient,
    SystemAudio_PerformDeviceConfigurationChange,
    SystemAudio_AbortDeviceConfigurationChange,
    SystemAudio_HasProperty,
    SystemAudio_IsPropertySettable,
    SystemAudio_GetPropertyDataSize,
    SystemAudio_GetPropertyData,
    SystemAudio_SetPropertyData,
    SystemAudio_StartIO,
    SystemAudio_StopIO,
    SystemAudio_GetZeroTimeStamp,
    SystemAudio_WillDoIOOperation,
    SystemAudio_BeginIOOperation,
    SystemAudio_DoIOOperation,
    SystemAudio_EndIOOperation,
};
static AudioServerPlugInDriverInterface *vtable_ptr = &vtable;
static AudioServerPlugInDriverRef driver = &vtable_ptr;
void *SystemAudio_Create(CFAllocatorRef allocator, CFUUIDRef requested_uuid) {
    NSLog(@"systemaudio create!");
    if (CFEqual(requested_uuid, kAudioServerPlugInTypeUUID))
        return driver;
    return NULL;
}

static HRESULT SystemAudio_QueryInterface(void *inDriver, REFIID inUUID, LPVOID *outInterface) {
    CFUUIDRef uuid = CFUUIDCreateFromUUIDBytes(NULL, inUUID);
    if (CFEqual(uuid, IUnknownUUID) || CFEqual(uuid, kAudioServerPlugInDriverInterfaceUUID)) {
        CFRelease(uuid);
        *outInterface = driver;
        return 0;
    }
    CFRelease(uuid);
    return E_NOINTERFACE;
}

static Float64 mach_ticks_per_second;
static const int sample_rate = 48000;
static const int frames_per_zero_timestamp = 16384;

static OSStatus SystemAudio_Initialize(AudioServerPlugInDriverRef inDriver, AudioServerPlugInHostRef inHost) {
    OSStatus err = initialize_hooks(inHost->PropertiesChanged);
    if (err != kAudioHardwareNoError)
        return err;
    struct mach_timebase_info timebase_info;
    mach_timebase_info(&timebase_info);
    mach_ticks_per_second = 1000000000. * timebase_info.denom / timebase_info.numer;
    return kAudioHardwareNoError;
}

// lol
static ULONG SystemAudio_AddRef(void *inDriver) {
    return 1;
}
static ULONG SystemAudio_Release(void *inDriver) {
    return 1;
}

struct AudioObject;
struct AudioPropertyDesc {
    int prop;
    int scope;
    void *value;
    UInt32 value_size;
    OSStatus (*custom_get)(struct AudioObject *obj, UInt32 *size_inout, void *value_out);
};
struct AudioObject {
    struct AudioPropertyDesc *properties;
};
#define value(v) \
.value = &(v), .value_size = sizeof(v)
#define arr(t, ...) ((t[]){__VA_ARGS__})
#define v(t, ...) value(arr(t, ##__VA_ARGS__))

static const int kAudioObject_Device = 2;
static const int kAudioObject_InputStream = 3;

struct AudioObject pluginObject = {
    .properties = (struct AudioPropertyDesc[]) {
        {kAudioObjectPropertyClass, v(AudioClassID, kAudioPlugInClassID)},
        {kAudioPlugInPropertyDeviceList, v(AudioObjectID, kAudioObject_Device)},
        {},
    },
};

struct AudioObject deviceObject = {
    .properties = (struct AudioPropertyDesc[]) {
        {kAudioObjectPropertyClass, v(AudioClassID, kAudioDeviceClassID)},
        {kAudioDevicePropertyDeviceNameCFString, v(CFStringRef, CFSTR("System Audio"))},
        {kAudioDevicePropertyDeviceUID, v(CFStringRef, CFSTR("System Audio but we pretend to be SoundFlower so OBS recognizes this as a system output device"))},
        {kAudioObjectPropertyControlList, v(AudioObjectID)},
        {kAudioDevicePropertyStreams, .scope = kAudioObjectPropertyScopeOutput, v(AudioObjectID)},
        {kAudioDevicePropertyStreams, .scope = kAudioObjectPropertyScopeInput, v(AudioObjectID, kAudioObject_InputStream)},
        {kAudioDevicePropertyNominalSampleRate, v(Float64, sample_rate)},
        {kAudioDevicePropertyNominalSampleRate, .scope = kAudioObjectPropertyScopeInput, v(Float64, sample_rate)},
        {kAudioDevicePropertyZeroTimeStampPeriod, v(UInt32, frames_per_zero_timestamp)},
        {kAudioDevicePropertySafetyOffset, .scope = kAudioObjectPropertyScopeOutput, v(UInt32, 0)},
        {kAudioDevicePropertySafetyOffset, .scope = kAudioObjectPropertyScopeInput, v(UInt32, 0)},
        {kAudioDevicePropertyLatency, .scope = kAudioObjectPropertyScopeOutput, v(UInt32, 0)},
        {kAudioDevicePropertyLatency, .scope = kAudioObjectPropertyScopeInput, v(UInt32, 0)},
        {kAudioDevicePropertyTransportType, v(UInt32, kAudioDeviceTransportTypeVirtual)},
        {kAudioDevicePropertyIsHidden, v(UInt32, 0)},
        {kAudioObjectPropertyName, v(CFStringRef, CFSTR("System Audio"))},
        {},
    },
};

static AudioStreamRangedDescription inputStreamFormats[1] = {{
    .mFormat = {
        .mSampleRate = sample_rate,
        .mFormatID = kAudioFormatLinearPCM,
        .mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagsNativeEndian | kAudioFormatFlagIsPacked,
        .mBytesPerPacket = 8,
        .mFramesPerPacket = 1,
        .mBytesPerFrame = 8,
        .mChannelsPerFrame = 2,
        .mBitsPerChannel = 32,
    },
    .mSampleRateRange = {
        .mMinimum = sample_rate,
        .mMaximum = sample_rate,
    },
}};
struct AudioObject inputStreamObject = {
    .properties = (struct AudioPropertyDesc[]) {
        {kAudioStreamPropertyAvailablePhysicalFormats, value(inputStreamFormats)},
        {kAudioStreamPropertyStartingChannel, v(UInt32, 1)},
        {kAudioStreamPropertyPhysicalFormat, value(inputStreamFormats[0].mFormat)},
        {kAudioStreamPropertyTerminalType, v(UInt32, kAudioStreamTerminalTypeLine)},
        {},
    },
};

static struct AudioObject *Object_GetByID(AudioObjectID objId) {
    switch (objId) {
        case kAudioObjectPlugInObject: return &pluginObject;
        case kAudioObject_Device: return &deviceObject;
        case kAudioObject_InputStream: return &inputStreamObject;
    }
    return NULL;
}
static struct AudioPropertyDesc *Object_GetPropertyDesc(struct AudioObject *obj, const AudioObjectPropertyAddress *prop) {
    for (int i = 0; obj->properties[i].prop != 0; i++) {
        if (obj->properties[i].prop != prop->mSelector)
            continue;
        int scope = obj->properties[i].scope;
        if (scope == 0)
            scope = kAudioObjectPropertyScopeGlobal;
        if (scope != prop->mScope)
            continue;
        return &obj->properties[i];
    }
    return NULL;
}

static Boolean SystemAudio_HasProperty(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress *inAddress) {
    struct AudioObject *obj = Object_GetByID(inObjectID);
    Boolean has = obj != NULL && Object_GetPropertyDesc(obj, inAddress) != NULL;
    if (!has) {
//        NSLog(@"%s %d %d %s,%s,%d ala a", __FUNCTION__, inObjectID, inClientProcessID, FourCCToCString(inAddress->mSelector), FourCCToCString(inAddress->mScope), inAddress->mElement);
    }
    return has;
}
static OSStatus SystemAudio_IsPropertySettable(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress *inAddress, Boolean *outIsSettable) {
//    NSLog(@"%s %d %d %s,%s,%d", __FUNCTION__, inObjectID, inClientProcessID, FourCCToCString(inAddress->mSelector), FourCCToCString(inAddress->mScope), inAddress->mElement);
    struct AudioObject *obj = Object_GetByID(inObjectID);
    if (obj == NULL)
        return kAudioHardwareBadObjectError;
    return kAudioHardwareUnknownPropertyError;
}
static OSStatus SystemAudio_GetPropertyDataSize(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress *inAddress, UInt32 inQualifierDataSize, const void *inQualifierData, UInt32 *outDataSize) {
    struct AudioObject *obj = Object_GetByID(inObjectID);
    if (obj == NULL)
        return kAudioHardwareBadObjectError;
    struct AudioPropertyDesc *prop = Object_GetPropertyDesc(obj, inAddress);
    if (prop == NULL) {
//        NSLog(@"%s %d %d %s,%s,%d ala a", __FUNCTION__, inObjectID, inClientProcessID, FourCCToCString(inAddress->mSelector), FourCCToCString(inAddress->mScope), inAddress->mElement);
        return kAudioHardwareUnknownPropertyError;
    }
    *outDataSize = prop->value_size;
    return kAudioHardwareNoError;
}
static OSStatus SystemAudio_GetPropertyData(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress *inAddress, UInt32 inQualifierDataSize, const void *inQualifierData, UInt32 inDataSize, UInt32 *outDataSize, void *outData) {
    struct AudioObject *obj = Object_GetByID(inObjectID);
    if (obj == NULL)
        return kAudioHardwareBadObjectError;
    struct AudioPropertyDesc *prop = Object_GetPropertyDesc(obj, inAddress);
    if (prop == NULL) {
//        NSLog(@"%s %d %d %s,%s,%d ala a", __FUNCTION__, inObjectID, inClientProcessID, FourCCToCString(inAddress->mSelector), FourCCToCString(inAddress->mScope), inAddress->mElement);
        return kAudioHardwareUnknownPropertyError;
    }
    if (inDataSize < prop->value_size)
            return kAudioHardwareBadPropertySizeError;
    *outDataSize = prop->value_size;
    memcpy(outData, prop->value, prop->value_size);
    return kAudioHardwareNoError;
}
static OSStatus SystemAudio_SetPropertyData(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress *inAddress, UInt32 inQualifierDataSize, const void *inQualifierData, UInt32 inDataSize, const void *inData) {
//    NSLog(@"%s %d %d %s,%s,%d", __FUNCTION__, inObjectID, inClientProcessID, FourCCToCString(inAddress->mSelector), FourCCToCString(inAddress->mScope), inAddress->mElement);
    struct AudioObject *obj = Object_GetByID(inObjectID);
    if (obj == NULL)
        return kAudioHardwareBadObjectError;
    return kAudioHardwareUnknownPropertyError;
}

static atomic_ulong io_count;
static _Atomic uint64_t io_start_mach_ticks;

static OSStatus SystemAudio_StartIO(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID) {
    unsigned long local_io_count = io_count;
    do {
        if (local_io_count + 1 < local_io_count)
            return kAudioHardwareIllegalOperationError;
        io_start_mach_ticks = mach_absolute_time();
    } while (atomic_compare_exchange_strong(&io_count, &local_io_count, local_io_count + 1));
    return 0;
}
static OSStatus SystemAudio_StopIO(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID) {
    io_count--;
    return 0;
}

bool is_input_running() {
    return io_count > 0;
}

static OSStatus SystemAudio_GetZeroTimeStamp(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID, Float64 *outSampleTime, UInt64 *outHostTime, UInt64 *outSeed) {
    uint64_t start = io_start_mach_ticks;
    uint64_t mach_ticks_since_start = mach_absolute_time() - start;
    Float64 mach_ticks_per_frame = mach_ticks_per_second / sample_rate;
    Float64 mach_ticks_per_zero_timestamp = mach_ticks_per_frame * frames_per_zero_timestamp;
    uint64_t cycle_count = (uint64_t) (mach_ticks_since_start / mach_ticks_per_zero_timestamp);
    *outSampleTime = cycle_count * frames_per_zero_timestamp;
    *outHostTime = start + cycle_count * mach_ticks_per_zero_timestamp;
    *outSeed = 1;
//    *outSampleTime /= 2;
//    NSLog(@"%s %f %llu", __FUNCTION__, *outSampleTime, *outHostTime);
    return kAudioHardwareNoError;
}

static OSStatus SystemAudio_WillDoIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID, UInt32 inOperationID, Boolean *outWillDo, Boolean *outWillDoInPlace) {
//    NSLog(@"%s", __FUNCTION__);
    switch (inOperationID) {
        case kAudioServerPlugInIOOperationReadInput:
            *outWillDo = true;
            *outWillDoInPlace = true;
            break;
        default:
            *outWillDo = false;
            *outWillDoInPlace = false;
            break;
    }
    return kAudioHardwareNoError;
}
static OSStatus SystemAudio_BeginIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID, UInt32 inOperationID, UInt32 inIOBufferFrameSize, const AudioServerPlugInIOCycleInfo *inIOCycleInfo) {
    return kAudioHardwareNoError;
}
static OSStatus SystemAudio_EndIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID, UInt32 inOperationID, UInt32 inIOBufferFrameSize, const AudioServerPlugInIOCycleInfo *inIOCycleInfo) {
    return kAudioHardwareNoError;
}

struct provide_func_context {
    TPCircularBuffer *ring;
    uint32_t byte_offset;
    uint32_t packet_size;
    uint32_t num_channels;
};

OSStatus ProvideInputDataFromContext(AudioConverterRef inAudioConverter, UInt32 *ioNumberDataPackets, AudioBufferList *ioData, AudioStreamPacketDescription * _Nullable *outDataPacketDescription, void *inUserData) {
    struct provide_func_context *ctx = inUserData;
    uint32_t getBytes = *ioNumberDataPackets * ctx->packet_size;
    uint32_t availableBytes;
    void *tail = TPCircularBufferTail(ctx->ring, &availableBytes);
    if (ctx->byte_offset > availableBytes) {
        availableBytes = 0;
    } else {
        tail += ctx->byte_offset;
        availableBytes -= ctx->byte_offset;
    }
    if (getBytes > availableBytes)
        getBytes = availableBytes;
    getBytes -= getBytes % ctx->packet_size;
    *ioNumberDataPackets = getBytes / ctx->packet_size;
    ioData->mNumberBuffers = 1;
    ioData->mBuffers[0].mData = tail;
    ioData->mBuffers[0].mDataByteSize = getBytes;
    ioData->mBuffers[0].mNumberChannels = ctx->num_channels;
//    NSLog(@"systemaudio ProvideInputDataFromContext numberdatapackets=%d data=%p databytesize=%d numberchannels=%d byteoffset=%d", *ioNumberDataPackets, ioData->mBuffers[0].mData, ioData->mBuffers[0].mDataByteSize, ioData->mBuffers[0].mNumberChannels, ctx->byte_offset);
    ctx->byte_offset += getBytes;
    return getBytes != 0 ? 0 : -1;
}

static OSStatus SystemAudio_DoIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, AudioObjectID inStreamObjectID, UInt32 inClientID, UInt32 inOperationID, UInt32 inIOBufferFrameSize, const AudioServerPlugInIOCycleInfo *inIOCycleInfo, void *ioMainBuffer, void *ioSecondaryBuffer) {
    if (inStreamObjectID != kAudioObject_InputStream)
        return kAudioHardwareBadObjectError;
//    NSLog(@"%s %u %u %llu %f %f %p", __FUNCTION__, inIOBufferFrameSize, inIOCycleInfo->mNominalIOBufferFrameSize, inIOCycleInfo->mIOCycleCounter, inIOCycleInfo->mInputTime.mSampleTime, inIOCycleInfo->mDeviceHostTicksPerFrame, ioMainBuffer);
    
    int channels = inputStreamFormats[0].mFormat.mChannelsPerFrame;
    uint32_t wantBytes = inIOBufferFrameSize * channels * sizeof(Float32);
    memset(ioMainBuffer, 0, wantBytes);
    
    static __thread void *tempBuffer;
    static __thread uint32_t tempBufferSize;
    if (tempBufferSize < wantBytes) {
        NSLog(@"systemaudio: mi suli %u e lipu pi tenpo lili", wantBytes);
        tempBufferSize = wantBytes;
        munmap(tempBuffer, tempBufferSize);
        tempBuffer = mmap(NULL, tempBufferSize, PROT_READ|PROT_WRITE, MAP_PRIVATE|MAP_ANONYMOUS, -1, 0);
    }
    
    // TODO: sync streams from the same device, or just, like, sync shit at all
    enumerate_contexts(^(AudioContext * _Nonnull ctx) {
        if (ctx->converter == NULL) {
            AudioStreamBasicDescription fmt = {
                .mSampleRate = ctx->sampleRate,
                .mFormatID = kAudioFormatLinearPCM,
                .mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagsNativeEndian | kAudioFormatFlagIsPacked,
                .mBytesPerPacket = sizeof(Float32) * ctx->stream0Channels,
                .mFramesPerPacket = 1,
                .mBytesPerFrame = sizeof(Float32) * ctx->stream0Channels,
                .mChannelsPerFrame = ctx->stream0Channels,
                .mBitsPerChannel = 32,
            };
            OSStatus err = AudioConverterNew(&fmt, &inputStreamFormats[0].mFormat, &ctx->converter);
            if (err != 0) {
                NSLog(@"systemaudio: pali pi ilo ante kalama li pakala ni: %d", err);
                return;
            }
        }
        
        AudioBufferList converterOut = {
            .mNumberBuffers = 1,
            .mBuffers = {
                {
                    .mNumberChannels = inputStreamFormats[0].mFormat.mChannelsPerFrame,
                    .mDataByteSize = wantBytes,
                    .mData = tempBuffer,
                },
            },
        };
        UInt32 packets = inIOBufferFrameSize;
        struct provide_func_context pctx = {
            .ring = &ctx->ring,
            .packet_size = sizeof(Float32) * ctx->stream0Channels,
            .num_channels = ctx->stream0Channels,
        };
        OSStatus err = AudioConverterFillComplexBuffer(ctx->converter, ProvideInputDataFromContext, &pctx, &packets, &converterOut, NULL);
        if (err != 0) {
            if (err != -1)
                NSLog(@"systemaudio: ante kalama li pakala ni: %d", err);
            return;
        }
        if (packets < inIOBufferFrameSize) {
            NSLog(@"systemaudio: pakala la kalama lili taso li kama tan ilo ante kalama! mi wile e kalama %u li jo e kalama %u", inIOBufferFrameSize, packets);
            return;
        }
        vDSP_vadd(tempBuffer, 1, ioMainBuffer, 1, ioMainBuffer, 1, packets * converterOut.mBuffers[0].mNumberChannels);
        TPCircularBufferConsume(&ctx->ring, pctx.byte_offset);
    });
    
//    // 1khz test tone
//    UInt32 time = inIOCycleInfo->mInputTime.mSampleTime;
//    Float32 (*buffer)[2] = ioMainBuffer;
//    for (size_t i = 0; i < inIOBufferFrameSize; i++) {
//        Float64 t = (Float64) time / sample_rate;
//        buffer[i][0] = buffer[i][1] = sin(2*M_PI * t*1000 * pow(pow(2, 1/12), inIOCycleInfo->mIOCycleCounter));
//        time++;
//    }
    return kAudioHardwareNoError;
}

static OSStatus SystemAudio_CreateDevice(AudioServerPlugInDriverRef inDriver, CFDictionaryRef inDescription, const AudioServerPlugInClientInfo *inClientInfo, AudioObjectID *outDeviceObjectID) {
    NSLog(@"%s", __FUNCTION__);
    return kAudioHardwareUnsupportedOperationError;
}
static OSStatus SystemAudio_DestroyDevice(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID) {
    NSLog(@"%s", __FUNCTION__);
    return kAudioHardwareUnsupportedOperationError;
}
static OSStatus SystemAudio_AddDeviceClient(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, const AudioServerPlugInClientInfo *inClientInfo) {
    NSLog(@"%s", __FUNCTION__);
    return kAudioHardwareUnsupportedOperationError;
}
static OSStatus SystemAudio_RemoveDeviceClient(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, const AudioServerPlugInClientInfo *inClientInfo) {
    NSLog(@"%s", __FUNCTION__);
    return kAudioHardwareUnsupportedOperationError;
}
static OSStatus SystemAudio_PerformDeviceConfigurationChange(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt64 inChangeAction, void *inChangeInfo) {
    NSLog(@"%s", __FUNCTION__);
    return kAudioHardwareUnsupportedOperationError;
}
static OSStatus SystemAudio_AbortDeviceConfigurationChange(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt64 inChangeAction, void *inChangeInfo) {
    NSLog(@"%s", __FUNCTION__);
    return kAudioHardwareUnsupportedOperationError;
}
