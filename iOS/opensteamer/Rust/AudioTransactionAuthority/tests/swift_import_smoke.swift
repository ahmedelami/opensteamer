import OpensteamerAudioTransactionAuthority

let abiVersion: UInt32 = OSATA_ABI_VERSION
let runtimeOK: UInt32 = OSATA_RUNTIME_OK
let category: UInt32 = OSATA_CATEGORY_PLAYBACK
let mode: UInt32 = OSATA_MODE_DEFAULT
let nativeOutcome: UInt32 = OSATA_NATIVE_OUTCOME_ACCEPTED
let proofOutcome: UInt32 = OSATA_PROOF_OUTCOME_ACCEPTED
let observation: UInt32 = OSATA_OBSERVATION_EXPECTED_CURRENT_APP_OPERATION
let transactionState: UInt32 = OSATA_TRANSACTION_STATE_CONSUMED
let drainState: UInt32 = OSATA_DRAIN_BINDING_STATE_BOUND
let aborted: UInt32 = OSATA_DECISION_ABORTED_UNPUBLISHED
let decision: UInt32 = OSATA_DECISION_COMPLETED
let deviceBound: UInt32 = OSATA_DECISION_DEVICE_BOUND
let staleDevice: UInt32 = OSATA_IGNORE_STALE_DEVICE_GENERATION
let rejection: UInt32 = OSATA_REJECTION_INVALID_INPUT
let ignoreReason: UInt32 = OSATA_IGNORE_EXACT_DUPLICATE

_ = (
    abiVersion,
    runtimeOK,
    category,
    mode,
    nativeOutcome,
    proofOutcome,
    observation,
    transactionState,
    drainState,
    aborted,
    decision,
    deviceBound,
    staleDevice,
    rejection,
    ignoreReason
)
