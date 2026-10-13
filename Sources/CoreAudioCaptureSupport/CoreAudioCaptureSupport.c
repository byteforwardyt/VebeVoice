#include "include/CoreAudioCaptureSupport.h"

#include <dispatch/dispatch.h>
#include <limits.h>
#include <mach/mach_time.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>

// 64 hardware cycles provides ample scheduling headroom while keeping the
// realtime producer strictly allocation-free.
#define VV_RING_CAPACITY 64u
#define VV_MAX_FRAMES_PER_PACKET 8192u

typedef struct {
    float samples[VV_MAX_FRAMES_PER_PACKET];
    uint32_t frameCount;
    uint64_t inputHostTime;
    int64_t inputSampleTime;
    uint64_t sequence;
} VVPacketSlot;

typedef struct {
    AudioObjectID deviceID;
    AudioDeviceIOProcID ioProcID;
    AudioStreamBasicDescription format;
    uint32_t bufferFrameSize;
    uint32_t bytesPerSample;
    dispatch_semaphore_t packetSemaphore;
    _Atomic uint64_t writeIndex;
    _Atomic uint64_t readIndex;
    _Atomic uint64_t droppedPackets;
    _Atomic bool running;
    VVPacketSlot slots[VV_RING_CAPACITY];
} VVCapture;

static OSStatus vv_get_input_stream_format(
    AudioObjectID deviceID,
    AudioStreamBasicDescription *format
) {
    AudioObjectPropertyAddress streamsAddress = {
        kAudioDevicePropertyStreams,
        kAudioObjectPropertyScopeInput,
        kAudioObjectPropertyElementMain,
    };
    UInt32 streamsSize = 0;
    OSStatus status = AudioObjectGetPropertyDataSize(
        deviceID,
        &streamsAddress,
        0,
        NULL,
        &streamsSize
    );
    if (status != noErr || streamsSize != sizeof(AudioStreamID)) {
        // Multiple independent input streams can have different formats. Let
        // AVAudioEngine handle those uncommon devices instead of guessing.
        return status != noErr ? status : kAudioHardwareUnsupportedOperationError;
    }

    AudioStreamID streamID = kAudioObjectUnknown;
    status = AudioObjectGetPropertyData(
        deviceID,
        &streamsAddress,
        0,
        NULL,
        &streamsSize,
        &streamID
    );
    if (status != noErr || streamID == kAudioObjectUnknown) {
        return status != noErr ? status : kAudioHardwareBadObjectError;
    }

    AudioObjectPropertyAddress formatAddress = {
        kAudioStreamPropertyVirtualFormat,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain,
    };
    UInt32 formatSize = sizeof(*format);
    return AudioObjectGetPropertyData(
        streamID,
        &formatAddress,
        0,
        NULL,
        &formatSize,
        format
    );
}

static OSStatus vv_get_buffer_frame_size(AudioObjectID deviceID, uint32_t *frameSize) {
    AudioObjectPropertyAddress address = {
        kAudioDevicePropertyBufferFrameSize,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain,
    };
    UInt32 size = sizeof(*frameSize);
    return AudioObjectGetPropertyData(deviceID, &address, 0, NULL, &size, frameSize);
}

static bool vv_format_is_supported(
    const AudioStreamBasicDescription *format,
    uint32_t *bytesPerSample
) {
    if (format->mFormatID != kAudioFormatLinearPCM ||
        format->mSampleRate <= 0.0 ||
        format->mChannelsPerFrame == 0 ||
        format->mBytesPerFrame == 0 ||
        (format->mFormatFlags & kAudioFormatFlagIsBigEndian) != 0) {
        return false;
    }

    const bool nonInterleaved =
        (format->mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0;
    const uint32_t channelDivisor = nonInterleaved ? 1u : format->mChannelsPerFrame;
    if (channelDivisor == 0 || format->mBytesPerFrame % channelDivisor != 0) {
        return false;
    }

    const uint32_t sampleBytes = format->mBytesPerFrame / channelDivisor;
    const bool isFloat = (format->mFormatFlags & kAudioFormatFlagIsFloat) != 0;
    const bool isSignedInteger =
        (format->mFormatFlags & kAudioFormatFlagIsSignedInteger) != 0;
    const bool isPacked = (format->mFormatFlags & kAudioFormatFlagIsPacked) != 0;

    if (isFloat && format->mBitsPerChannel == 32 && sampleBytes == sizeof(float)) {
        *bytesPerSample = sampleBytes;
        return true;
    }
    if (isSignedInteger && isPacked &&
        ((format->mBitsPerChannel == 16 && sampleBytes == 2) ||
         (format->mBitsPerChannel == 24 && sampleBytes == 3) ||
         (format->mBitsPerChannel == 32 && sampleBytes == 4))) {
        *bytesPerSample = sampleBytes;
        return true;
    }
    return false;
}

static inline float vv_read_sample(
    const uint8_t *bytes,
    const AudioStreamBasicDescription *format
) {
    if ((format->mFormatFlags & kAudioFormatFlagIsFloat) != 0) {
        float sample;
        memcpy(&sample, bytes, sizeof(sample));
        return sample;
    }

    switch (format->mBitsPerChannel) {
    case 16: {
        int16_t sample;
        memcpy(&sample, bytes, sizeof(sample));
        return (float) sample / 32768.0f;
    }
    case 24: {
        int32_t sample =
            ((int32_t) bytes[0]) |
            ((int32_t) bytes[1] << 8) |
            ((int32_t) bytes[2] << 16);
        if ((sample & 0x00800000) != 0) {
            sample |= (int32_t) 0xFF000000;
        }
        return (float) sample / 8388608.0f;
    }
    case 32: {
        int32_t sample;
        memcpy(&sample, bytes, sizeof(sample));
        return (float) ((double) sample / 2147483648.0);
    }
    default:
        return 0.0f;
    }
}

uint32_t vv_core_audio_buffer_bytes_per_frame(
    uint32_t bytesPerSample,
    uint32_t channelCount
) {
    if (bytesPerSample == 0 || channelCount == 0 ||
        bytesPerSample > UINT32_MAX / channelCount) {
        return 0;
    }
    return bytesPerSample * channelCount;
}

uint32_t vv_core_audio_buffer_frame_count(
    uint32_t dataByteSize,
    uint32_t bytesPerSample,
    uint32_t channelCount
) {
    const uint32_t bytesPerFrame =
        vv_core_audio_buffer_bytes_per_frame(bytesPerSample, channelCount);
    return bytesPerFrame == 0 ? 0 : dataByteSize / bytesPerFrame;
}

static uint32_t vv_frame_count(
    const VVCapture *capture,
    const AudioBufferList *inputData
) {
    uint32_t frameCount = UINT_MAX;
    const AudioBuffer *buffers = inputData->mBuffers;
    for (UInt32 index = 0; index < inputData->mNumberBuffers; ++index) {
        const AudioBuffer *buffer = &buffers[index];
        if (buffer->mData == NULL || buffer->mDataByteSize == 0) {
            continue;
        }
        // Derive the stride from the actual AudioBuffer layout. Core Audio can
        // expose one buffer per channel even when the device's virtual ASBD
        // temporarily reports the stream-wide interleaved byte stride during
        // a route change. Using ASBD.mBytesPerFrame in that state turns a
        // 512-frame, 3-buffer callback into 170 frames and speeds audio up 3x.
        const uint32_t frames = vv_core_audio_buffer_frame_count(
            buffer->mDataByteSize,
            capture->bytesPerSample,
            buffer->mNumberChannels
        );
        if (frames == 0) {
            continue;
        }
        if (frames < frameCount) {
            frameCount = frames;
        }
    }
    return frameCount == UINT_MAX ? 0u : frameCount;
}

static OSStatus vv_io_proc(
    AudioObjectID inDevice,
    const AudioTimeStamp *inNow,
    const AudioBufferList *inInputData,
    const AudioTimeStamp *inInputTime,
    AudioBufferList *outOutputData,
    const AudioTimeStamp *inOutputTime,
    void *inClientData
) {
    (void) inDevice;
    (void) inNow;
    (void) outOutputData;
    (void) inOutputTime;

    VVCapture *capture = (VVCapture *) inClientData;
    if (capture == NULL || inInputData == NULL ||
        !atomic_load_explicit(&capture->running, memory_order_relaxed)) {
        return noErr;
    }

    uint32_t frameCount = vv_frame_count(capture, inInputData);
    if (frameCount == 0) {
        return noErr;
    }
    if (frameCount > VV_MAX_FRAMES_PER_PACKET) {
        atomic_fetch_add_explicit(&capture->droppedPackets, 1, memory_order_relaxed);
        return noErr;
    }

    const uint64_t writeIndex =
        atomic_load_explicit(&capture->writeIndex, memory_order_relaxed);
    const uint64_t readIndex =
        atomic_load_explicit(&capture->readIndex, memory_order_acquire);
    if (writeIndex - readIndex >= VV_RING_CAPACITY) {
        atomic_fetch_add_explicit(&capture->droppedPackets, 1, memory_order_relaxed);
        return noErr;
    }

    VVPacketSlot *slot = &capture->slots[writeIndex % VV_RING_CAPACITY];
    memset(slot->samples, 0, frameCount * sizeof(float));

    uint32_t availableChannels = 0;
    const AudioBuffer *buffers = inInputData->mBuffers;
    for (UInt32 bufferIndex = 0; bufferIndex < inInputData->mNumberBuffers; ++bufferIndex) {
        const AudioBuffer *buffer = &buffers[bufferIndex];
        if (buffer->mData == NULL || buffer->mDataByteSize == 0 ||
            buffer->mNumberChannels == 0) {
            continue;
        }

        const uint8_t *data = (const uint8_t *) buffer->mData;
        const uint32_t channelCount = buffer->mNumberChannels;
        const uint32_t bufferBytesPerFrame =
            vv_core_audio_buffer_bytes_per_frame(capture->bytesPerSample, channelCount);
        for (uint32_t frame = 0; frame < frameCount; ++frame) {
            const uint8_t *frameData = data + frame * bufferBytesPerFrame;
            float sum = 0.0f;
            for (uint32_t channel = 0; channel < channelCount; ++channel) {
                sum += vv_read_sample(
                    frameData + channel * capture->bytesPerSample,
                    &capture->format
                );
            }
            slot->samples[frame] += sum;
        }
        availableChannels += channelCount;
    }

    if (availableChannels == 0) {
        return noErr;
    }
    const float channelScale = 1.0f / (float) availableChannels;
    for (uint32_t frame = 0; frame < frameCount; ++frame) {
        slot->samples[frame] *= channelScale;
    }

    slot->frameCount = frameCount;
    slot->inputHostTime =
        inInputTime != NULL &&
        (inInputTime->mFlags & kAudioTimeStampHostTimeValid) != 0
            ? inInputTime->mHostTime
            : mach_absolute_time();
    slot->inputSampleTime =
        inInputTime != NULL &&
        (inInputTime->mFlags & kAudioTimeStampSampleTimeValid) != 0
            ? (int64_t) inInputTime->mSampleTime
            : -1;
    slot->sequence = writeIndex;

    atomic_store_explicit(&capture->writeIndex, writeIndex + 1, memory_order_release);
    dispatch_semaphore_signal(capture->packetSemaphore);
    return noErr;
}

int32_t vv_core_audio_capture_create(
    AudioObjectID deviceID,
    VVCoreAudioCaptureRef *outCapture
) {
    if (outCapture == NULL || deviceID == kAudioObjectUnknown) {
        return kAudioHardwareBadObjectError;
    }
    *outCapture = NULL;

    VVCapture *capture = (VVCapture *) calloc(1, sizeof(VVCapture));
    if (capture == NULL) {
        return kAudioHardwareUnspecifiedError;
    }
    capture->deviceID = deviceID;

    OSStatus status = vv_get_input_stream_format(deviceID, &capture->format);
    if (status == noErr &&
        !vv_format_is_supported(&capture->format, &capture->bytesPerSample)) {
        status = kAudioHardwareUnsupportedOperationError;
    }
    if (status == noErr) {
        status = vv_get_buffer_frame_size(deviceID, &capture->bufferFrameSize);
    }
    if (status == noErr &&
        (capture->bufferFrameSize == 0 ||
         capture->bufferFrameSize > VV_MAX_FRAMES_PER_PACKET)) {
        status = kAudioHardwareUnsupportedOperationError;
    }
    if (status != noErr) {
        free(capture);
        return status;
    }

    capture->packetSemaphore = dispatch_semaphore_create(0);
    if (capture->packetSemaphore == NULL) {
        free(capture);
        return kAudioHardwareUnspecifiedError;
    }
    atomic_init(&capture->writeIndex, 0);
    atomic_init(&capture->readIndex, 0);
    atomic_init(&capture->droppedPackets, 0);
    atomic_init(&capture->running, false);

    status = AudioDeviceCreateIOProcID(
        deviceID,
        vv_io_proc,
        capture,
        &capture->ioProcID
    );
    if (status != noErr) {
#if !OS_OBJECT_USE_OBJC
        dispatch_release(capture->packetSemaphore);
#endif
        free(capture);
        return status;
    }

    *outCapture = (VVCoreAudioCaptureRef) capture;
    return noErr;
}

int32_t vv_core_audio_capture_start(VVCoreAudioCaptureRef captureRef) {
    VVCapture *capture = (VVCapture *) captureRef;
    if (capture == NULL || capture->ioProcID == NULL) {
        return kAudioHardwareBadObjectError;
    }
    if (atomic_load_explicit(&capture->running, memory_order_acquire)) {
        return noErr;
    }

    atomic_store_explicit(&capture->running, true, memory_order_release);
    OSStatus status = AudioDeviceStart(capture->deviceID, capture->ioProcID);
    if (status != noErr) {
        atomic_store_explicit(&capture->running, false, memory_order_release);
        dispatch_semaphore_signal(capture->packetSemaphore);
    }
    return status;
}

int32_t vv_core_audio_capture_stop(VVCoreAudioCaptureRef captureRef) {
    VVCapture *capture = (VVCapture *) captureRef;
    if (capture == NULL || capture->ioProcID == NULL) {
        return kAudioHardwareBadObjectError;
    }
    if (!atomic_load_explicit(&capture->running, memory_order_acquire)) {
        dispatch_semaphore_signal(capture->packetSemaphore);
        return noErr;
    }

    // Keep accepting callbacks until AudioDeviceStop has synchronized with the
    // IOProc. Packets acquired before the caller's stop boundary can then be
    // timestamp-trimmed by the consumer instead of being dropped here.
    OSStatus status = AudioDeviceStop(capture->deviceID, capture->ioProcID);
    atomic_store_explicit(&capture->running, false, memory_order_release);
    dispatch_semaphore_signal(capture->packetSemaphore);
    return status;
}

void vv_core_audio_capture_destroy(VVCoreAudioCaptureRef captureRef) {
    VVCapture *capture = (VVCapture *) captureRef;
    if (capture == NULL) {
        return;
    }
    if (atomic_load_explicit(&capture->running, memory_order_acquire)) {
        (void) vv_core_audio_capture_stop(captureRef);
    }
    if (capture->ioProcID != NULL) {
        (void) AudioDeviceDestroyIOProcID(capture->deviceID, capture->ioProcID);
        capture->ioProcID = NULL;
    }
#if !OS_OBJECT_USE_OBJC
    dispatch_release(capture->packetSemaphore);
#endif
    free(capture);
}

bool vv_core_audio_capture_wait(
    VVCoreAudioCaptureRef captureRef,
    uint32_t timeoutMilliseconds
) {
    VVCapture *capture = (VVCapture *) captureRef;
    if (capture == NULL) {
        return false;
    }
    dispatch_time_t timeout = dispatch_time(
        DISPATCH_TIME_NOW,
        (int64_t) timeoutMilliseconds * NSEC_PER_MSEC
    );
    return dispatch_semaphore_wait(capture->packetSemaphore, timeout) == 0;
}

bool vv_core_audio_capture_peek(
    VVCoreAudioCaptureRef captureRef,
    VVCoreAudioPacket *packet
) {
    VVCapture *capture = (VVCapture *) captureRef;
    if (capture == NULL || packet == NULL) {
        return false;
    }
    const uint64_t readIndex =
        atomic_load_explicit(&capture->readIndex, memory_order_relaxed);
    const uint64_t writeIndex =
        atomic_load_explicit(&capture->writeIndex, memory_order_acquire);
    if (readIndex == writeIndex) {
        return false;
    }

    const VVPacketSlot *slot = &capture->slots[readIndex % VV_RING_CAPACITY];
    packet->samples = slot->samples;
    packet->frameCount = slot->frameCount;
    packet->sampleRate = capture->format.mSampleRate;
    packet->inputHostTime = slot->inputHostTime;
    packet->inputSampleTime = slot->inputSampleTime;
    packet->sequence = slot->sequence;
    return true;
}

void vv_core_audio_capture_consume(VVCoreAudioCaptureRef captureRef) {
    VVCapture *capture = (VVCapture *) captureRef;
    if (capture == NULL) {
        return;
    }
    const uint64_t readIndex =
        atomic_load_explicit(&capture->readIndex, memory_order_relaxed);
    const uint64_t writeIndex =
        atomic_load_explicit(&capture->writeIndex, memory_order_acquire);
    if (readIndex != writeIndex) {
        atomic_store_explicit(&capture->readIndex, readIndex + 1, memory_order_release);
    }
}

void vv_core_audio_capture_clear(VVCoreAudioCaptureRef captureRef) {
    VVCapture *capture = (VVCapture *) captureRef;
    if (capture == NULL || atomic_load_explicit(&capture->running, memory_order_acquire)) {
        return;
    }
    const uint64_t writeIndex =
        atomic_load_explicit(&capture->writeIndex, memory_order_acquire);
    atomic_store_explicit(&capture->readIndex, writeIndex, memory_order_release);
    atomic_store_explicit(&capture->droppedPackets, 0, memory_order_relaxed);
    while (dispatch_semaphore_wait(capture->packetSemaphore, DISPATCH_TIME_NOW) == 0) {
        // Remove stale per-packet wakeups from the previous stopped session.
    }
}

void vv_core_audio_capture_wake(VVCoreAudioCaptureRef captureRef) {
    VVCapture *capture = (VVCapture *) captureRef;
    if (capture != NULL) {
        dispatch_semaphore_signal(capture->packetSemaphore);
    }
}

bool vv_core_audio_capture_is_running(VVCoreAudioCaptureRef captureRef) {
    VVCapture *capture = (VVCapture *) captureRef;
    return capture != NULL &&
        atomic_load_explicit(&capture->running, memory_order_acquire);
}

double vv_core_audio_capture_sample_rate(VVCoreAudioCaptureRef captureRef) {
    const VVCapture *capture = (const VVCapture *) captureRef;
    return capture == NULL ? 0.0 : capture->format.mSampleRate;
}

uint32_t vv_core_audio_capture_buffer_frame_size(VVCoreAudioCaptureRef captureRef) {
    const VVCapture *capture = (const VVCapture *) captureRef;
    return capture == NULL ? 0u : capture->bufferFrameSize;
}

uint64_t vv_core_audio_capture_dropped_packet_count(VVCoreAudioCaptureRef captureRef) {
    const VVCapture *capture = (const VVCapture *) captureRef;
    return capture == NULL
        ? 0u
        : atomic_load_explicit(&capture->droppedPackets, memory_order_relaxed);
}
