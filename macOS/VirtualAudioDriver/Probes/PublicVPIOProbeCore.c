#include "PublicVPIOProbeCore.h"

#include <math.h>
#include <stdlib.h>
#include <string.h>

static const double kSampleRateTolerance = 0.0001;
static const double kMinimumCaptureRMS = 0.0025;
static const double kMinimumCorrelation = 0.45;

uint64_t OSVAPublicVPIOHashBytes(const void *bytes, size_t length) {
  const uint8_t *cursor = (const uint8_t *)bytes;
  uint64_t hash = UINT64_C(1469598103934665603);
  for (size_t index = 0; index < length; ++index) {
    hash ^= (uint64_t)cursor[index];
    hash *= UINT64_C(1099511628211);
  }
  return hash;
}

uint64_t OSVAPublicVPIOHashString(const char *string) {
  if (string == NULL) {
    return 0;
  }
  return OSVAPublicVPIOHashBytes(string, strlen(string));
}

bool OSVAPublicVPIOIsForbiddenOutputUID(const char *uid) {
  if (uid == NULL) {
    return false;
  }
  return strcmp(uid, OSVA_PUBLIC_VPIO_VISIBLE_UID) == 0 ||
         strcmp(uid, OSVA_PUBLIC_VPIO_HIDDEN_UID) == 0 ||
         strcmp(uid, OSVA_PUBLIC_VPIO_LEGACY_VISIBLE_UID) == 0 ||
         strcmp(uid, OSVA_PUBLIC_VPIO_LEGACY_HIDDEN_UID) == 0;
}

bool OSVAPublicVPIOIsForbiddenRestorationInputUID(const char *uid) {
  if (uid == NULL) {
    return true;
  }
  return strcmp(uid, OSVA_PUBLIC_VPIO_HIDDEN_UID) == 0 ||
         strcmp(uid, OSVA_PUBLIC_VPIO_LEGACY_HIDDEN_UID) == 0;
}

OSVAPublicVPIOSignalMetrics OSVAPublicVPIOAnalyzeSignal(
    const float *reference, size_t referenceFrameCount, const float *capture,
    size_t captureFrameCount) {
  OSVAPublicVPIOSignalMetrics metrics;
  memset(&metrics, 0, sizeof(metrics));
  if (reference == NULL || capture == NULL || referenceFrameCount < 1920 ||
      captureFrameCount < 1920) {
    return metrics;
  }

  metrics.captured_frame_count = (uint64_t)captureFrameCount;
  metrics.capture_hash =
      OSVAPublicVPIOHashBytes(capture, captureFrameCount * sizeof(float));

  long double sumSquares = 0.0L;
  for (size_t index = 0; index < captureFrameCount; ++index) {
    const long double sample = (long double)capture[index];
    sumSquares += sample * sample;
  }
  metrics.capture_rms =
      sqrt((double)(sumSquares / (long double)captureFrameCount));

  const size_t hopFrames = 480;
  const size_t windowFrames = 1920;
  const size_t referenceEnvelopeCount =
      1 + ((referenceFrameCount - windowFrames) / hopFrames);
  const size_t captureEnvelopeCount =
      1 + ((captureFrameCount - windowFrames) / hopFrames);
  double *referenceEnvelope =
      (double *)calloc(referenceEnvelopeCount, sizeof(double));
  double *captureEnvelope =
      (double *)calloc(captureEnvelopeCount, sizeof(double));
  if (referenceEnvelope == NULL || captureEnvelope == NULL) {
    free(referenceEnvelope);
    free(captureEnvelope);
    return metrics;
  }

  for (size_t envelope = 0; envelope < referenceEnvelopeCount; ++envelope) {
    long double energy = 0.0L;
    const size_t first = envelope * hopFrames;
    for (size_t index = 0; index < windowFrames; ++index) {
      const long double sample = (long double)reference[first + index];
      energy += sample * sample;
    }
    referenceEnvelope[envelope] =
        sqrt((double)(energy / (long double)windowFrames));
  }
  for (size_t envelope = 0; envelope < captureEnvelopeCount; ++envelope) {
    long double energy = 0.0L;
    const size_t first = envelope * hopFrames;
    for (size_t index = 0; index < windowFrames; ++index) {
      const long double sample = (long double)capture[first + index];
      energy += sample * sample;
    }
    captureEnvelope[envelope] =
        sqrt((double)(energy / (long double)windowFrames));
  }

  double bestCorrelation = -1.0;
  size_t bestCount = 0;
  const size_t smallerEnvelopeCount =
      referenceEnvelopeCount < captureEnvelopeCount ? referenceEnvelopeCount
                                                    : captureEnvelopeCount;
  const size_t minimumOverlapCount = (smallerEnvelopeCount * 3) / 4;
  for (int lag = -50; lag <= 50; ++lag) {
    size_t referenceStart = 0;
    size_t captureStart = 0;
    if (lag < 0) {
      referenceStart = (size_t)(-lag);
    } else {
      captureStart = (size_t)lag;
    }
    if (referenceStart >= referenceEnvelopeCount ||
        captureStart >= captureEnvelopeCount) {
      continue;
    }
    size_t count = referenceEnvelopeCount - referenceStart;
    const size_t captureAvailable = captureEnvelopeCount - captureStart;
    if (captureAvailable < count) {
      count = captureAvailable;
    }
    if (count < kOSVAPublicVPIOMinimumMatchedEnvelopeFrames ||
        count < minimumOverlapCount) {
      continue;
    }

    long double referenceMean = 0.0L;
    long double captureMean = 0.0L;
    for (size_t index = 0; index < count; ++index) {
      referenceMean += referenceEnvelope[referenceStart + index];
      captureMean += captureEnvelope[captureStart + index];
    }
    referenceMean /= (long double)count;
    captureMean /= (long double)count;

    long double numerator = 0.0L;
    long double referencePower = 0.0L;
    long double capturePower = 0.0L;
    for (size_t index = 0; index < count; ++index) {
      const long double referenceCentered =
          (long double)referenceEnvelope[referenceStart + index] -
          referenceMean;
      const long double captureCentered =
          (long double)captureEnvelope[captureStart + index] - captureMean;
      numerator += referenceCentered * captureCentered;
      referencePower += referenceCentered * referenceCentered;
      capturePower += captureCentered * captureCentered;
    }
    if (referencePower <= 0.0L || capturePower <= 0.0L) {
      continue;
    }
    const double correlation =
        (double)(numerator / sqrtl(referencePower * capturePower));
    if (correlation > bestCorrelation) {
      bestCorrelation = correlation;
      bestCount = count;
    }
  }

  if (bestCorrelation > -1.0) {
    metrics.speech_band_correlation = bestCorrelation;
    metrics.matched_envelope_frame_count = (uint64_t)bestCount;
  }
  free(referenceEnvelope);
  free(captureEnvelope);
  return metrics;
}

OSVAPublicVPIOEvidence OSVAPublicVPIOBaselineEvidence(void) {
  OSVAPublicVPIOEvidence evidence;
  memset(&evidence, 0, sizeof(evidence));

  evidence.visible_uid_hash =
      OSVAPublicVPIOHashString(OSVA_PUBLIC_VPIO_VISIBLE_UID);
  evidence.hidden_uid_hash =
      OSVAPublicVPIOHashString(OSVA_PUBLIC_VPIO_HIDDEN_UID);
  evidence.visible_model_uid_hash =
      OSVAPublicVPIOHashString(OSVA_PUBLIC_VPIO_MODEL_UID);
  evidence.hidden_model_uid_hash =
      OSVAPublicVPIOHashString(OSVA_PUBLIC_VPIO_MODEL_UID);
  evidence.devices_are_distinct = true;
  evidence.visible_is_alive = true;
  evidence.hidden_is_alive = true;
  evidence.visible_is_hidden = false;
  evidence.hidden_is_hidden = true;
  evidence.visible_input_channels = 1;
  evidence.visible_output_channels = 0;
  evidence.hidden_input_channels = 0;
  evidence.hidden_output_channels = 1;
  evidence.visible_nominal_sample_rate = 48000.0;
  evidence.hidden_nominal_sample_rate = 48000.0;
  evidence.visible_clock_domain = kOSVAPublicVPIOExpectedClockDomain;
  evidence.hidden_clock_domain = kOSVAPublicVPIOExpectedClockDomain;
  evidence.endpoint_translation_stable_before_commit = true;
  evidence.endpoint_translation_stable_after_start = true;

  evidence.visible_stream_format_exact = true;
  evidence.hidden_stream_format_exact = true;
  evidence.processed_mic_stream_format_exact = true;
  evidence.processed_mic_sample_rate = 48000.0;
  evidence.processed_mic_channels = 1;
  evidence.playout_stream_format_exact = true;
  evidence.playout_sample_rate = 48000.0;
  evidence.playout_channels = 2;

  evidence.original_input_uid_hash =
      OSVAPublicVPIOHashString("BuiltInMicrophoneDevice");
  evidence.original_input_is_admissible_for_restoration = true;
  evidence.default_output_uid_hash =
      OSVAPublicVPIOHashString("BuiltInSpeakerDevice");
  evidence.default_system_output_uid_hash =
      evidence.default_output_uid_hash;
  evidence.default_output_is_real_and_alive = true;
  evidence.default_system_output_is_real_and_alive = true;
  evidence.default_output_channels = 2;
  evidence.default_system_output_channels = 2;
  evidence.output_defaults_stable_and_safe_before_gate = true;
  evidence.defaults_stable_and_safe_after_vpio_start = true;
  evidence.output_defaults_stable_and_safe_after_run = true;

  evidence.listeners_registered_before_default_reads = true;
  evidence.input_listener_sequence_before_selection = 0;
  evidence.input_listener_sequence_at_commit = 1;
  evidence.input_listener_sequence_at_restore = 1;
  evidence.selection_comparison_matched = true;
  evidence.selection_listener_advanced = true;
  evidence.selection_readback_matched = true;
  evidence.selection_commit_sequence_stable = true;
  evidence.visible_was_default_input_at_commit = true;

  evidence.hidden_writer_started_first = true;
  evidence.initial_silence_frames = 2048;
  evidence.vpio_initialized_after_writer = true;
  evidence.nonce_signal_enabled_after_vpio_start = true;

  evidence.writer_callback_count = 16;
  evidence.microphone_callback_count = 16;
  evidence.output_callback_count = 16;
  evidence.output_silence_frame_count = 4096;
  evidence.output_reference_is_bounded_silence = true;
  evidence.writer_valid_timestamp_count = 16;
  evidence.microphone_valid_timestamp_count = 16;

  evidence.captured_frame_count = 96000;
  evidence.matched_envelope_frame_count = 120;
  evidence.capture_hash = UINT64_C(0x0123456789ABCDEF);
  evidence.nonce_hash = UINT64_C(0xFEDCBA9876543210);
  evidence.capture_rms = 0.08;
  evidence.speech_band_correlation = 0.82;

  evidence.default_input_was_changed = true;
  evidence.default_input_ownership_preserved_at_restore = true;
  evidence.restoration_target_retranslated_from_uid = true;
  evidence.restoration_attempted_if_owned = true;
  evidence.restoration_succeeded = true;
  evidence.final_default_input_matches_snapshot = true;

  evidence.gates_closed_before_stop = true;
  evidence.cancellation_handlers_installed = true;
  evidence.callbacks_stable_after_drain = true;
  evidence.listeners_removed = true;
  evidence.listener_callbacks_stable_after_removal = true;
  return evidence;
}

static bool NearlyEqual(double left, double right) {
  return fabs(left - right) <= kSampleRateTolerance;
}

uint64_t OSVAPublicVPIOEvaluate(const OSVAPublicVPIOEvidence *evidence) {
  if (evidence == NULL) {
    return UINT64_MAX;
  }

  uint64_t failures = 0;
  const uint64_t expectedVisibleUID =
      OSVAPublicVPIOHashString(OSVA_PUBLIC_VPIO_VISIBLE_UID);
  const uint64_t expectedHiddenUID =
      OSVAPublicVPIOHashString(OSVA_PUBLIC_VPIO_HIDDEN_UID);
  const uint64_t expectedModelUID =
      OSVAPublicVPIOHashString(OSVA_PUBLIC_VPIO_MODEL_UID);

  if (evidence->visible_uid_hash != expectedVisibleUID ||
      evidence->hidden_uid_hash != expectedHiddenUID ||
      evidence->visible_model_uid_hash != expectedModelUID ||
      evidence->hidden_model_uid_hash != expectedModelUID ||
      !evidence->devices_are_distinct || !evidence->visible_is_alive ||
      !evidence->hidden_is_alive || evidence->visible_is_hidden ||
      !evidence->hidden_is_hidden ||
      evidence->visible_clock_domain != kOSVAPublicVPIOExpectedClockDomain ||
      evidence->hidden_clock_domain != kOSVAPublicVPIOExpectedClockDomain ||
      !evidence->endpoint_translation_stable_before_commit ||
      !evidence->endpoint_translation_stable_after_start) {
    failures |= kOSVAPublicVPIOGateIdentityTopology;
  }

  if (evidence->visible_input_channels != 1 ||
      evidence->visible_output_channels != 0 ||
      evidence->hidden_input_channels != 0 ||
      evidence->hidden_output_channels != 1 ||
      !NearlyEqual(evidence->visible_nominal_sample_rate, 48000.0) ||
      !NearlyEqual(evidence->hidden_nominal_sample_rate, 48000.0) ||
      evidence->visible_format_status != 0 ||
      evidence->hidden_format_status != 0 ||
      evidence->processed_mic_format_set_status != 0 ||
      evidence->processed_mic_format_read_status != 0 ||
      evidence->playout_format_set_status != 0 ||
      evidence->playout_format_read_status != 0 ||
      !evidence->visible_stream_format_exact ||
      !evidence->hidden_stream_format_exact ||
      !evidence->processed_mic_stream_format_exact ||
      !evidence->playout_stream_format_exact ||
      !NearlyEqual(evidence->processed_mic_sample_rate, 48000.0) ||
      evidence->processed_mic_channels != 1 ||
      !NearlyEqual(evidence->playout_sample_rate, 48000.0) ||
      evidence->playout_channels != 2) {
    failures |= kOSVAPublicVPIOGateFormat;
  }

  if (evidence->default_output_is_forbidden_virtual ||
      evidence->default_system_output_is_forbidden_virtual ||
      !evidence->default_output_is_real_and_alive ||
      !evidence->default_system_output_is_real_and_alive ||
      evidence->default_output_channels == 0 ||
      evidence->default_system_output_channels == 0 ||
      evidence->default_output_uid_hash == 0 ||
      evidence->default_system_output_uid_hash == 0 ||
      !evidence->output_defaults_stable_and_safe_before_gate ||
      !evidence->defaults_stable_and_safe_after_vpio_start ||
      !evidence->output_defaults_stable_and_safe_after_run) {
    failures |= kOSVAPublicVPIOGateSafeOutputs;
  }

  const bool selectionSequenceIsValid =
      evidence->default_input_was_changed
          ? evidence->input_listener_sequence_at_commit >
                evidence->input_listener_sequence_before_selection
          : evidence->input_listener_sequence_at_commit ==
                evidence->input_listener_sequence_before_selection;
  if (!evidence->listeners_registered_before_default_reads ||
      evidence->input_listener_sequence_before_selection != 0 ||
      evidence->output_listener_notifications != 0 ||
      evidence->system_output_listener_notifications != 0 ||
      evidence->unexpected_input_listener_notifications != 0 ||
      !evidence->selection_comparison_matched ||
      !evidence->selection_listener_advanced ||
      !evidence->selection_readback_matched ||
      !evidence->selection_commit_sequence_stable ||
      !evidence->visible_was_default_input_at_commit ||
      !selectionSequenceIsValid ||
      evidence->input_listener_sequence_at_restore !=
          evidence->input_listener_sequence_at_commit) {
    failures |= kOSVAPublicVPIOGateListenerFence;
  }

  if (!evidence->hidden_writer_started_first ||
      evidence->initial_silence_frames == 0 ||
      !evidence->vpio_initialized_after_writer ||
      !evidence->nonce_signal_enabled_after_vpio_start ||
      evidence->writer_create_status != 0 ||
      evidence->writer_start_status != 0) {
    failures |= kOSVAPublicVPIOGateStartOrder;
  }

  if (evidence->writer_valid_timestamp_count <
          kOSVAPublicVPIOMinimumCallbackCount ||
      evidence->microphone_valid_timestamp_count <
          kOSVAPublicVPIOMinimumCallbackCount ||
      evidence->frozen_timestamp_count != 0 ||
      evidence->gapped_timestamp_count != 0) {
    failures |= kOSVAPublicVPIOGateTimestamps;
  }

  if (evidence->writer_callback_count < kOSVAPublicVPIOMinimumCallbackCount ||
      evidence->microphone_callback_count <
          kOSVAPublicVPIOMinimumCallbackCount ||
      evidence->output_callback_count < kOSVAPublicVPIOMinimumCallbackCount ||
      evidence->output_silence_frame_count == 0 ||
      !evidence->output_reference_is_bounded_silence ||
      evidence->oversized_callback_count != 0 ||
      evidence->callback_stall_count != 0) {
    failures |= kOSVAPublicVPIOGateCallbackProgress;
  }

  if (evidence->captured_frame_count < kOSVAPublicVPIOMinimumCaptureFrames ||
      evidence->matched_envelope_frame_count <
          kOSVAPublicVPIOMinimumMatchedEnvelopeFrames ||
      evidence->capture_hash == 0 || evidence->nonce_hash == 0 ||
      !isfinite(evidence->capture_rms) ||
      evidence->capture_rms < kMinimumCaptureRMS ||
      !isfinite(evidence->speech_band_correlation) ||
      evidence->speech_band_correlation < kMinimumCorrelation ||
      evidence->speech_band_correlation > 1.000001) {
    failures |= kOSVAPublicVPIOGateSignalCorrelation;
  }

  if (evidence->component_status != 0 || evidence->enable_input_status != 0 ||
      evidence->enable_output_status != 0 ||
      evidence->input_callback_status != 0 ||
      evidence->output_callback_status != 0 ||
      evidence->voice_processing_bypass_status != 0 ||
      evidence->voice_processing_bypassed ||
      evidence->initialize_status != 0 || evidence->start_status != 0 ||
      evidence->last_render_error != 0 || evidence->render_error_count != 0 ||
      evidence->known_vpio_error_count != 0) {
    failures |= kOSVAPublicVPIOGateVPIOStatus;
  }

  const bool restorationShapeIsValid =
      evidence->default_input_was_changed
          ? (evidence->default_input_ownership_preserved_at_restore &&
             evidence->restoration_target_retranslated_from_uid &&
             evidence->restoration_attempted_if_owned &&
             evidence->restoration_succeeded &&
             !evidence->restoration_skipped_after_ownership_loss)
          : (evidence->restoration_target_retranslated_from_uid &&
             !evidence->restoration_attempted_if_owned &&
             !evidence->restoration_skipped_after_ownership_loss);
  if (evidence->original_input_uid_hash == 0 ||
      !evidence->original_input_is_admissible_for_restoration ||
      !restorationShapeIsValid ||
      !evidence->final_default_input_matches_snapshot) {
    failures |= kOSVAPublicVPIOGateRestoration;
  }

  if (!evidence->gates_closed_before_stop ||
      !evidence->cancellation_handlers_installed ||
      evidence->vpio_stop_status != 0 ||
      evidence->vpio_uninitialize_status != 0 ||
      evidence->vpio_dispose_status != 0 ||
      evidence->writer_stop_status != 0 ||
      evidence->writer_destroy_status != 0 ||
      evidence->callbacks_in_flight_after_drain != 0 ||
      !evidence->callbacks_stable_after_drain || !evidence->listeners_removed ||
      !evidence->listener_callbacks_stable_after_removal) {
    failures |= kOSVAPublicVPIOGateTeardown;
  }

  return failures;
}

typedef void (*EvidenceMutation)(OSVAPublicVPIOEvidence *evidence);

typedef struct MutationCase {
  const char *name;
  EvidenceMutation mutate;
  uint64_t exact_expected_failure;
} MutationCase;

static void MutateWrongVisibleUID(OSVAPublicVPIOEvidence *evidence) {
  evidence->visible_uid_hash = OSVAPublicVPIOHashString("wrong-visible");
}

static void MutateUIDTranslationInstability(OSVAPublicVPIOEvidence *evidence) {
  evidence->endpoint_translation_stable_after_start = false;
}

static void MutateStereoInput(OSVAPublicVPIOEvidence *evidence) {
  evidence->visible_input_channels = 2;
  evidence->processed_mic_channels = 2;
}

static void MutateFormatError(OSVAPublicVPIOEvidence *evidence) {
  evidence->processed_mic_format_set_status = -10868;
  evidence->processed_mic_format_read_status = -10868;
}

static void MutateEndpointClientFormatCross(
    OSVAPublicVPIOEvidence *evidence) {
  evidence->visible_stream_format_exact = false;
}

static void MutateClientEndpointFormatCross(
    OSVAPublicVPIOEvidence *evidence) {
  evidence->processed_mic_stream_format_exact = false;
}

static void MutateMonoPlayoutFormat(OSVAPublicVPIOEvidence *evidence) {
  evidence->playout_stream_format_exact = false;
  evidence->playout_channels = 1;
}

static void MutateSilence(OSVAPublicVPIOEvidence *evidence) {
  evidence->capture_rms = 0.0;
  evidence->speech_band_correlation = 0.0;
}

static void MutateNoise(OSVAPublicVPIOEvidence *evidence) {
  evidence->capture_rms = 0.08;
  evidence->speech_band_correlation = 0.01;
}

static void MutateLowCorrelation(OSVAPublicVPIOEvidence *evidence) {
  evidence->speech_band_correlation = 0.31;
}

static void MutateFrozenTimestamp(OSVAPublicVPIOEvidence *evidence) {
  evidence->frozen_timestamp_count = 1;
}

static void MutateGappedTimestamp(OSVAPublicVPIOEvidence *evidence) {
  evidence->gapped_timestamp_count = 1;
}

static void MutateCallbackStall(OSVAPublicVPIOEvidence *evidence) {
  evidence->output_callback_count = 0;
  evidence->output_silence_frame_count = 0;
  evidence->output_reference_is_bounded_silence = false;
  evidence->callback_stall_count = 1;
}

static void MutateUnsafeOutput(OSVAPublicVPIOEvidence *evidence) {
  evidence->default_output_is_forbidden_virtual = true;
}

static void MutateDelayedOutputReadback(OSVAPublicVPIOEvidence *evidence) {
  evidence->defaults_stable_and_safe_after_vpio_start = false;
  evidence->output_defaults_stable_and_safe_after_run = false;
}

static void MutateDefaultNotification(OSVAPublicVPIOEvidence *evidence) {
  evidence->input_listener_sequence_before_selection = 1;
  evidence->output_listener_notifications = 1;
}

static void MutateWriterStartOrder(OSVAPublicVPIOEvidence *evidence) {
  evidence->hidden_writer_started_first = false;
}

static void MutateLastRenderError(OSVAPublicVPIOEvidence *evidence) {
  evidence->last_render_error = -10863;
  evidence->known_vpio_error_count = 1;
}

static void MutateFailedRestoration(OSVAPublicVPIOEvidence *evidence) {
  evidence->restoration_succeeded = false;
  evidence->final_default_input_matches_snapshot = false;
}

static void MutateInadmissibleRestorationBaseline(
    OSVAPublicVPIOEvidence *evidence) {
  evidence->original_input_uid_hash =
      OSVAPublicVPIOHashString(OSVA_PUBLIC_VPIO_HIDDEN_UID);
  evidence->original_input_is_admissible_for_restoration = false;
}

static void MutateStaleRestorationDeviceID(
    OSVAPublicVPIOEvidence *evidence) {
  evidence->restoration_target_retranslated_from_uid = false;
  evidence->restoration_succeeded = false;
  evidence->final_default_input_matches_snapshot = false;
}

static void MutateOwnershipLost(OSVAPublicVPIOEvidence *evidence) {
  evidence->default_input_ownership_preserved_at_restore = false;
  evidence->restoration_attempted_if_owned = false;
  evidence->restoration_succeeded = false;
  evidence->restoration_skipped_after_ownership_loss = true;
  evidence->final_default_input_matches_snapshot = false;
}

static void MutateFailedTeardown(OSVAPublicVPIOEvidence *evidence) {
  evidence->cancellation_handlers_installed = false;
  evidence->callbacks_in_flight_after_drain = 1;
  evidence->callbacks_stable_after_drain = false;
}

static void HashPassName(uint64_t *hash, const char *name) {
  const size_t length = strlen(name);
  for (size_t index = 0; index < length; ++index) {
    *hash ^= (uint64_t)(uint8_t)name[index];
    *hash *= UINT64_C(1099511628211);
  }
  *hash ^= (uint64_t)(uint8_t)'\n';
  *hash *= UINT64_C(1099511628211);
}

OSVAPublicVPIOSelfTestSummary OSVAPublicVPIORunSelfTests(void) {
  static const MutationCase mutations[] = {
      {"wrong-visible-uid", MutateWrongVisibleUID,
       kOSVAPublicVPIOGateIdentityTopology},
      {"uid-translation-instability", MutateUIDTranslationInstability,
       kOSVAPublicVPIOGateIdentityTopology},
      {"stereo-input", MutateStereoInput, kOSVAPublicVPIOGateFormat},
      {"format-error", MutateFormatError, kOSVAPublicVPIOGateFormat},
      {"endpoint-client-format-cross", MutateEndpointClientFormatCross,
       kOSVAPublicVPIOGateFormat},
      {"client-endpoint-format-cross", MutateClientEndpointFormatCross,
       kOSVAPublicVPIOGateFormat},
      {"mono-playout-format", MutateMonoPlayoutFormat,
       kOSVAPublicVPIOGateFormat},
      {"silence", MutateSilence, kOSVAPublicVPIOGateSignalCorrelation},
      {"noise", MutateNoise, kOSVAPublicVPIOGateSignalCorrelation},
      {"low-correlation", MutateLowCorrelation,
       kOSVAPublicVPIOGateSignalCorrelation},
      {"frozen-timestamp", MutateFrozenTimestamp,
       kOSVAPublicVPIOGateTimestamps},
      {"gapped-timestamp", MutateGappedTimestamp,
       kOSVAPublicVPIOGateTimestamps},
      {"callback-stall", MutateCallbackStall,
       kOSVAPublicVPIOGateCallbackProgress},
      {"unsafe-output-default", MutateUnsafeOutput,
       kOSVAPublicVPIOGateSafeOutputs},
      {"delayed-output-readback", MutateDelayedOutputReadback,
       kOSVAPublicVPIOGateSafeOutputs},
      {"default-mutation-notification", MutateDefaultNotification,
       kOSVAPublicVPIOGateListenerFence},
      {"writer-start-order", MutateWriterStartOrder,
       kOSVAPublicVPIOGateStartOrder},
      {"last-render-error", MutateLastRenderError,
       kOSVAPublicVPIOGateVPIOStatus},
      {"failed-restoration", MutateFailedRestoration,
       kOSVAPublicVPIOGateRestoration},
      {"inadmissible-restoration-baseline",
       MutateInadmissibleRestorationBaseline,
       kOSVAPublicVPIOGateRestoration},
      {"stale-restoration-device-id", MutateStaleRestorationDeviceID,
       kOSVAPublicVPIOGateRestoration},
      {"ownership-lost", MutateOwnershipLost,
       kOSVAPublicVPIOGateRestoration},
      {"failed-teardown", MutateFailedTeardown,
       kOSVAPublicVPIOGateTeardown},
  };

  OSVAPublicVPIOSelfTestSummary summary;
  memset(&summary, 0, sizeof(summary));
  uint64_t passSetHash = UINT64_C(1469598103934665603);

  OSVAPublicVPIOEvidence baseline = OSVAPublicVPIOBaselineEvidence();
  ++summary.test_count;
  const uint64_t baselineFailures = OSVAPublicVPIOEvaluate(&baseline);
  if (baselineFailures == 0) {
    HashPassName(&passSetHash, "baseline");
  } else {
    summary.unexpected_failure_mask |= baselineFailures;
  }

  ++summary.test_count;
  const bool forbiddenSetIsExact =
      OSVAPublicVPIOIsForbiddenOutputUID(OSVA_PUBLIC_VPIO_VISIBLE_UID) &&
      OSVAPublicVPIOIsForbiddenOutputUID(OSVA_PUBLIC_VPIO_HIDDEN_UID) &&
      OSVAPublicVPIOIsForbiddenOutputUID(
          OSVA_PUBLIC_VPIO_LEGACY_VISIBLE_UID) &&
      OSVAPublicVPIOIsForbiddenOutputUID(
          OSVA_PUBLIC_VPIO_LEGACY_HIDDEN_UID) &&
      !OSVAPublicVPIOIsForbiddenOutputUID("BuiltInSpeakerDevice") &&
      !OSVAPublicVPIOIsForbiddenOutputUID(NULL) &&
      OSVAPublicVPIOIsForbiddenRestorationInputUID(
          OSVA_PUBLIC_VPIO_HIDDEN_UID) &&
      OSVAPublicVPIOIsForbiddenRestorationInputUID(
          OSVA_PUBLIC_VPIO_LEGACY_HIDDEN_UID) &&
      !OSVAPublicVPIOIsForbiddenRestorationInputUID(
          OSVA_PUBLIC_VPIO_VISIBLE_UID) &&
      !OSVAPublicVPIOIsForbiddenRestorationInputUID(
          OSVA_PUBLIC_VPIO_LEGACY_VISIBLE_UID) &&
      OSVAPublicVPIOIsForbiddenRestorationInputUID(NULL);
  if (forbiddenSetIsExact) {
    HashPassName(&passSetHash, "forbidden-uid-set");
  } else {
    summary.unexpected_failure_mask |= kOSVAPublicVPIOGateSafeOutputs;
  }

  ++summary.test_count;
  enum { kAnalyzerFrames = 96000, kAnalyzerDelay = 960 };
  float *reference = (float *)calloc(kAnalyzerFrames, sizeof(float));
  float *capture = (float *)calloc(kAnalyzerFrames, sizeof(float));
  bool analyzerPassed = reference != NULL && capture != NULL;
  uint64_t analyzerState = UINT64_C(0x4f5356415650494f);
  if (analyzerPassed) {
    for (size_t index = 0; index < kAnalyzerFrames; ++index) {
      if ((index % 3840) == 0) {
        analyzerState ^= analyzerState << 13;
        analyzerState ^= analyzerState >> 7;
        analyzerState ^= analyzerState << 17;
      }
      const double amplitude =
          0.02 + (0.02 * (double)(1 + (analyzerState & UINT64_C(3))));
      reference[index] =
          (float)(amplitude * sin((2.0 * M_PI * 733.0 * (double)index) /
                                 48000.0));
      if (index >= kAnalyzerDelay) {
        capture[index] = 0.71F * reference[index - kAnalyzerDelay];
      }
    }
    const OSVAPublicVPIOSignalMetrics correlated =
        OSVAPublicVPIOAnalyzeSignal(reference, kAnalyzerFrames, capture,
                                    kAnalyzerFrames);
    memset(capture, 0, kAnalyzerFrames * sizeof(float));
    const OSVAPublicVPIOSignalMetrics silent =
        OSVAPublicVPIOAnalyzeSignal(reference, kAnalyzerFrames, capture,
                                    kAnalyzerFrames);
    uint64_t noiseEnvelopeState = UINT64_C(0x9e3779b97f4a7c15);
    uint64_t noiseSampleState = UINT64_C(0xd1b54a32d192ed03);
    double noiseAmplitude = 0.04;
    for (size_t index = 0; index < kAnalyzerFrames; ++index) {
      if ((index % 3840) == 0) {
        noiseEnvelopeState ^= noiseEnvelopeState << 13;
        noiseEnvelopeState ^= noiseEnvelopeState >> 7;
        noiseEnvelopeState ^= noiseEnvelopeState << 17;
        noiseAmplitude =
            0.02 * (double)(1 + (noiseEnvelopeState & UINT64_C(3)));
      }
      noiseSampleState ^= noiseSampleState << 13;
      noiseSampleState ^= noiseSampleState >> 7;
      noiseSampleState ^= noiseSampleState << 17;
      const int32_t centered =
          (int32_t)(noiseSampleState & UINT64_C(0xffff)) -
                               INT32_C(32768);
      capture[index] =
          (float)(noiseAmplitude * ((double)centered / 32768.0));
    }
    const OSVAPublicVPIOSignalMetrics noise =
        OSVAPublicVPIOAnalyzeSignal(reference, kAnalyzerFrames, capture,
                                    kAnalyzerFrames);
    analyzerPassed =
        correlated.speech_band_correlation > 0.9 &&
        correlated.matched_envelope_frame_count >=
            kOSVAPublicVPIOMinimumMatchedEnvelopeFrames &&
        correlated.capture_rms > kMinimumCaptureRMS &&
        silent.capture_rms == 0.0 && silent.speech_band_correlation == 0.0 &&
        noise.capture_rms > kMinimumCaptureRMS &&
        noise.speech_band_correlation < 0.35;
  }
  free(reference);
  free(capture);
  if (analyzerPassed) {
    HashPassName(&passSetHash, "signal-analyzer");
  } else {
    summary.unexpected_failure_mask |= kOSVAPublicVPIOGateSignalCorrelation;
  }

  const size_t mutationCount = sizeof(mutations) / sizeof(mutations[0]);
  summary.mutant_count = (uint32_t)mutationCount;
  for (size_t index = 0; index < mutationCount; ++index) {
    OSVAPublicVPIOEvidence mutant = baseline;
    mutations[index].mutate(&mutant);
    const uint64_t failures = OSVAPublicVPIOEvaluate(&mutant);
    ++summary.test_count;
    if (failures == mutations[index].exact_expected_failure) {
      HashPassName(&passSetHash, mutations[index].name);
    } else {
      summary.unexpected_failure_mask |=
          failures ^ mutations[index].exact_expected_failure;
      if (summary.unexpected_failure_mask == 0) {
        summary.unexpected_failure_mask = UINT64_C(1) << 63;
      }
    }
  }

  summary.pass_set_hash = passSetHash;
  summary.passed = summary.unexpected_failure_mask == 0 &&
                   summary.test_count == 26 && summary.mutant_count == 23;
  return summary;
}
