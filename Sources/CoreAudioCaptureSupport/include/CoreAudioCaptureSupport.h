#ifndef CORE_AUDIO_CAPTURE_SUPPORT_H
#define CORE_AUDIO_CAPTURE_SUPPORT_H

#include <CoreAudio/CoreAudio.h>
#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef void *VVCoreAudioCaptureRef;

typedef struct {
    const float *samples;
    uint32_t frameCount;
    double sampleRate;
    uint64_t inputHostTime;
    int64_t inputSampleTime;
    uint64_t sequence;
} VVCoreAudioPacket;

/// Layout helpers shared by capture and deterministic tests.
uint32_t vv_core_audio_buffer_bytes_per_frame(
    uint32_t bytesPerSample,
    uint32_t channelCount
);
uint32_t vv_core_audio_buffer_frame_count(
    uint32_t dataByteSize,
    uint32_t bytesPerSample,
    uint32_t channelCount
);

/// Creates a prepared, input-only capture for one physical Core Audio device.
/// The device is not started and the microphone is not active until start.
int32_t vv_core_audio_capture_create(
    AudioObjectID deviceID,
    VVCoreAudioCaptureRef *outCapture
);

int32_t vv_core_audio_capture_start(VVCoreAudioCaptureRef capture);
int32_t vv_core_audio_capture_stop(VVCoreAudioCaptureRef capture);
void vv_core_audio_capture_destroy(VVCoreAudioCaptureRef capture);

/// Waits until the realtime producer publishes a packet or capture stops.
/// Returns true when the consumer should attempt to drain the ring.
bool vv_core_audio_capture_wait(VVCoreAudioCaptureRef capture, uint32_t timeoutMilliseconds);

/// Returns a view into the next immutable ring slot. The pointer remains valid
/// until consume is called and must never escape the consumer callback.
bool vv_core_audio_capture_peek(VVCoreAudioCaptureRef capture, VVCoreAudioPacket *packet);
void vv_core_audio_capture_consume(VVCoreAudioCaptureRef capture);
void vv_core_audio_capture_clear(VVCoreAudioCaptureRef capture);
void vv_core_audio_capture_wake(VVCoreAudioCaptureRef capture);

bool vv_core_audio_capture_is_running(VVCoreAudioCaptureRef capture);
double vv_core_audio_capture_sample_rate(VVCoreAudioCaptureRef capture);
uint32_t vv_core_audio_capture_buffer_frame_size(VVCoreAudioCaptureRef capture);
uint64_t vv_core_audio_capture_dropped_packet_count(VVCoreAudioCaptureRef capture);

#ifdef __cplusplus
}
#endif

#endif
