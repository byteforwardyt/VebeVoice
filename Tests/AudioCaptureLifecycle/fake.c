#include "CoreAudioCaptureSupport.h"
#include <stdatomic.h>
#include <stdlib.h>
#include <unistd.h>
typedef struct { _Atomic bool running; _Atomic bool destroyed; _Atomic bool consumed; float sample; } Fake;
static _Atomic int accessesAfterDestroy;
static _Atomic int destroyCount;
static void check(Fake *f) { if (f->destroyed) ++accessesAfterDestroy; }
int probe_accesses(void) { return accessesAfterDestroy; }
int probe_destroy_count(void) { return destroyCount; }
int32_t vv_core_audio_capture_create(AudioObjectID d, VVCoreAudioCaptureRef *out) { *out=calloc(1,sizeof(Fake)); return 0; }
int32_t vv_core_audio_capture_start(VVCoreAudioCaptureRef p) { ((Fake*)p)->running=true; return 0; }
int32_t vv_core_audio_capture_stop(VVCoreAudioCaptureRef p) { ((Fake*)p)->running=false; return 0; }
void vv_core_audio_capture_destroy(VVCoreAudioCaptureRef p) { ((Fake*)p)->destroyed=true; ++destroyCount; }
bool vv_core_audio_capture_wait(VVCoreAudioCaptureRef p,uint32_t ms) { check(p); usleep(1000); return true; }
bool vv_core_audio_capture_peek(VVCoreAudioCaptureRef p,VVCoreAudioPacket *packet) { Fake *f=p; check(f); if(f->consumed) return false; packet->samples=&f->sample; packet->frameCount=1; packet->sampleRate=16000; return true; }
void vv_core_audio_capture_consume(VVCoreAudioCaptureRef p) { check(p); ((Fake*)p)->consumed=true; }
void vv_core_audio_capture_clear(VVCoreAudioCaptureRef p) { check(p); }
void vv_core_audio_capture_wake(VVCoreAudioCaptureRef p) { check(p); }
bool vv_core_audio_capture_is_running(VVCoreAudioCaptureRef p) { check(p); return ((Fake*)p)->running; }
double vv_core_audio_capture_sample_rate(VVCoreAudioCaptureRef p) { return 16000; }
uint32_t vv_core_audio_capture_buffer_frame_size(VVCoreAudioCaptureRef p) { return 1; }
uint64_t vv_core_audio_capture_dropped_packet_count(VVCoreAudioCaptureRef p) { return 0; }

// Destruction intentionally marks the allocation instead of freeing it so a
// delayed consumer's lifetime violation is observable without undefined behavior.
// The single test allocation is reclaimed when this short-lived process exits.
