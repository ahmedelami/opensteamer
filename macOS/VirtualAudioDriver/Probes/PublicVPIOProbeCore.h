#ifndef OPENSTEAMER_PUBLIC_VPIO_PROBE_CORE_H
#define OPENSTEAMER_PUBLIC_VPIO_PROBE_CORE_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define OSVA_PUBLIC_VPIO_VISIBLE_UID                                          \
  "com.elamin.opensteamer.virtual-microphone.input"
#define OSVA_PUBLIC_VPIO_HIDDEN_UID                                           \
  "com.elamin.opensteamer.virtual-microphone.writer"
#define OSVA_PUBLIC_VPIO_MODEL_UID                                            \
  "com.elamin.opensteamer.virtual-microphone.model"
#define OSVA_PUBLIC_VPIO_LEGACY_VISIBLE_UID "BlackHole2ch_UID"
#define OSVA_PUBLIC_VPIO_LEGACY_HIDDEN_UID "BlackHole2ch_2_UID"

enum {
  kOSVAPublicVPIOExpectedClockDomain = 0x6F73564D,
  kOSVAPublicVPIOExpectedSampleRate = 48000,
  kOSVAPublicVPIOMinimumCallbackCount = 3,
  kOSVAPublicVPIOMinimumCaptureFrames = 48000,
  kOSVAPublicVPIOMinimumMatchedEnvelopeFrames = 40,
};

typedef enum OSVAPublicVPIOGate {
  kOSVAPublicVPIOGateIdentityTopology = UINT64_C(1) << 0,
  kOSVAPublicVPIOGateFormat = UINT64_C(1) << 1,
  kOSVAPublicVPIOGateSafeOutputs = UINT64_C(1) << 2,
  kOSVAPublicVPIOGateListenerFence = UINT64_C(1) << 3,
  kOSVAPublicVPIOGateStartOrder = UINT64_C(1) << 4,
  kOSVAPublicVPIOGateTimestamps = UINT64_C(1) << 5,
  kOSVAPublicVPIOGateCallbackProgress = UINT64_C(1) << 6,
  kOSVAPublicVPIOGateSignalCorrelation = UINT64_C(1) << 7,
  kOSVAPublicVPIOGateVPIOStatus = UINT64_C(1) << 8,
  kOSVAPublicVPIOGateRestoration = UINT64_C(1) << 9,
  kOSVAPublicVPIOGateTeardown = UINT64_C(1) << 10,
} OSVAPublicVPIOGate;

typedef struct OSVAPublicVPIOEvidence {
  uint64_t visible_uid_hash;
  uint64_t hidden_uid_hash;
  uint64_t visible_model_uid_hash;
  uint64_t hidden_model_uid_hash;
  bool devices_are_distinct;
  bool visible_is_alive;
  bool hidden_is_alive;
  bool visible_is_hidden;
  bool hidden_is_hidden;
  uint32_t visible_input_channels;
  uint32_t visible_output_channels;
  uint32_t hidden_input_channels;
  uint32_t hidden_output_channels;
  double visible_nominal_sample_rate;
  double hidden_nominal_sample_rate;
  uint32_t visible_clock_domain;
  uint32_t hidden_clock_domain;
  bool endpoint_translation_stable_before_commit;
  bool endpoint_translation_stable_after_start;

  int32_t visible_format_status;
  int32_t hidden_format_status;
  int32_t processed_mic_format_set_status;
  int32_t processed_mic_format_read_status;
  int32_t playout_format_set_status;
  int32_t playout_format_read_status;
  bool visible_stream_format_exact;
  bool hidden_stream_format_exact;
  bool processed_mic_stream_format_exact;
  bool playout_stream_format_exact;
  double processed_mic_sample_rate;
  uint32_t processed_mic_channels;
  double playout_sample_rate;
  uint32_t playout_channels;

  uint64_t original_input_uid_hash;
  bool original_input_is_admissible_for_restoration;
  uint64_t default_output_uid_hash;
  uint64_t default_system_output_uid_hash;
  bool default_output_is_forbidden_virtual;
  bool default_system_output_is_forbidden_virtual;
  bool default_output_is_real_and_alive;
  bool default_system_output_is_real_and_alive;
  uint32_t default_output_channels;
  uint32_t default_system_output_channels;
  bool output_defaults_stable_and_safe_before_gate;
  bool defaults_stable_and_safe_after_vpio_start;
  bool output_defaults_stable_and_safe_after_run;

  bool listeners_registered_before_default_reads;
  uint64_t input_listener_sequence_before_selection;
  uint64_t input_listener_sequence_at_commit;
  uint64_t input_listener_sequence_at_restore;
  uint64_t output_listener_notifications;
  uint64_t system_output_listener_notifications;
  uint64_t unexpected_input_listener_notifications;
  bool selection_comparison_matched;
  bool selection_listener_advanced;
  bool selection_readback_matched;
  bool selection_commit_sequence_stable;
  bool visible_was_default_input_at_commit;

  bool hidden_writer_started_first;
  uint64_t initial_silence_frames;
  bool vpio_initialized_after_writer;
  bool nonce_signal_enabled_after_vpio_start;
  int32_t writer_create_status;
  int32_t writer_start_status;

  uint64_t writer_callback_count;
  uint64_t microphone_callback_count;
  uint64_t output_callback_count;
  uint64_t output_silence_frame_count;
  bool output_reference_is_bounded_silence;
  uint64_t writer_valid_timestamp_count;
  uint64_t microphone_valid_timestamp_count;
  uint64_t frozen_timestamp_count;
  uint64_t gapped_timestamp_count;
  uint64_t oversized_callback_count;
  uint64_t callback_stall_count;

  uint64_t captured_frame_count;
  uint64_t matched_envelope_frame_count;
  uint64_t capture_hash;
  uint64_t nonce_hash;
  double capture_rms;
  double speech_band_correlation;

  int32_t component_status;
  int32_t enable_input_status;
  int32_t enable_output_status;
  int32_t input_callback_status;
  int32_t output_callback_status;
  int32_t voice_processing_bypass_status;
  bool voice_processing_bypassed;
  int32_t initialize_status;
  int32_t start_status;
  int32_t last_render_error;
  uint64_t render_error_count;
  uint64_t known_vpio_error_count;

  bool default_input_was_changed;
  bool default_input_ownership_preserved_at_restore;
  bool restoration_target_retranslated_from_uid;
  bool restoration_attempted_if_owned;
  bool restoration_succeeded;
  bool restoration_skipped_after_ownership_loss;
  bool final_default_input_matches_snapshot;

  bool gates_closed_before_stop;
  bool cancellation_handlers_installed;
  int32_t vpio_stop_status;
  int32_t vpio_uninitialize_status;
  int32_t vpio_dispose_status;
  int32_t writer_stop_status;
  int32_t writer_destroy_status;
  uint64_t callbacks_in_flight_after_drain;
  bool callbacks_stable_after_drain;
  bool listeners_removed;
  bool listener_callbacks_stable_after_removal;
} OSVAPublicVPIOEvidence;

typedef struct OSVAPublicVPIOSelfTestSummary {
  bool passed;
  uint32_t test_count;
  uint32_t mutant_count;
  uint64_t pass_set_hash;
  uint64_t unexpected_failure_mask;
} OSVAPublicVPIOSelfTestSummary;

typedef struct OSVAPublicVPIOSignalMetrics {
  uint64_t captured_frame_count;
  uint64_t matched_envelope_frame_count;
  uint64_t capture_hash;
  double capture_rms;
  double speech_band_correlation;
} OSVAPublicVPIOSignalMetrics;

uint64_t OSVAPublicVPIOHashBytes(const void *bytes, size_t length);
uint64_t OSVAPublicVPIOHashString(const char *string);
bool OSVAPublicVPIOIsForbiddenOutputUID(const char *uid);
bool OSVAPublicVPIOIsForbiddenRestorationInputUID(const char *uid);
OSVAPublicVPIOSignalMetrics OSVAPublicVPIOAnalyzeSignal(
    const float *reference, size_t reference_frame_count, const float *capture,
    size_t capture_frame_count);
OSVAPublicVPIOEvidence OSVAPublicVPIOBaselineEvidence(void);
uint64_t OSVAPublicVPIOEvaluate(const OSVAPublicVPIOEvidence *evidence);
OSVAPublicVPIOSelfTestSummary OSVAPublicVPIORunSelfTests(void);

#ifdef __cplusplus
}
#endif

#endif
