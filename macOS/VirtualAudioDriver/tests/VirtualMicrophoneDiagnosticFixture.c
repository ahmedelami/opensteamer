#include "OpensteamerVirtualMicrophoneDriver.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

int main(int argc, char **argv) {
  if (argc != 4) return 2;
  OSVADiagnosticSnapshot snapshot = {0};
  snapshot.schema_version = kOSVADiagnosticSnapshotSchemaVersion;
  snapshot.struct_size = sizeof(snapshot);
  snapshot.snapshot_sequence = strtoull(argv[2], NULL, 10);
  snapshot.captured_host_ticks = strtoull(argv[3], NULL, 10);
  snapshot.driver_instance_generation = 77;
  snapshot.driver_lifecycle_sequence = 9;
  snapshot.core_lifecycle_sequence = 8;
  snapshot.host_ticks_per_second = 24000000;
  snapshot.client_slot_capacity = kOSVADiagnosticClientSlotCapacity;
  snapshot.last_issued_seed = 7;
  snapshot.last_issued_session_id = 11;
  snapshot.global_start_transition_count = 1;
  snapshot.global_stop_transition_count = 1;
  snapshot.seed_create_count = 1;
  snapshot.seed_clear_count = 1;
  snapshot.invariant_flags =
      kOSVADiagnosticSnapshotCoreInitialized |
      kOSVADiagnosticInvariantGlobalMatchesCoreSlots |
      kOSVADiagnosticInvariantEndpointsMatchCoreSlots |
      kOSVADiagnosticInvariantDriverStartsMatchCoreSlots |
      kOSVADiagnosticInvariantIdleImpliesClockCleared |
      kOSVADiagnosticInvariantActiveImpliesClockValid |
      kOSVADiagnosticInvariantSlotCountsWithinCapacity |
      kOSVADiagnosticInvariantStartStopBalancedAtIdle |
      kOSVADiagnosticInvariantSeedCreateClearBalancedAtIdle |
      kOSVADiagnosticInvariantRingGenerationMatchesCurrentSeed |
      kOSVADiagnosticInvariantNoActiveSlotReferencesRetiredGeneration;
  const char *mode = argv[1];
  if (strcmp(mode, "active") == 0) {
    snapshot.invariant_flags |= kOSVADiagnosticSnapshotTimelineActive;
    snapshot.timeline_seed = snapshot.current_seed_generation = 7;
    snapshot.anchor_host_ticks = 50;
    snapshot.active_client_count = snapshot.visible_input_active_count = 1;
    snapshot.core_active_slot_count = snapshot.core_active_slot_bitmap = 1;
    snapshot.driver_registered_count = snapshot.driver_started_count = 1;
    snapshot.visible_driver_registered_count = snapshot.visible_driver_started_count = 1;
    snapshot.driver_registered_slot_bitmap = snapshot.driver_started_slot_bitmap = 1;
  } else if (strcmp(mode, "schema") == 0) {
    snapshot.schema_version += 1;
  } else if (strcmp(mode, "struct-size") == 0) {
    snapshot.struct_size -= 1;
  } else if (strcmp(mode, "missing-invariant") == 0) {
    snapshot.invariant_flags &= ~kOSVADiagnosticInvariantGlobalMatchesCoreSlots;
  } else if (strcmp(mode, "unknown-flag") == 0) {
    snapshot.invariant_flags |= UINT64_C(1) << 63;
  } else if (strcmp(mode, "retained-seed") == 0) {
    snapshot.timeline_seed = 7;
  } else if (strcmp(mode, "retained-slot") == 0) {
    snapshot.core_active_slot_bitmap = 1;
  } else if (strcmp(mode, "count-mismatch") == 0) {
    snapshot.visible_input_active_count = 1;
  } else if (strcmp(mode, "count-overflow") == 0) {
    snapshot.active_client_count = UINT64_MAX;
  } else if (strcmp(mode, "unbalanced-stop") == 0) {
    snapshot.global_stop_transition_count = 0;
  } else if (strcmp(mode, "work-loop-active") == 0) {
    snapshot.io_work_loop[0].current_count = 1;
  } else if (strcmp(mode, "new-instance") == 0) {
    snapshot.driver_instance_generation += 1;
  } else if (strcmp(mode, "new-lifecycle") == 0) {
    snapshot.driver_lifecycle_sequence += 1;
  } else if (strcmp(mode, "new-session") == 0) {
    snapshot.last_issued_session_id += 1;
  } else if (strcmp(mode, "new-seed") == 0) {
    snapshot.last_issued_seed += 1;
  } else if (strcmp(mode, "idle") != 0) {
    return 3;
  }
  return fwrite(&snapshot, sizeof(snapshot), 1, stdout) == 1 ? 0 : 4;
}
