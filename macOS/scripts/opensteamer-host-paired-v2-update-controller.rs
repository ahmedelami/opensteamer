//! Pairing-preserving updater for the committed isolated `opensteamer Host.app`.
//!
//! The historical post-v20 controller remains an immutable included implementation source for
//! its reviewed low-level filesystem, launchd, signature, process, lock, and deployment proofs.
//! This controller owns a disjoint v2 journal/pointer namespace, never starts an interactive
//! host, never resets pairing, and rolls back to the exact committed isolated host rather than
//! to v20.

#[allow(dead_code)]
mod paired_v2 {
    include!(env!("OPENSTEAMER_PAIRED_V2_INCLUDED_SOURCE"));

    const V2_PREFLIGHT_MODE: &str = "--verify-paired-v2-host-update-preflight";
    const V2_EXECUTE_MODE: &str = "--execute-authorized-paired-v2-host-update";
    const V2_ROLLBACK_MODE: &str = "--rollback-authorized-paired-v2-host-update";
    const V2_SELF_TEST_MODE: &str = "--self-test-paired-v2-host-update";
    const V2_EXPECTED_REPO: &str = "/Users/ahmed/Documents/Codex/opensteamer";

    const V2_UPDATE_ROOT: &str =
        "/Users/ahmed/Library/Application Support/opensteamer/paired-host-updates-v2";
    const V2_ACTIVE_UPDATE: &str =
        "/Users/ahmed/Library/Application Support/opensteamer/active-paired-host-update-v2";
    const V2_UPDATE_LOCK: &str = UPDATE_LOCK;
    const V2_JOURNAL_HEADER: &str = "OPENSTEAMER_PAIRED_HOST_UPDATE_V2";
    const HIDDEN_INSTALL_PREFIX: &str = ".opensteamer-paired-v2-install-";
    const NEW_LAUNCH_AGENT_LABEL: &str = NEW_LABEL;
    const PROTECTED_LEGACY_LAUNCH_AGENT_LABEL: &str = LEGACY_LABEL;
    const REVIEWED_LAUNCH_AGENT_PATH: &str = NEW_PLIST;
    const REVIEWED_LAUNCH_AGENT_SHA256: &str = NEW_PLIST_SHA256;

    const COMMITTED_V1_POINTER: &str =
        "/Users/ahmed/Library/Application Support/opensteamer/active-post-v20-host-update-v1";
    const COMMITTED_V1_EVIDENCE: &str = "/Users/ahmed/Library/Application Support/opensteamer/host-updates/post-v20-update-1785755610-30384-e2654f34-367f-4767-93f8-76d27a7e2c10";
    const COMMITTED_V1_POINTER_SHA256: &str =
        "f6e76a7d67e424fe319f12ef505d94b6826cc5c36f0415644832c853e9788cdf";
    const COMMITTED_V1_JOURNAL_SHA256: &str =
        "1c6051a9538901c0002b126b373c9476b93aa48c220127358e7e08e2b58d5ff5";
    const COMMITTED_V1_RESULT_SHA256: &str =
        "22127aa5523e3efa468822044100fb2fd1cc5ceb97552377c986b1f5c1a15d77";
    const COMMITTED_V1_PROVENANCE_SHA256: &str =
        "ff747bc792b4781b709f3650941a28eaba4235b1fdb87a76ed079ad930eb95d1";
    const COMMITTED_V1_SOURCE_ARCHIVE_SHA256: &str =
        "7f0fc3bc8efb16958c8c424e159188e2b9fc2b1ee8747f25a0a2261ee7091b9f";
    const COMMITTED_V1_INSTALL_HOLD_NAME_SHA256: &str =
        "ee67e4a38815acebb71b3a35fd3f83e0faa9c8eec0237b96be3ae91bc77afa43";

    const CURRENT_BASELINE_APP: &str = "/Users/ahmed/Library/Application Support/opensteamer/host-updates/post-v20-update-1785755610-30384-e2654f34-367f-4767-93f8-76d27a7e2c10/deployment-reference/opensteamer Host.app";
    const CURRENT_BASELINE_SOURCE_EXPORT: &str = "/Users/ahmed/Library/Application Support/opensteamer/host-updates/post-v20-update-1785755610-30384-e2654f34-367f-4767-93f8-76d27a7e2c10/source-export";
    const CURRENT_BASELINE_EXECUTABLE_SHA256: &str =
        "ae7638a512440bb567d5e07f1067d8e5035bb59951e38c0559a74e4afa1d2e52";
    const CURRENT_BASELINE_CDHASH: &str = "468cbff663853fc36f184946194cda0f4e146be9";
    const CURRENT_BASELINE_VERIFY_BUNDLE_SHA256: &str =
        "02a348a88d25b76ab95d45620d823339212bb53ee0f39bfb3a52f04240d3d745";
    const CURRENT_BASELINE_VERIFY_LIVE_PROCESS_SHA256: &str =
        "0e56403570362c6d59ea86dc10d3cc53d7a5461d4a2f6c78d6e6c86dd13a4b41";
    const CURRENT_BASELINE_VERIFY_DEPLOYMENT_SHA256: &str =
        "6c4a1598d2b78550202b5d23903f0dd64e117384cd962a2c18c73e74795fe4de";
    const CURRENT_BASELINE_VERIFY_LAUNCH_STATE_SHA256: &str =
        "27c36f8adec05c22216955cb404d6732ceaa6065477e5bb1570f2d41e84db7a9";
    const CURRENT_BASELINE_LAUNCH_AGENT_SOURCE_SHA256: &str =
        "7cdcf2d1517dc9ec1ae49b6fbbaf293c77afd958f697878d44f3b3c8e9c7e550";

    const ISOLATED_PAIRING_IDENTITY_ACCOUNT: &str = "worldwide-host-identity-v1";
    const ISOLATED_PAIRING_VIEWER_ACCOUNT: &str = "worldwide-paired-viewer-v1";
    const PAIRED_AVAILABILITY_MARKER_PREFIX: &str =
        "[info] Worldwide paired-device availability is online";
    const REQUIRED_FACE_TIME_PATCH_COMMIT: &str = "bdced4105fb9284cab620fce35bf638866c46cde";
    const EXPECTED_SOURCE_BRANCH: &str = "agent/auto-select-iphone-microphone";
    const EXPECTED_REMOTE: &str = "https://github.com/ahmedelami/opensteamer.git";

    #[derive(Clone, Copy, Debug, Eq, Ord, PartialEq, PartialOrd)]
    enum V2State {
        Begun,
        SourceExported,
        BuildVerified,
        StopInitiated,
        InstallHoldVerified,
        CurrentStopped,
        CurrentHeld,
        NewPublished,
        PersistentBootstrapped,
        ReadyVerified,
        Committed,
        RollbackStarted,
        FailedNewArchived,
        CurrentRestored,
        CurrentBootstrapped,
        RolledBack,
        CriticalFailure,
    }

    impl V2State {
        fn token(self) -> &'static str {
            match self {
                Self::Begun => "BEGUN",
                Self::SourceExported => "SOURCE_EXPORTED",
                Self::BuildVerified => "BUILD_VERIFIED",
                Self::StopInitiated => "STOP_INITIATED",
                Self::InstallHoldVerified => "INSTALL_HOLD_VERIFIED",
                Self::CurrentStopped => "CURRENT_STOPPED",
                Self::CurrentHeld => "CURRENT_HELD",
                Self::NewPublished => "NEW_PUBLISHED",
                Self::PersistentBootstrapped => "PERSISTENT_BOOTSTRAPPED",
                Self::ReadyVerified => "READY_VERIFIED",
                Self::Committed => "COMMITTED",
                Self::RollbackStarted => "ROLLBACK_STARTED",
                Self::FailedNewArchived => "FAILED_NEW_ARCHIVED",
                Self::CurrentRestored => "CURRENT_RESTORED",
                Self::CurrentBootstrapped => "CURRENT_BOOTSTRAPPED",
                Self::RolledBack => "ROLLED_BACK",
                Self::CriticalFailure => "CRITICAL_FAILURE",
            }
        }

        fn parse(value: &str) -> Option<Self> {
            Some(match value {
                "BEGUN" => Self::Begun,
                "SOURCE_EXPORTED" => Self::SourceExported,
                "BUILD_VERIFIED" => Self::BuildVerified,
                "STOP_INITIATED" => Self::StopInitiated,
                "INSTALL_HOLD_VERIFIED" => Self::InstallHoldVerified,
                "CURRENT_STOPPED" => Self::CurrentStopped,
                "CURRENT_HELD" => Self::CurrentHeld,
                "NEW_PUBLISHED" => Self::NewPublished,
                "PERSISTENT_BOOTSTRAPPED" => Self::PersistentBootstrapped,
                "READY_VERIFIED" => Self::ReadyVerified,
                "COMMITTED" => Self::Committed,
                "ROLLBACK_STARTED" => Self::RollbackStarted,
                "FAILED_NEW_ARCHIVED" => Self::FailedNewArchived,
                "CURRENT_RESTORED" => Self::CurrentRestored,
                "CURRENT_BOOTSTRAPPED" => Self::CurrentBootstrapped,
                "ROLLED_BACK" => Self::RolledBack,
                "CRITICAL_FAILURE" => Self::CriticalFailure,
                _ => return None,
            })
        }
    }

    struct V2Journal {
        path: PathBuf,
        file: File,
        state: V2State,
        healthy: bool,
    }

    impl V2Journal {
        fn create(path: &Path) -> Result<Self> {
            let mut file = OpenOptions::new()
                .create_new(true)
                .read(true)
                .write(true)
                .mode(0o600)
                .custom_flags(O_NOFOLLOW | 0x0100_0000)
                .open(path)
                .map_err(|error| ControllerError(format!("cannot create v2 journal: {error}")))?;
            validate_open_journal_file(path, &file)?;
            writeln!(file, "{V2_JOURNAL_HEADER}")?;
            file.sync_all()?;
            fsync_parent(path)?;
            let mut journal = Self {
                path: path.to_path_buf(),
                file,
                state: V2State::Begun,
                healthy: true,
            };
            journal.record(V2State::Begun, &[])?;
            Ok(journal)
        }

        fn open(path: &Path) -> Result<Self> {
            require_regular(path, 0o600)?;
            let mut file = OpenOptions::new()
                .read(true)
                .write(true)
                .custom_flags(O_NOFOLLOW | 0x0100_0000)
                .open(path)?;
            validate_open_journal_file(path, &file)?;
            let bytes = read_open_journal_bytes(&mut file)?;
            let complete_length = bytes
                .iter()
                .rposition(|byte| *byte == b'\n')
                .map_or(0, |index| index + 1);
            let complete_text = std::str::from_utf8(&bytes[..complete_length])
                .map_err(|_| ControllerError("v2 journal is not UTF-8".to_owned()))?;
            let state = parse_v2_journal(complete_text)?;
            if complete_length != bytes.len() {
                if !is_plausible_v2_torn_tail(&bytes[complete_length..], state) {
                    return Err(ControllerError(
                        "v2 journal has an implausible incomplete final record".to_owned(),
                    ));
                }
                validate_open_journal_file(path, &file)?;
                file.set_len(complete_length as u64)?;
                file.sync_all()?;
            }
            file.seek(SeekFrom::End(0))?;
            Ok(Self {
                path: path.to_path_buf(),
                file,
                state,
                healthy: true,
            })
        }

        fn record(&mut self, state: V2State, fields: &[(&str, String)]) -> Result<()> {
            self.require_healthy()?;
            validate_v2_transition(self.state, state)?;
            validate_v2_fields(state, fields)?;
            let mut record = Vec::new();
            write!(record, "STATE {}", state.token())?;
            for (key, value) in fields {
                write!(record, " {key}={value}")?;
            }
            record.push(b'\n');
            let prior_length = self.file.seek(SeekFrom::End(0))?;
            self.healthy = false;
            if let Err(error) = self
                .file
                .write_all(&record)
                .and_then(|_| self.file.sync_all())
            {
                let recovery = self.restore_after_failed_append(prior_length);
                return match recovery {
                    Ok(()) => Err(ControllerError(format!(
                        "cannot durably append v2 journal record: {error}"
                    ))),
                    Err(recovery_error) => Err(ControllerError(format!(
                        "cannot durably append v2 journal record ({error}) or restore prior length ({recovery_error})"
                    ))),
                };
            }
            validate_open_journal_file(&self.path, &self.file)?;
            self.state = state;
            self.healthy = true;
            Ok(())
        }

        fn require_healthy(&mut self) -> Result<()> {
            if !self.healthy {
                return Err(ControllerError(
                    "v2 journal is poisoned after an unrecovered append failure".to_owned(),
                ));
            }
            if let Err(error) = validate_open_journal_file(&self.path, &self.file) {
                self.healthy = false;
                return Err(error);
            }
            Ok(())
        }

        fn restore_after_failed_append(&mut self, prior_length: u64) -> Result<()> {
            self.file.set_len(prior_length)?;
            self.file.sync_all()?;
            validate_open_journal_file(&self.path, &self.file)?;
            let bytes = read_open_journal_bytes(&mut self.file)?;
            if bytes.len() as u64 != prior_length || !bytes.ends_with(b"\n") {
                return Err(ControllerError(
                    "v2 journal append recovery did not restore prior durable length".to_owned(),
                ));
            }
            let text = std::str::from_utf8(&bytes)
                .map_err(|_| ControllerError("recovered v2 journal is not UTF-8".to_owned()))?;
            if parse_v2_journal(text)? != self.state {
                return Err(ControllerError(
                    "v2 journal append recovery did not restore prior state".to_owned(),
                ));
            }
            self.file.seek(SeekFrom::End(0))?;
            self.healthy = true;
            Ok(())
        }
    }

    struct V2Layout {
        repo: PathBuf,
        evidence: PathBuf,
        source_tar: PathBuf,
        source_export: PathBuf,
        stage_output: PathBuf,
        staged_app: PathBuf,
        deployment_reference_dir: PathBuf,
        deployment_reference_app: PathBuf,
        scratch: PathBuf,
        rollback_dir: PathBuf,
        rollback_app: PathBuf,
        failed_dir: PathBuf,
        failed_app: PathBuf,
        rollback_reserve: PathBuf,
        install_hold_root: PathBuf,
        install_hold: PathBuf,
        journal: PathBuf,
        result: PathBuf,
    }

    enum V2Command {
        Preflight(String),
        Execute(String),
        Rollback(String),
        SelfTest,
        ProbeLock {
            runtime: String,
            lock: String,
            pid: String,
        },
    }

    impl V2Layout {
        fn new(repo: PathBuf, evidence: PathBuf, nonce: &str) -> Self {
            let stage_output = evidence.join("staged-output");
            let deployment_reference_dir = evidence.join("deployment-reference");
            let rollback_dir = evidence.join("rollback-current");
            let failed_dir = evidence.join("failed-new");
            let install_hold_root = PathBuf::from(format!(
                "/Applications/.opensteamer-paired-v2-install-{nonce}"
            ));
            Self {
                repo,
                source_tar: evidence.join("source.tar"),
                source_export: evidence.join("source-export"),
                staged_app: stage_output.join("opensteamer Host.app"),
                stage_output,
                deployment_reference_app: deployment_reference_dir.join("opensteamer Host.app"),
                deployment_reference_dir,
                scratch: evidence.join("swiftpm-scratch"),
                rollback_app: rollback_dir.join("opensteamer Host.app"),
                rollback_dir,
                failed_app: failed_dir.join("opensteamer Host.app"),
                failed_dir,
                rollback_reserve: evidence.join("rollback-reserve.bin"),
                install_hold: install_hold_root.join("opensteamer Host.app"),
                install_hold_root,
                journal: evidence.join("journal.log"),
                result: evidence.join("result.txt"),
                evidence,
            }
        }
    }

    pub fn entry() {
        if let Err(error) = paired_v2_real_main() {
            eprintln!("opensteamer paired-v2 update controller: {error}");
            std::process::exit(1);
        }
    }

    fn paired_v2_real_main() -> Result<()> {
        let arguments: Vec<String> = env::args().collect();
        verify_optimized_binary_scrub()?;
        match parse_v2_command(&arguments)? {
            V2Command::Preflight(repo) => {
                let repo = canonical_repo(&repo)?;
                verify_machine_contract()?;
                let _transaction_lock = acquire_update_transaction_lock()?;
                verify_committed_v1_baseline()?;
                let generation = verify_paired_v2_runtime()?;
                verify_paired_v2_git_provenance(&repo, false)?;
                verify_isolated_pairing_items_present()?;
                require_path_absent(Path::new(V2_ACTIVE_UPDATE), "active paired-v2 pointer")?;
                println!(
                    "PAIRED_V2_UPDATE_PREFLIGHT_OK pid={} runs={} baseline=sole-ready pairing=preserved v1=immutable v2=absent",
                    generation.pid, generation.runs
                );
                Ok(())
            }
            V2Command::Execute(repo) => execute_paired_v2_update(canonical_repo(&repo)?),
            V2Command::Rollback(repo) => rollback_existing_paired_v2_update(canonical_repo(&repo)?),
            V2Command::SelfTest => paired_v2_self_test(),
            V2Command::ProbeLock { runtime, lock, pid } => {
                if runtime != LOCK_DIRECTORY || lock != LOCK_FILE {
                    return Err(ControllerError(
                        "lock probe paths differ from canonical shared lock".to_owned(),
                    ));
                }
                let pid = parse_positive_u32(&pid, "lock-holder PID")?;
                prove_lock_holder(pid, Duration::from_secs(4))?;
                println!("lock_holder={pid}");
                Ok(())
            }
        }
    }

    fn parse_v2_command(arguments: &[String]) -> Result<V2Command> {
        match arguments {
            [_, mode, repo] if mode == V2_PREFLIGHT_MODE => {
                Ok(V2Command::Preflight(repo.clone()))
            }
            [_, mode, repo] if mode == V2_EXECUTE_MODE => Ok(V2Command::Execute(repo.clone())),
            [_, mode, repo] if mode == V2_ROLLBACK_MODE => Ok(V2Command::Rollback(repo.clone())),
            [_, mode] if mode == V2_SELF_TEST_MODE => Ok(V2Command::SelfTest),
            [_, mode, runtime, lock, pid] if mode == PROBE_LOCK_MODE => {
                Ok(V2Command::ProbeLock {
                    runtime: runtime.clone(),
                    lock: lock.clone(),
                    pid: pid.clone(),
                })
            }
            _ => Err(ControllerError(format!(
                "usage: {} {{{V2_PREFLIGHT_MODE}|{V2_EXECUTE_MODE}|{V2_ROLLBACK_MODE}}} <canonical-repo>\n       {} {V2_SELF_TEST_MODE}\n       {} {PROBE_LOCK_MODE} <runtime-dir> <lock-file> <pid>",
                arguments.first().map_or("controller", String::as_str),
                arguments.first().map_or("controller", String::as_str),
                arguments.first().map_or("controller", String::as_str),
            ))),
        }
    }

    fn verify_optimized_binary_scrub() -> Result<()> {
        const MAX_CONTROLLER_BYTES: u64 = 64 * 1_024 * 1_024;
        const FORBIDDEN_MARKER_HEX: [&str; 11] = [
            "2d2d72657365742d776f726c64776964652d70616972696e67",
            "2d2d656d69742d66726573682d776f726c64776964652d70616972696e67",
            "776169745f666f725f696e7465726163746976655f70616972696e67",
            "2d2d657865637574652d617574686f72697a65642d706f73742d7632302d686f73742d7570646174652d776974682d72657669657765642d7072656275696c74",
            "72657669657765642d7072656275696c74",
            "696e7669746174696f6e",
            "2d2d7665726966792d706f73742d7632302d686f73742d7570646174652d707265666c69676874",
            "2d2d657865637574652d617574686f72697a65642d706f73742d7632302d686f73742d757064617465",
            "2d2d726f6c6c6261636b2d617574686f72697a65642d706f73742d7632302d686f73742d757064617465",
            "2d2d73656c662d746573742d706f73742d7632302d686f73742d757064617465",
            "2d2d696e7374616c6c2d7072656275696c742d686f7374",
        ];

        let executable = env::current_exe().map_err(|error| {
            ControllerError(format!("cannot resolve the paired-v2 controller: {error}"))
        })?;
        let mut file = File::open(&executable).map_err(|error| {
            ControllerError(format!("cannot inspect the paired-v2 controller: {error}"))
        })?;
        let before = file.metadata()?;
        if !before.file_type().is_file()
            || before.nlink() != 1
            || before.len() == 0
            || before.len() > MAX_CONTROLLER_BYTES
        {
            return Err(ControllerError(
                "paired-v2 controller binary has unsafe metadata".to_owned(),
            ));
        }
        let mut bytes = Vec::with_capacity(before.len() as usize);
        Read::by_ref(&mut file)
            .take(MAX_CONTROLLER_BYTES + 1)
            .read_to_end(&mut bytes)?;
        let after = file.metadata()?;
        if bytes.len() as u64 != before.len()
            || after.dev() != before.dev()
            || after.ino() != before.ino()
            || after.len() != before.len()
        {
            return Err(ControllerError(
                "paired-v2 controller changed while being scrub-verified".to_owned(),
            ));
        }
        for (index, encoded) in FORBIDDEN_MARKER_HEX.iter().enumerate() {
            let marker = decode_marker_hex(encoded)?;
            if bytes
                .windows(marker.len())
                .any(|window| window == marker.as_slice())
            {
                return Err(ControllerError(format!(
                    "optimized paired-v2 controller retained forbidden legacy marker {index}"
                )));
            }
        }
        Ok(())
    }

    fn decode_marker_hex(encoded: &str) -> Result<Vec<u8>> {
        if encoded.len() % 2 != 0 {
            return Err(ControllerError(
                "paired-v2 binary scrub marker has odd length".to_owned(),
            ));
        }
        encoded
            .as_bytes()
            .chunks_exact(2)
            .map(|pair| {
                let high = decode_hex_nibble(pair[0])?;
                let low = decode_hex_nibble(pair[1])?;
                Ok((high << 4) | low)
            })
            .collect()
    }

    fn decode_hex_nibble(value: u8) -> Result<u8> {
        match value {
            b'0'..=b'9' => Ok(value - b'0'),
            b'a'..=b'f' => Ok(value - b'a' + 10),
            _ => Err(ControllerError(
                "paired-v2 binary scrub marker is not lowercase hexadecimal".to_owned(),
            )),
        }
    }

    fn execute_paired_v2_update(repo: PathBuf) -> Result<()> {
        verify_machine_contract()?;
        let transaction_lock = acquire_update_transaction_lock_at(Path::new(V2_UPDATE_LOCK))?;
        verify_committed_v1_baseline()?;
        let initial_generation = verify_paired_v2_runtime()?;
        verify_isolated_pairing_items_present()?;
        let provenance = verify_paired_v2_git_provenance(&repo, true)?;
        require_path_absent(Path::new(V2_ACTIVE_UPDATE), "active paired-v2 pointer")?;
        require_available_bytes(
            Path::new(PRIVATE_ROOT),
            2 * 1_024 * 1_024 * 1_024,
            "before creating paired-v2 update evidence",
        )?;

        let nonce = new_nonce()?;
        let evidence = PathBuf::from(V2_UPDATE_ROOT).join(format!(
            "paired-v2-update-{}-{}-{}",
            unix_seconds()?,
            std::process::id(),
            nonce
        ));
        create_private_directory(Path::new(V2_UPDATE_ROOT))?;
        create_private_directory(&evidence)?;
        let layout = V2Layout::new(repo, evidence, &nonce);
        create_private_directory(&layout.rollback_dir)?;
        create_private_directory(&layout.failed_dir)?;
        let mut journal = V2Journal::create(&layout.journal)?;
        record_v2_install_hold_name(&layout)?;

        let result =
            perform_paired_v2_update(&layout, &mut journal, &provenance, &initial_generation);
        match result {
            Ok(()) => Ok(()),
            Err(primary) => {
                if journal.state == V2State::Committed {
                    let _ = write_result(
                        &layout.result,
                        "success-with-warning",
                        Some(&primary.to_string()),
                    );
                    eprintln!(
                        "warning: paired-v2 update committed but final reporting failed: {primary}"
                    );
                    return Ok(());
                }
                let pointer_absent_before_stop = journal.state == V2State::StopInitiated
                    && matches!(
                        fs::symlink_metadata(V2_ACTIVE_UPDATE),
                        Err(error) if error.kind() == std::io::ErrorKind::NotFound
                    );
                let crossed_stop = journal.state >= V2State::StopInitiated
                    && journal.state < V2State::Committed
                    && !pointer_absent_before_stop;
                if !crossed_stop {
                    if layout.rollback_reserve.exists() {
                        let _ = release_rollback_reserve(&layout.rollback_reserve);
                    }
                    let _ = archive_v2_install_hold_if_present(&layout);
                    let _ = write_result(
                        &layout.result,
                        "failed-before-stop",
                        Some(&primary.to_string()),
                    );
                    return Err(primary);
                }
                verify_v2_active_pointer(&layout.evidence)?;
                match rollback_to_current_baseline(&layout, &mut journal, &transaction_lock) {
                    Ok(()) => {
                        write_result(&layout.result, "rolled-back", Some(&primary.to_string()))?;
                        retire_v2_active_pointer(&layout)?;
                        Err(ControllerError(format!(
                            "update failed and exact current isolated baseline was restored; evidence={}: {primary}",
                            layout.evidence.display()
                        )))
                    }
                    Err(rollback) => {
                        let _ = journal.record(
                            V2State::CriticalFailure,
                            &[("phase", "rollback".to_owned())],
                        );
                        let _ = write_result(
                            &layout.result,
                            "critical-failure",
                            Some(&format!("primary={primary}; rollback={rollback}")),
                        );
                        Err(ControllerError(format!(
                            "CRITICAL: paired-v2 update and rollback both failed; keep host offline; evidence={}: primary={primary}; rollback={rollback}",
                            layout.evidence.display()
                        )))
                    }
                }
            }
        }
    }

    fn perform_paired_v2_update(
        layout: &V2Layout,
        journal: &mut V2Journal,
        provenance: &Provenance,
        initial_generation: &LaunchGeneration,
    ) -> Result<()> {
        export_v2_source(layout, provenance)?;
        journal.record(
            V2State::SourceExported,
            &[
                ("commit", provenance.commit.clone()),
                ("tree", provenance.tree.clone()),
                ("initial_pid", initial_generation.pid.to_string()),
            ],
        )?;

        build_and_verify_v2_staged_app(layout)?;
        prepare_v2_deployment_reference(layout)?;
        journal.record(
            V2State::BuildVerified,
            &[(
                "executable_sha256",
                sha256(&layout.staged_app.join("Contents/MacOS/CaptureServer"))?,
            )],
        )?;

        require_available_bytes(
            Path::new(PRIVATE_ROOT),
            1_024 * 1_024 * 1_024,
            "after staging and immediately before stopping the current isolated host",
        )?;
        verify_v2_deployment_reference(layout)?;
        verify_isolated_pairing_items_present()?;
        verify_v1_pointer_unchanged()?;
        let revalidated = verify_paired_v2_runtime()?;
        if revalidated.pid != initial_generation.pid
            || revalidated.runs != initial_generation.runs
            || revalidated.process_start != initial_generation.process_start
            || revalidated.nonce != initial_generation.nonce
            || revalidated.lock_device != initial_generation.lock_device
            || revalidated.lock_inode != initial_generation.lock_inode
        {
            return Err(ControllerError(
                "current isolated launch generation changed during the build".to_owned(),
            ));
        }

        let reserve = allocate_rollback_reserve(&layout.rollback_reserve, 8 * 1_024 * 1_024)?;
        journal.record(
            V2State::StopInitiated,
            &[
                ("reserve_device", reserve.0.to_string()),
                ("reserve_inode", reserve.1.to_string()),
                ("reserve_bytes", reserve.2.to_string()),
            ],
        )?;
        publish_v2_active_pointer(&layout.evidence)?;
        prepare_v2_install_hold(layout)?;
        journal.record(V2State::InstallHoldVerified, &[])?;

        verify_v2_active_pointer(&layout.evidence)?;
        verify_v2_deployment_reference(layout)?;
        verify_isolated_pairing_items_present()?;
        verify_v1_pointer_unchanged()?;
        let final_generation = verify_paired_v2_runtime()?;
        if final_generation.pid != initial_generation.pid
            || final_generation.runs != initial_generation.runs
            || final_generation.process_start != initial_generation.process_start
            || final_generation.nonce != initial_generation.nonce
            || final_generation.lock_device != initial_generation.lock_device
            || final_generation.lock_inode != initial_generation.lock_inode
        {
            return Err(ControllerError(
                "current isolated launch generation changed at the pre-stop gate".to_owned(),
            ));
        }

        bootout_exact_new_job()?;
        wait_for_no_capture_servers(Duration::from_secs(30))?;
        require_service_absent(NEW_LAUNCH_AGENT_LABEL)?;
        verify_protected_legacy_absent()?;
        let lock = acquire_unowned_shared_lock()?;
        verify_v2_active_pointer(&layout.evidence)?;
        verify_v1_pointer_unchanged()?;
        verify_isolated_pairing_items_present()?;
        verify_v2_deployment_reference(layout)?;
        verify_current_baseline_app_at(Path::new(NEW_APP), true)?;
        journal.record(V2State::CurrentStopped, &[])?;

        rename_exclusive(Path::new(NEW_APP), &layout.rollback_app)?;
        fsync_parent(Path::new(NEW_APP))?;
        fsync_parent(&layout.rollback_app)?;
        verify_current_baseline_app_at(&layout.rollback_app, false)?;
        journal.record(V2State::CurrentHeld, &[])?;

        rename_exclusive(&layout.install_hold, Path::new(NEW_APP))?;
        fsync_parent(&layout.install_hold)?;
        fsync_parent(Path::new(NEW_APP))?;
        fs::remove_dir(&layout.install_hold_root).map_err(|error| {
            ControllerError(format!(
                "cannot remove empty paired-v2 install-hold root {}: {error}",
                layout.install_hold_root.display()
            ))
        })?;
        fsync_parent(&layout.install_hold_root)?;
        verify_v2_installed_matches_reference(layout)?;
        verify_isolated_pairing_items_present()?;
        verify_v1_pointer_unchanged()?;
        journal.record(V2State::NewPublished, &[])?;
        drop(lock);

        let checkpoint = capture_log_checkpoint()?;
        bootstrap_exact_new_job()?;
        journal.record(V2State::PersistentBootstrapped, &[])?;
        let generation = wait_for_paired_v2_launch_generation(Duration::from_secs(45))?;
        verify_paired_v2_deployment(layout, &checkpoint, &generation)?;
        verify_isolated_pairing_items_present()?;
        verify_v1_pointer_unchanged()?;
        journal.record(
            V2State::ReadyVerified,
            &[
                ("pid", generation.pid.to_string()),
                ("runs", generation.runs.to_string()),
                ("nonce", generation.nonce.clone()),
            ],
        )?;
        verify_protected_legacy_absent()?;
        release_rollback_reserve(&layout.rollback_reserve)?;
        journal.record(V2State::Committed, &[])?;
        if let Err(error) = write_result(&layout.result, "success", None) {
            eprintln!("warning: paired-v2 update committed but result recording failed: {error}");
        }
        println!(
            "PAIRED_V2_HOST_UPDATE_COMMITTED evidence={} pid={} rollback=current-isolated-retained pairing=preserved",
            layout.evidence.display(),
            generation.pid
        );
        Ok(())
    }

    fn rollback_existing_paired_v2_update(repo: PathBuf) -> Result<()> {
        verify_machine_contract()?;
        let transaction_lock = acquire_update_transaction_lock_at(Path::new(V2_UPDATE_LOCK))?;
        verify_committed_v1_baseline()?;
        let evidence =
            read_update_pointer_at(Path::new(V2_ACTIVE_UPDATE), Path::new(V2_UPDATE_ROOT))?;
        let layout = v2_layout_from_existing(repo, evidence)?;
        let mut journal = V2Journal::open(&layout.journal)?;
        if journal.state == V2State::RolledBack {
            verify_paired_v2_runtime()?;
            verify_isolated_pairing_items_present()?;
            ensure_rolled_back_result(&layout.result)?;
            retire_v2_active_pointer(&layout)?;
            println!("PAIRED_V2_HOST_UPDATE_ALREADY_ROLLED_BACK");
            return Ok(());
        }
        rollback_to_current_baseline(&layout, &mut journal, &transaction_lock)?;
        write_result(&layout.result, "rolled-back-by-explicit-request", None)?;
        retire_v2_active_pointer(&layout)?;
        println!(
            "PAIRED_V2_HOST_UPDATE_ROLLED_BACK evidence={} pairing=preserved",
            layout.evidence.display()
        );
        Ok(())
    }

    fn rollback_to_current_baseline(
        layout: &V2Layout,
        journal: &mut V2Journal,
        _transaction_lock: &UpdateTransactionLock,
    ) -> Result<()> {
        journal.require_healthy()?;
        verify_v2_active_pointer(&layout.evidence)?;
        verify_v1_pointer_unchanged()?;
        verify_isolated_pairing_items_present()?;
        if journal.state == V2State::RolledBack {
            verify_paired_v2_runtime()?;
            return Ok(());
        }
        let already_rolling_back = matches!(
            journal.state,
            V2State::RollbackStarted
                | V2State::FailedNewArchived
                | V2State::CurrentRestored
                | V2State::CurrentBootstrapped
        );
        if !already_rolling_back {
            journal.record(V2State::RollbackStarted, &[])?;
        }
        if layout.rollback_reserve.exists() {
            release_rollback_reserve(&layout.rollback_reserve)?;
        }

        bootout_paired_v2_job_if_loaded(layout)?;
        wait_for_no_capture_servers(Duration::from_secs(30))?;
        require_service_absent(NEW_LAUNCH_AGENT_LABEL)?;
        verify_protected_legacy_absent()?;
        let lock = acquire_unowned_shared_lock()?;
        verify_isolated_pairing_items_present()?;
        verify_v1_pointer_unchanged()?;
        archive_v2_install_hold_if_present(layout)?;

        let canonical_exists = path_exists_without_follow(Path::new(NEW_APP))?;
        let rollback_exists = path_exists_without_follow(&layout.rollback_app)?;
        let failed_exists = path_exists_without_follow(&layout.failed_app)?;

        if rollback_exists {
            verify_current_baseline_app_at(&layout.rollback_app, false)?;
            if canonical_exists {
                if verify_current_baseline_app_at(Path::new(NEW_APP), true).is_ok() {
                    return Err(ControllerError(
                        "rollback found duplicate current isolated baseline apps".to_owned(),
                    ));
                }
                if failed_exists {
                    return Err(ControllerError(
                        "rollback found both canonical failed app and retained failed archive"
                            .to_owned(),
                    ));
                }
                verify_v2_installed_matches_reference(layout)?;
                rename_exclusive(Path::new(NEW_APP), &layout.failed_app)?;
                fsync_parent(Path::new(NEW_APP))?;
                fsync_parent(&layout.failed_app)?;
                if journal.state == V2State::RollbackStarted {
                    journal.record(V2State::FailedNewArchived, &[])?;
                }
            } else if failed_exists && journal.state == V2State::RollbackStarted {
                journal.record(V2State::FailedNewArchived, &[])?;
            }

            require_path_absent(Path::new(NEW_APP), "canonical app before baseline restore")?;
            rename_exclusive(&layout.rollback_app, Path::new(NEW_APP))?;
            fsync_parent(Path::new(NEW_APP))?;
            fsync_parent(&layout.rollback_app)?;
            verify_current_baseline_app_at(Path::new(NEW_APP), true)?;
            if matches!(
                journal.state,
                V2State::RollbackStarted | V2State::FailedNewArchived
            ) {
                journal.record(V2State::CurrentRestored, &[])?;
            }
        } else if canonical_exists {
            verify_current_baseline_app_at(Path::new(NEW_APP), true)?;
            if matches!(
                journal.state,
                V2State::RollbackStarted | V2State::FailedNewArchived
            ) {
                journal.record(V2State::CurrentRestored, &[])?;
            }
        } else {
            return Err(ControllerError(
                "rollback cannot locate the exact current isolated baseline".to_owned(),
            ));
        }

        if !matches!(
            journal.state,
            V2State::CurrentRestored | V2State::CurrentBootstrapped
        ) {
            return Err(ControllerError(format!(
                "paired-v2 rollback topology is not resumable from {}",
                journal.state.token()
            )));
        }
        verify_isolated_pairing_items_present()?;
        verify_v1_pointer_unchanged()?;
        drop(lock);

        verify_current_baseline_app_at(Path::new(NEW_APP), true)?;
        let checkpoint = capture_log_checkpoint()?;
        bootstrap_exact_new_job()?;
        if journal.state == V2State::CurrentRestored {
            journal.record(V2State::CurrentBootstrapped, &[])?;
        }
        let generation = wait_for_paired_v2_launch_generation(Duration::from_secs(45))?;
        verify_current_baseline_oracle_pins()?;
        verify_deployment(
            Path::new(CURRENT_BASELINE_SOURCE_EXPORT),
            Path::new(CURRENT_BASELINE_APP),
            &checkpoint,
            &generation,
        )?;
        verify_isolated_pairing_items_present()?;
        verify_v1_pointer_unchanged()?;
        verify_protected_legacy_absent()?;
        journal.record(V2State::RolledBack, &[])?;
        verify_paired_v2_runtime()?;
        Ok(())
    }

    fn v2_layout_from_existing(repo: PathBuf, evidence: PathBuf) -> Result<V2Layout> {
        require_descendant(Path::new(V2_UPDATE_ROOT), &evidence)?;
        require_directory(&evidence, 0o700)?;
        let install_hold_name = read_bounded_utf8(&evidence.join("install-hold-name.txt"), 512)?;
        let install_hold_root = PathBuf::from(install_hold_name.trim_end());
        let nonce = install_hold_root
            .file_name()
            .and_then(|value| value.to_str())
            .and_then(|value| value.strip_prefix(HIDDEN_INSTALL_PREFIX))
            .ok_or_else(|| {
                ControllerError("paired-v2 install-hold name is malformed".to_owned())
            })?;
        let expected = V2Layout::new(repo, evidence, nonce);
        if expected.install_hold_root != install_hold_root {
            return Err(ControllerError(
                "paired-v2 install-hold path escaped its recorded layout".to_owned(),
            ));
        }
        require_v2_install_hold_layout(&expected.install_hold_root, &expected.install_hold)?;
        Ok(expected)
    }

    fn export_v2_source(layout: &V2Layout, provenance: &Provenance) -> Result<()> {
        require_path_absent(&layout.source_tar, "v2 source archive")?;
        require_path_absent(&layout.source_export, "v2 source export")?;
        create_private_directory(&layout.source_export)?;
        let archive = OpenOptions::new()
            .create_new(true)
            .write(true)
            .mode(0o600)
            .open(&layout.source_tar)?;
        let status = Command::new("/usr/bin/git")
            .args(["archive", "--format=tar", &provenance.commit])
            .current_dir(&layout.repo)
            .stdout(Stdio::from(archive))
            .stderr(Stdio::piped())
            .status()?;
        require_success(status, "git archive for paired-v2 update")?;
        require_regular(&layout.source_tar, 0o600)?;
        let output = command_output(
            "/usr/bin/tar",
            &[
                "-xf",
                path_text(&layout.source_tar)?,
                "-C",
                path_text(&layout.source_export)?,
            ],
            None,
        )?;
        require_output_success(&output, "extract paired-v2 source archive")?;
        require_regular(
            &layout
                .source_export
                .join("macOS/scripts/build-opensteamer-host-app.sh"),
            SOURCE_EXPORT_EXECUTABLE_MODE,
        )?;
        require_regular(
            &layout
                .source_export
                .join("macOS/scripts/opensteamer-host-paired-v2-update-controller.rs"),
            0o600,
        )?;
        let mut record = create_new_private(&layout.evidence.join("provenance.txt"))?;
        writeln!(record, "commit={}", provenance.commit)?;
        writeln!(record, "tree={}", provenance.tree)?;
        writeln!(record, "upstream={}", provenance.upstream)?;
        writeln!(record, "remote={}", provenance.remote)?;
        writeln!(
            record,
            "source_archive_sha256={}",
            sha256(&layout.source_tar)?
        )?;
        record.sync_all()?;
        fsync_parent(&layout.evidence.join("provenance.txt"))
    }

    fn build_and_verify_v2_staged_app(layout: &V2Layout) -> Result<()> {
        require_path_absent(&layout.stage_output, "paired-v2 staged output")?;
        require_path_absent(&layout.scratch, "paired-v2 SwiftPM scratch")?;
        let stdout = create_new_private(&layout.evidence.join("build.stdout"))?;
        let stderr = create_new_private(&layout.evidence.join("build.stderr"))?;
        let build_script = layout
            .source_export
            .join("macOS/scripts/build-opensteamer-host-app.sh");
        let status = Command::new(&build_script)
            .current_dir(&layout.source_export)
            .env_clear()
            .env("HOME", USER_HOME)
            .env("USER", "ahmed")
            .env("LOGNAME", "ahmed")
            .env("PATH", "/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin")
            .env("OPENSTEAMER_HOST_APP_OUTPUT_DIR", &layout.stage_output)
            .env("OPENSTEAMER_HOST_SCRATCH_PATH", &layout.scratch)
            .env("OPENSTEAMER_REQUIRE_FRESH_RELEASE", "1")
            .env("OPENSTEAMER_EXPECTED_TEAM_ID", EXPECTED_TEAM_ID)
            .env(
                "OPENSTEAMER_EXPECTED_SIGNING_IDENTITY_SHA1",
                EXPECTED_SIGNING_IDENTITY_SHA1,
            )
            .env(
                "OPENSTEAMER_HOST_DESIGNATED_REQUIREMENT_REFERENCE",
                OFFLINE_LEGACY_REFERENCE,
            )
            .env("OPENSTEAMER_EXPECTED_ARCHITECTURES", "arm64")
            .stdout(Stdio::from(stdout))
            .stderr(Stdio::from(stderr))
            .status()?;
        require_success(status, "fresh signed paired-v2 host build")?;
        verify_staged_app_contract(
            &layout.source_export,
            &layout.staged_app,
            SOURCE_EXPORT_EXECUTABLE_MODE,
        )?;
        let executable = layout.staged_app.join("Contents/MacOS/CaptureServer");
        if sha256(&executable)? == CURRENT_BASELINE_EXECUTABLE_SHA256 {
            return Err(ControllerError(
                "paired-v2 staged executable is byte-identical to the current isolated baseline"
                    .to_owned(),
            ));
        }
        verify_staged_pairing_namespace(&executable)
    }

    fn verify_staged_pairing_namespace(executable: &Path) -> Result<()> {
        let strings = command_output("/usr/bin/strings", &[path_text(executable)?], None)?;
        require_output_success(&strings, "inspect paired-v2 staged pairing namespace")?;
        let text = decode_utf8(&strings.stdout, "paired-v2 strings output")?;
        let isolated_count = text
            .lines()
            .filter(|line| *line == ISOLATED_PAIRING_SERVICE)
            .count();
        let protected_count = text
            .lines()
            .filter(|line| *line == PROTECTED_PAIRING_SERVICE)
            .count();
        if isolated_count != 1 || protected_count != 0 {
            return Err(ControllerError(format!(
                "paired-v2 staged pairing namespace is not isolated: isolated_count={isolated_count} protected_count={protected_count}"
            )));
        }
        Ok(())
    }

    fn prepare_v2_deployment_reference(layout: &V2Layout) -> Result<()> {
        require_path_absent(
            &layout.deployment_reference_dir,
            "paired-v2 deployment-reference directory",
        )?;
        create_private_directory(&layout.deployment_reference_dir)?;
        let output = command_output(
            "/usr/bin/ditto",
            &[
                "--noqtn",
                path_text(&layout.staged_app)?,
                path_text(&layout.deployment_reference_app)?,
            ],
            None,
        )?;
        require_output_success(&output, "copy paired-v2 deployment reference")?;
        verify_v2_deployment_reference(layout)
    }

    fn verify_v2_deployment_reference(layout: &V2Layout) -> Result<()> {
        require_directory(&layout.deployment_reference_dir, 0o700)?;
        for app in [&layout.staged_app, &layout.deployment_reference_app] {
            verify_staged_app_contract(&layout.source_export, app, SOURCE_EXPORT_EXECUTABLE_MODE)?;
            let executable = app.join("Contents/MacOS/CaptureServer");
            if sha256(&executable)? == CURRENT_BASELINE_EXECUTABLE_SHA256 {
                return Err(ControllerError(
                    "paired-v2 deployment reference equals current isolated baseline".to_owned(),
                ));
            }
            verify_staged_pairing_namespace(&executable)?;
        }
        require_tree_equal(&layout.staged_app, &layout.deployment_reference_app)
    }

    fn prepare_v2_install_hold(layout: &V2Layout) -> Result<()> {
        require_v2_install_hold_layout(&layout.install_hold_root, &layout.install_hold)?;
        require_path_absent(&layout.install_hold_root, "paired-v2 hidden install hold")?;
        create_private_directory(&layout.install_hold_root)?;
        let output = command_output(
            "/usr/bin/ditto",
            &[
                "--noqtn",
                path_text(&layout.deployment_reference_app)?,
                path_text(&layout.install_hold)?,
            ],
            None,
        )?;
        require_output_success(&output, "copy paired-v2 install hold")?;
        verify_bundle(
            &layout.source_export,
            &layout.install_hold,
            false,
            SOURCE_EXPORT_EXECUTABLE_MODE,
        )?;
        require_tree_equal(&layout.deployment_reference_app, &layout.install_hold)
    }

    fn record_v2_install_hold_name(layout: &V2Layout) -> Result<()> {
        require_v2_install_hold_layout(&layout.install_hold_root, &layout.install_hold)?;
        let path = layout.evidence.join("install-hold-name.txt");
        let mut record = create_new_private(&path)?;
        writeln!(record, "{}", layout.install_hold_root.display())?;
        record.sync_all()?;
        fsync_parent(&path)
    }

    fn archive_v2_install_hold_if_present(layout: &V2Layout) -> Result<()> {
        require_v2_install_hold_layout(&layout.install_hold_root, &layout.install_hold)?;
        if !path_exists_without_follow(&layout.install_hold_root)? {
            return Ok(());
        }
        require_directory(&layout.install_hold_root, 0o700)?;
        if path_exists_without_follow(&layout.install_hold)? {
            verify_bundle(
                &layout.source_export,
                &layout.install_hold,
                false,
                SOURCE_EXPORT_EXECUTABLE_MODE,
            )?;
            let archive = layout.evidence.join("unused-install-hold");
            require_path_absent(&archive, "unused paired-v2 install-hold archive")?;
            rename_exclusive(&layout.install_hold, &archive)?;
            fsync_parent(&layout.install_hold)?;
            fsync_parent(&archive)?;
        }
        fs::remove_dir(&layout.install_hold_root)?;
        fsync_parent(&layout.install_hold_root)
    }

    fn verify_v2_installed_matches_reference(layout: &V2Layout) -> Result<()> {
        verify_bundle(
            &layout.source_export,
            Path::new(NEW_APP),
            true,
            SOURCE_EXPORT_EXECUTABLE_MODE,
        )?;
        require_tree_equal(&layout.deployment_reference_app, Path::new(NEW_APP))?;
        verify_staged_pairing_namespace(Path::new(NEW_EXECUTABLE))?;
        verify_reviewed_launch_agent_unchanged()?;
        verify_protected_legacy_absent()
    }

    fn verify_paired_v2_deployment(
        layout: &V2Layout,
        checkpoint: &LogCheckpoint,
        generation: &LaunchGeneration,
    ) -> Result<()> {
        verify_deployment(
            &layout.source_export,
            &layout.deployment_reference_app,
            checkpoint,
            generation,
        )?;
        verify_generation_bound_paired_marker(checkpoint, generation)
    }

    fn verify_generation_bound_paired_marker(
        checkpoint: &LogCheckpoint,
        generation: &LaunchGeneration,
    ) -> Result<()> {
        require_regular(Path::new(ONLINE_LOG), 0o600)?;
        let before = fs::metadata(ONLINE_LOG)?;
        if before.dev() != checkpoint.device
            || before.ino() != checkpoint.inode
            || before.len() < checkpoint.offset
            || before.nlink() != 1
            || before.uid() != USER_ID
        {
            return Err(ControllerError(
                "paired availability log changed outside the generation checkpoint".to_owned(),
            ));
        }
        let suffix_length = before.len() - checkpoint.offset;
        if suffix_length > 8 * 1_024 * 1_024 {
            return Err(ControllerError(
                "paired availability log suffix exceeds the bounded proof limit".to_owned(),
            ));
        }
        let mut file = File::open(ONLINE_LOG)?;
        file.seek(SeekFrom::Start(checkpoint.offset))?;
        let mut bytes = Vec::with_capacity(suffix_length as usize);
        file.take(8 * 1_024 * 1_024 + 1).read_to_end(&mut bytes)?;
        if bytes.len() as u64 > 8 * 1_024 * 1_024 {
            return Err(ControllerError(
                "paired availability log grew beyond the bounded proof limit".to_owned(),
            ));
        }
        let after = fs::metadata(ONLINE_LOG)?;
        if after.dev() != before.dev()
            || after.ino() != before.ino()
            || after.len() < checkpoint.offset + bytes.len() as u64
        {
            return Err(ControllerError(
                "paired availability log changed while being read".to_owned(),
            ));
        }
        let text = std::str::from_utf8(&bytes)
            .map_err(|_| ControllerError("paired availability log is not UTF-8".to_owned()))?;
        let expected = format!(
            "{PAIRED_AVAILABILITY_MARKER_PREFIX} pid={} nonce={}",
            generation.pid, generation.nonce
        );
        if text.lines().filter(|line| *line == expected).count() == 0 {
            return Err(ControllerError(
                "generation-bound paired-device availability marker is absent".to_owned(),
            ));
        }
        Ok(())
    }

    fn verify_committed_v1_baseline() -> Result<()> {
        require_regular(Path::new(COMMITTED_V1_POINTER), 0o600)?;
        if sha256(Path::new(COMMITTED_V1_POINTER))? != COMMITTED_V1_POINTER_SHA256 {
            return Err(ControllerError(
                "committed v1 pointer hash changed".to_owned(),
            ));
        }
        let pointer = read_bounded_utf8(Path::new(COMMITTED_V1_POINTER), 512)?;
        if pointer != format!("{COMMITTED_V1_EVIDENCE}\n") {
            return Err(ControllerError(
                "committed v1 pointer bytes changed".to_owned(),
            ));
        }
        verify_update_pointer_at(
            Path::new(COMMITTED_V1_POINTER),
            Path::new(COMMITTED_V1_EVIDENCE),
            Path::new(UPDATE_ROOT),
        )?;
        let evidence = Path::new(COMMITTED_V1_EVIDENCE);
        require_directory(evidence, 0o700)?;
        for (relative, expected) in [
            ("journal.log", COMMITTED_V1_JOURNAL_SHA256),
            ("result.txt", COMMITTED_V1_RESULT_SHA256),
            ("provenance.txt", COMMITTED_V1_PROVENANCE_SHA256),
            ("source.tar", COMMITTED_V1_SOURCE_ARCHIVE_SHA256),
            (
                "install-hold-name.txt",
                COMMITTED_V1_INSTALL_HOLD_NAME_SHA256,
            ),
        ] {
            let path = evidence.join(relative);
            require_regular(&path, 0o600)?;
            if sha256(&path)? != expected {
                return Err(ControllerError(format!(
                    "committed v1 evidence changed: {}",
                    path.display()
                )));
            }
        }
        if read_bounded_utf8(&evidence.join("result.txt"), 128)? != "result=success\n" {
            return Err(ControllerError(
                "committed v1 result is not exact success".to_owned(),
            ));
        }
        verify_current_baseline_oracle_pins()?;
        let reference = Path::new(CURRENT_BASELINE_APP);
        verify_bundle(
            Path::new(CURRENT_BASELINE_SOURCE_EXPORT),
            reference,
            false,
            SOURCE_EXPORT_EXECUTABLE_MODE,
        )?;
        let executable = reference.join("Contents/MacOS/CaptureServer");
        if sha256(&executable)? != CURRENT_BASELINE_EXECUTABLE_SHA256
            || code_hash(reference)? != CURRENT_BASELINE_CDHASH
        {
            return Err(ControllerError(
                "committed isolated deployment reference changed".to_owned(),
            ));
        }
        require_code_identity(reference)?;
        verify_staged_pairing_namespace(&executable)
    }

    fn verify_current_baseline_oracle_pins() -> Result<()> {
        let source_export = Path::new(CURRENT_BASELINE_SOURCE_EXPORT);
        require_directory(source_export, 0o700)?;
        for (relative, mode, expected_sha256) in [
            (
                "macOS/scripts/verify-mac-host-bundle.sh",
                0o700,
                CURRENT_BASELINE_VERIFY_BUNDLE_SHA256,
            ),
            (
                "macOS/scripts/verify-live-mac-host-process.sh",
                0o700,
                CURRENT_BASELINE_VERIFY_LIVE_PROCESS_SHA256,
            ),
            (
                "macOS/scripts/verify-mac-host-deployment.sh",
                0o700,
                CURRENT_BASELINE_VERIFY_DEPLOYMENT_SHA256,
            ),
            (
                "macOS/scripts/verify-mac-host-launch-state.sh",
                0o700,
                CURRENT_BASELINE_VERIFY_LAUNCH_STATE_SHA256,
            ),
            (
                "macOS/LaunchAgents/org.example.opensteamer.worldwide.plist",
                0o600,
                CURRENT_BASELINE_LAUNCH_AGENT_SOURCE_SHA256,
            ),
        ] {
            let oracle = source_export.join(relative);
            require_regular(&oracle, mode)?;
            if sha256(&oracle)? != expected_sha256 {
                return Err(ControllerError(format!(
                    "committed v1 rollback oracle changed: {}",
                    oracle.display()
                )));
            }
        }
        Ok(())
    }

    fn verify_v1_pointer_unchanged() -> Result<()> {
        verify_committed_v1_baseline()
    }

    fn verify_current_baseline_app_at(app: &Path, canonical_installed: bool) -> Result<()> {
        verify_current_baseline_oracle_pins()?;
        require_directory(app, 0o755)?;
        let executable = app.join("Contents/MacOS/CaptureServer");
        require_regular(&executable, 0o755)?;
        if sha256(&executable)? != CURRENT_BASELINE_EXECUTABLE_SHA256
            || code_hash(app)? != CURRENT_BASELINE_CDHASH
        {
            return Err(ControllerError(format!(
                "current isolated baseline changed at {}",
                app.display()
            )));
        }
        require_code_identity(app)?;
        require_tree_equal(Path::new(CURRENT_BASELINE_APP), app)?;
        if canonical_installed {
            if app != Path::new(NEW_APP) {
                return Err(ControllerError(
                    "installed baseline verification escaped canonical app".to_owned(),
                ));
            }
            verify_bundle(
                Path::new(CURRENT_BASELINE_SOURCE_EXPORT),
                app,
                true,
                SOURCE_EXPORT_EXECUTABLE_MODE,
            )?;
        }
        Ok(())
    }

    fn verify_reviewed_launch_agent_unchanged() -> Result<()> {
        verify_current_baseline_oracle_pins()?;
        require_regular(Path::new(REVIEWED_LAUNCH_AGENT_PATH), 0o600)?;
        if sha256(Path::new(REVIEWED_LAUNCH_AGENT_PATH))? != REVIEWED_LAUNCH_AGENT_SHA256 {
            return Err(ControllerError(
                "reviewed isolated LaunchAgent bytes changed".to_owned(),
            ));
        }
        let source = Path::new(CURRENT_BASELINE_SOURCE_EXPORT)
            .join("macOS/LaunchAgents/org.example.opensteamer.worldwide.plist");
        require_regular(&source, 0o600)?;
        if sha256(&source)? != REVIEWED_LAUNCH_AGENT_SHA256 {
            return Err(ControllerError(
                "committed v1 LaunchAgent source changed".to_owned(),
            ));
        }
        Ok(())
    }

    fn verify_protected_legacy_absent() -> Result<()> {
        if PROTECTED_LEGACY_LAUNCH_AGENT_LABEL != LEGACY_LABEL {
            return Err(ControllerError(
                "protected legacy LaunchAgent alias changed".to_owned(),
            ));
        }
        verify_legacy_sources()?;
        require_legacy_disabled_and_absent()
    }

    fn verify_isolated_pairing_items_present() -> Result<()> {
        require_root_owned_system_executable(Path::new("/usr/bin/security"))?;
        for account in [
            ISOLATED_PAIRING_IDENTITY_ACCOUNT,
            ISOLATED_PAIRING_VIEWER_ACCOUNT,
        ] {
            let status = Command::new("/usr/bin/security")
                .args([
                    "find-generic-password",
                    "-s",
                    ISOLATED_PAIRING_SERVICE,
                    "-a",
                    account,
                ])
                .env_clear()
                .env("HOME", USER_HOME)
                .env("USER", "ahmed")
                .env("LOGNAME", "ahmed")
                .env("PATH", "/usr/bin:/bin:/usr/sbin:/sbin")
                .stdin(Stdio::null())
                .stdout(Stdio::null())
                .stderr(Stdio::null())
                .status()
                .map_err(|error| {
                    ControllerError(format!(
                        "cannot inspect isolated pairing item metadata for {account}: {error}"
                    ))
                })?;
            if !status.success() {
                return Err(ControllerError(format!(
                    "isolated pairing item is absent or inaccessible: account={account} status={status}"
                )));
            }
        }
        Ok(())
    }

    fn require_root_owned_system_executable(path: &Path) -> Result<()> {
        let metadata = fs::symlink_metadata(path)?;
        if !metadata.file_type().is_file()
            || metadata.file_type().is_symlink()
            || metadata.uid() != 0
            || metadata.nlink() != 1
            || metadata.permissions().mode() & 0o777 != 0o755
        {
            return Err(ControllerError(format!(
                "system executable has unsafe metadata: {}",
                path.display()
            )));
        }
        Ok(())
    }

    fn verify_paired_v2_runtime() -> Result<LaunchGeneration> {
        verify_committed_v1_baseline()?;
        verify_protected_legacy_absent()?;
        verify_reviewed_launch_agent_unchanged()?;
        verify_current_baseline_app_at(Path::new(NEW_APP), true)?;
        let launch = read_loaded_launch_state()?;
        require_solo_capture_server(Path::new(NEW_EXECUTABLE), launch.pid)?;
        let (lock_device, lock_inode, nonce) = read_generation_lock(launch.pid)?;
        prove_lock_holder(launch.pid, Duration::from_secs(4))?;
        let generation = LaunchGeneration {
            pid: launch.pid,
            runs: launch.runs,
            process_start: process_start(launch.pid)?,
            nonce,
            lock_device,
            lock_inode,
        };
        thread::sleep(Duration::from_millis(500));
        let second = read_loaded_launch_state()?;
        let (second_device, second_inode, second_nonce) = read_generation_lock(generation.pid)?;
        if second.pid != generation.pid
            || second.runs != generation.runs
            || process_start(generation.pid)? != generation.process_start
            || second_device != generation.lock_device
            || second_inode != generation.lock_inode
            || second_nonce != generation.nonce
        {
            return Err(ControllerError(
                "current isolated launch generation changed during preflight".to_owned(),
            ));
        }
        prove_lock_holder(generation.pid, Duration::from_secs(4))?;
        Ok(generation)
    }

    fn verify_paired_v2_git_provenance(repo: &Path, require_remote: bool) -> Result<Provenance> {
        let status = command_output(
            "/usr/bin/git",
            &["status", "--porcelain=v1", "--untracked-files=all"],
            Some(repo),
        )?;
        require_output_success(&status, "inspect paired-v2 git worktree")?;
        if !status.stdout.is_empty() {
            return Err(ControllerError(
                "repository must be completely clean before a paired-v2 host update".to_owned(),
            ));
        }
        let commit = command_line("/usr/bin/git", &["rev-parse", "HEAD"], Some(repo))?;
        let tree = command_line("/usr/bin/git", &["rev-parse", "HEAD^{tree}"], Some(repo))?;
        let remote = command_line(
            "/usr/bin/git",
            &["config", "--get", "remote.origin.url"],
            Some(repo),
        )?;
        if remote != EXPECTED_REMOTE {
            return Err(ControllerError(
                "origin remote differs from the reviewed repository".to_owned(),
            ));
        }
        let ancestry = command_output(
            "/usr/bin/git",
            &[
                "merge-base",
                "--is-ancestor",
                REQUIRED_FACE_TIME_PATCH_COMMIT,
                &commit,
            ],
            Some(repo),
        )?;
        require_output_success(&ancestry, "verify required FaceTime patch ancestry")?;
        if require_remote {
            let output = command_output(
                "/usr/bin/git",
                &[
                    "ls-remote",
                    "--heads",
                    "origin",
                    &format!("refs/heads/{EXPECTED_SOURCE_BRANCH}"),
                ],
                Some(repo),
            )?;
            require_output_success(&output, "verify pushed paired-v2 source commit")?;
            let text = decode_utf8(&output.stdout, "paired-v2 git ls-remote output")?;
            let records: Vec<&str> = text.lines().collect();
            let expected_ref = format!("refs/heads/{EXPECTED_SOURCE_BRANCH}");
            if records.len() != 1 {
                return Err(ControllerError(
                    "paired-v2 source branch is absent or ambiguous on origin".to_owned(),
                ));
            }
            let mut fields = records[0].split('\t');
            if fields.next() != Some(commit.as_str())
                || fields.next() != Some(expected_ref.as_str())
                || fields.next().is_some()
            {
                return Err(ControllerError(
                    "origin paired-v2 source branch does not resolve to local HEAD".to_owned(),
                ));
            }
        }
        Ok(Provenance {
            commit,
            tree,
            upstream: format!("origin/{EXPECTED_SOURCE_BRANCH}"),
            remote,
        })
    }

    fn wait_for_paired_v2_launch_generation(timeout: Duration) -> Result<LaunchGeneration> {
        wait_for_launch_generation(timeout)
    }

    fn bootout_paired_v2_job_if_loaded(layout: &V2Layout) -> Result<()> {
        let state = command_output(
            "/bin/launchctl",
            &["print", &format!("gui/{USER_ID}/{NEW_LAUNCH_AGENT_LABEL}")],
            None,
        )?;
        if state.status.success() {
            let loaded = parse_loaded_launch_job(decode_utf8(
                &state.stdout,
                "paired-v2 rollback launchctl state",
            )?)?;
            let expected_start = if let Some(pid) = loaded.pid {
                require_solo_capture_server(Path::new(NEW_EXECUTABLE), pid)?;
                if verify_current_baseline_app_at(Path::new(NEW_APP), true).is_ok() {
                    verify_live_canonical_process(
                        Path::new(CURRENT_BASELINE_SOURCE_EXPORT),
                        pid,
                        Path::new(CURRENT_BASELINE_APP),
                    )?;
                } else {
                    verify_v2_installed_matches_reference(layout)?;
                    verify_live_canonical_process(
                        &layout.source_export,
                        pid,
                        &layout.deployment_reference_app,
                    )?;
                }
                Some(process_start(pid)?)
            } else {
                require_no_capture_servers()?;
                None
            };
            let output = command_output(
                "/bin/launchctl",
                &[
                    "bootout",
                    &format!("gui/{USER_ID}/{NEW_LAUNCH_AGENT_LABEL}"),
                ],
                None,
            )?;
            require_output_success(&output, "boot out paired-v2 LaunchAgent during rollback")?;
            wait_for_new_job_bootout(&loaded, expected_start.as_deref(), Duration::from_secs(30))?;
        } else {
            require_service_absent(NEW_LAUNCH_AGENT_LABEL)?;
        }
        Ok(())
    }

    fn verify_live_canonical_process(
        verifier_root: &Path,
        pid: u32,
        signed_reference_app: &Path,
    ) -> Result<()> {
        if verifier_root == Path::new(CURRENT_BASELINE_SOURCE_EXPORT) {
            verify_current_baseline_oracle_pins()?;
        }
        let verifier = verifier_root.join("macOS/scripts/verify-live-mac-host-process.sh");
        require_regular(&verifier, SOURCE_EXPORT_EXECUTABLE_MODE)?;
        let reference_executable = signed_reference_app.join("Contents/MacOS/CaptureServer");
        let expected_cdhash = code_hash(&reference_executable)?;
        let output = command_output(
            path_text(&verifier)?,
            &[
                &pid.to_string(),
                NEW_EXECUTABLE,
                &expected_cdhash,
                EXPECTED_IDENTIFIER,
                EXPECTED_TEAM_ID,
                "/Applications/opensteamer Host.app/Contents/Frameworks/LiveKitWebRTC.framework/LiveKitWebRTC",
            ],
            Some(verifier_root),
        )?;
        require_output_success(&output, "verify canonical paired-v2 host mapped code")
    }

    fn require_v2_install_hold_layout(root: &Path, app: &Path) -> Result<()> {
        if root.parent() != Some(Path::new("/Applications"))
            || !root
                .file_name()
                .and_then(|value| value.to_str())
                .is_some_and(|value| {
                    value.starts_with(HIDDEN_INSTALL_PREFIX)
                        && value.len() > HIDDEN_INSTALL_PREFIX.len()
                        && value.len() < 160
                })
            || app.parent() != Some(root)
            || app.file_name().and_then(|value| value.to_str()) != Some("opensteamer Host.app")
        {
            return Err(ControllerError(format!(
                "paired-v2 install hold escaped its reviewed layout: {}",
                app.display()
            )));
        }
        Ok(())
    }

    fn publish_v2_active_pointer(evidence: &Path) -> Result<()> {
        require_descendant(Path::new(V2_UPDATE_ROOT), evidence)?;
        let pending = PathBuf::from(format!("{V2_ACTIVE_UPDATE}.pending-{}", std::process::id()));
        require_path_absent(&pending, "pending paired-v2 pointer")?;
        require_path_absent(Path::new(V2_ACTIVE_UPDATE), "active paired-v2 pointer")?;
        let mut file = create_new_private(&pending)?;
        writeln!(file, "{}", evidence.display())?;
        file.sync_all()?;
        rename_exclusive(&pending, Path::new(V2_ACTIVE_UPDATE))?;
        fsync_parent(Path::new(V2_ACTIVE_UPDATE))
    }

    fn verify_v2_active_pointer(expected_evidence: &Path) -> Result<()> {
        verify_update_pointer_at(
            Path::new(V2_ACTIVE_UPDATE),
            expected_evidence,
            Path::new(V2_UPDATE_ROOT),
        )
    }

    fn retire_v2_active_pointer(layout: &V2Layout) -> Result<()> {
        retire_update_pointer_at(
            Path::new(V2_ACTIVE_UPDATE),
            &layout.evidence,
            Path::new(V2_UPDATE_ROOT),
        )
    }

    fn path_exists_without_follow(path: &Path) -> Result<bool> {
        match fs::symlink_metadata(path) {
            Ok(_) => Ok(true),
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(false),
            Err(error) => Err(error.into()),
        }
    }

    fn parse_v2_journal(text: &str) -> Result<V2State> {
        let mut lines = text.lines();
        if lines.next() != Some(V2_JOURNAL_HEADER) {
            return Err(ControllerError(
                "paired-v2 journal header is malformed".to_owned(),
            ));
        }
        let mut state = None;
        for line in lines {
            let mut fields = line.split(' ');
            if fields.next() != Some("STATE") {
                return Err(ControllerError(
                    "paired-v2 journal record is malformed".to_owned(),
                ));
            }
            let next = fields
                .next()
                .and_then(V2State::parse)
                .ok_or_else(|| ControllerError("paired-v2 journal state is unknown".to_owned()))?;
            if let Some(previous) = state {
                validate_v2_transition(previous, next)?;
            } else if next != V2State::Begun {
                return Err(ControllerError(
                    "paired-v2 journal does not begin at BEGUN".to_owned(),
                ));
            }
            let fields: Vec<&str> = fields.collect();
            let expected = v2_field_schema(next);
            if fields.len() != expected.len() {
                return Err(ControllerError(
                    "paired-v2 journal field count is invalid".to_owned(),
                ));
            }
            for (field, expected_key) in fields.into_iter().zip(expected) {
                let (key, value) = field.split_once('=').ok_or_else(|| {
                    ControllerError("paired-v2 journal field is malformed".to_owned())
                })?;
                if key != *expected_key || !is_safe_journal_value(value) {
                    return Err(ControllerError(
                        "paired-v2 journal field is unsafe".to_owned(),
                    ));
                }
            }
            state = Some(next);
        }
        state.ok_or_else(|| ControllerError("paired-v2 journal has no state".to_owned()))
    }

    fn v2_field_schema(state: V2State) -> &'static [&'static str] {
        match state {
            V2State::Begun
            | V2State::InstallHoldVerified
            | V2State::CurrentStopped
            | V2State::CurrentHeld
            | V2State::NewPublished
            | V2State::PersistentBootstrapped
            | V2State::Committed
            | V2State::RollbackStarted
            | V2State::FailedNewArchived
            | V2State::CurrentRestored
            | V2State::CurrentBootstrapped
            | V2State::RolledBack => &[],
            V2State::SourceExported => &["commit", "tree", "initial_pid"],
            V2State::BuildVerified => &["executable_sha256"],
            V2State::StopInitiated => &["reserve_device", "reserve_inode", "reserve_bytes"],
            V2State::ReadyVerified => &["pid", "runs", "nonce"],
            V2State::CriticalFailure => &["phase"],
        }
    }

    fn validate_v2_fields(state: V2State, fields: &[(&str, String)]) -> Result<()> {
        let expected = v2_field_schema(state);
        if fields.len() != expected.len() {
            return Err(ControllerError(
                "paired-v2 journal record has wrong field count".to_owned(),
            ));
        }
        for ((key, value), expected_key) in fields.iter().zip(expected) {
            if *key != *expected_key || !is_safe_journal_value(value) {
                return Err(ControllerError("unsafe paired-v2 journal field".to_owned()));
            }
        }
        Ok(())
    }

    fn validate_v2_transition(previous: V2State, next: V2State) -> Result<()> {
        if previous == V2State::Begun && next == V2State::Begun {
            return Ok(());
        }
        let forward = matches!(
            (previous, next),
            (V2State::Begun, V2State::SourceExported)
                | (V2State::SourceExported, V2State::BuildVerified)
                | (V2State::BuildVerified, V2State::StopInitiated)
                | (V2State::StopInitiated, V2State::InstallHoldVerified)
                | (V2State::InstallHoldVerified, V2State::CurrentStopped)
                | (V2State::CurrentStopped, V2State::CurrentHeld)
                | (V2State::CurrentHeld, V2State::NewPublished)
                | (V2State::NewPublished, V2State::PersistentBootstrapped)
                | (V2State::PersistentBootstrapped, V2State::ReadyVerified)
                | (V2State::ReadyVerified, V2State::Committed)
        );
        let rollback_entry = next == V2State::RollbackStarted
            && ((previous >= V2State::StopInitiated && previous <= V2State::Committed)
                || previous == V2State::CriticalFailure)
            && previous != V2State::RollbackStarted;
        let rollback = matches!(
            (previous, next),
            (V2State::RollbackStarted, V2State::FailedNewArchived)
                | (V2State::RollbackStarted, V2State::CurrentRestored)
                | (V2State::FailedNewArchived, V2State::CurrentRestored)
                | (V2State::CurrentRestored, V2State::CurrentBootstrapped)
                | (V2State::CurrentBootstrapped, V2State::RolledBack)
        );
        let critical = next == V2State::CriticalFailure
            && previous >= V2State::RollbackStarted
            && previous < V2State::RolledBack;
        if forward || rollback_entry || rollback || critical {
            Ok(())
        } else {
            Err(ControllerError(format!(
                "invalid paired-v2 journal transition: {} -> {}",
                previous.token(),
                next.token()
            )))
        }
    }

    const ALL_V2_STATES: [V2State; 17] = [
        V2State::Begun,
        V2State::SourceExported,
        V2State::BuildVerified,
        V2State::StopInitiated,
        V2State::InstallHoldVerified,
        V2State::CurrentStopped,
        V2State::CurrentHeld,
        V2State::NewPublished,
        V2State::PersistentBootstrapped,
        V2State::ReadyVerified,
        V2State::Committed,
        V2State::RollbackStarted,
        V2State::FailedNewArchived,
        V2State::CurrentRestored,
        V2State::CurrentBootstrapped,
        V2State::RolledBack,
        V2State::CriticalFailure,
    ];

    fn is_plausible_v2_torn_tail(tail: &[u8], previous: V2State) -> bool {
        if tail.is_empty() || tail.len() > 4_096 || tail.contains(&b'\n') || tail.contains(&b'\r') {
            return false;
        }
        let Ok(tail) = std::str::from_utf8(tail) else {
            return false;
        };
        ALL_V2_STATES
            .iter()
            .copied()
            .filter(|next| validate_v2_transition(previous, *next).is_ok())
            .any(|next| is_plausible_v2_record_prefix(tail, next))
    }

    fn is_plausible_v2_record_prefix(tail: &str, state: V2State) -> bool {
        let state_prefix = format!("STATE {}", state.token());
        if tail.len() <= state_prefix.len() {
            return state_prefix.starts_with(tail);
        }
        if !tail.starts_with(&state_prefix) {
            return false;
        }
        let Some(fields_text) = tail[state_prefix.len()..].strip_prefix(' ') else {
            return false;
        };
        let expected = v2_field_schema(state);
        if expected.is_empty() {
            return false;
        }
        let fields: Vec<&str> = fields_text.split(' ').collect();
        if fields.len() > expected.len() {
            return false;
        }
        for (index, (field, expected_key)) in fields.iter().zip(expected).enumerate() {
            let expected_prefix = format!("{expected_key}=");
            let last = index + 1 == fields.len();
            if field.len() <= expected_prefix.len() {
                return last && expected_prefix.starts_with(field);
            }
            let Some(value) = field.strip_prefix(&expected_prefix) else {
                return false;
            };
            if !value.bytes().all(|byte| {
                byte.is_ascii_alphanumeric() || matches!(byte, b'.' | b'_' | b'-' | b':' | b'/')
            }) || (value.is_empty() && !last)
            {
                return false;
            }
        }
        true
    }

    fn paired_v2_self_test() -> Result<()> {
        verify_v2_cli_surface()?;
        let valid = format!(
            "{V2_JOURNAL_HEADER}\nSTATE BEGUN\nSTATE SOURCE_EXPORTED commit={} tree={} initial_pid=41\nSTATE BUILD_VERIFIED executable_sha256={}\nSTATE STOP_INITIATED reserve_device=1 reserve_inode=2 reserve_bytes=8388608\nSTATE INSTALL_HOLD_VERIFIED\nSTATE CURRENT_STOPPED\nSTATE CURRENT_HELD\nSTATE NEW_PUBLISHED\nSTATE PERSISTENT_BOOTSTRAPPED\nSTATE READY_VERIFIED pid=42 runs=1 nonce={}\nSTATE COMMITTED\n",
            "a".repeat(40),
            "b".repeat(40),
            "c".repeat(64),
            "d".repeat(64),
        );
        if parse_v2_journal(&valid)? != V2State::Committed {
            return Err(ControllerError(
                "paired-v2 committed journal parser self-test failed".to_owned(),
            ));
        }
        let rolled_back = format!(
            "{V2_JOURNAL_HEADER}\nSTATE BEGUN\nSTATE SOURCE_EXPORTED commit={} tree={} initial_pid=41\nSTATE BUILD_VERIFIED executable_sha256={}\nSTATE STOP_INITIATED reserve_device=1 reserve_inode=2 reserve_bytes=8388608\nSTATE INSTALL_HOLD_VERIFIED\nSTATE CURRENT_STOPPED\nSTATE CURRENT_HELD\nSTATE NEW_PUBLISHED\nSTATE ROLLBACK_STARTED\nSTATE FAILED_NEW_ARCHIVED\nSTATE CURRENT_RESTORED\nSTATE CURRENT_BOOTSTRAPPED\nSTATE ROLLED_BACK\n",
            "a".repeat(40),
            "b".repeat(40),
            "c".repeat(64),
        );
        if parse_v2_journal(&rolled_back)? != V2State::RolledBack {
            return Err(ControllerError(
                "paired-v2 rollback journal parser self-test failed".to_owned(),
            ));
        }
        if parse_v2_journal(&format!(
            "{V2_JOURNAL_HEADER}\nSTATE BEGUN\nSTATE NEW_PUBLISHED\n"
        ))
        .is_ok()
        {
            return Err(ControllerError(
                "paired-v2 journal parser accepted a skipped transition".to_owned(),
            ));
        }
        let hold_root = Path::new("/Applications/.opensteamer-paired-v2-install-selftest");
        let hold_app = hold_root.join("opensteamer Host.app");
        require_v2_install_hold_layout(hold_root, &hold_app)?;
        if require_v2_install_hold_layout(
            Path::new("/Applications/opensteamer Host.app"),
            &hold_app,
        )
        .is_ok()
            || require_v2_install_hold_layout(hold_root, &hold_root.join("unreviewed Host.app"))
                .is_ok()
        {
            return Err(ControllerError(
                "paired-v2 install-hold layout self-test failed".to_owned(),
            ));
        }
        paired_v2_dynamic_self_test()?;
        println!("SELF_TEST_OK paired-v2-host-update-controller");
        Ok(())
    }

    fn verify_v2_cli_surface() -> Result<()> {
        let executable = "controller".to_owned();
        let repo = V2_EXPECTED_REPO.to_owned();
        let allowed = [
            vec![
                executable.clone(),
                V2_PREFLIGHT_MODE.to_owned(),
                repo.clone(),
            ],
            vec![executable.clone(), V2_EXECUTE_MODE.to_owned(), repo.clone()],
            vec![
                executable.clone(),
                V2_ROLLBACK_MODE.to_owned(),
                repo.clone(),
            ],
            vec![executable.clone(), V2_SELF_TEST_MODE.to_owned()],
            vec![
                executable.clone(),
                PROBE_LOCK_MODE.to_owned(),
                LOCK_DIRECTORY.to_owned(),
                LOCK_FILE.to_owned(),
                "1".to_owned(),
            ],
        ];
        if !matches!(parse_v2_command(&allowed[0]), Ok(V2Command::Preflight(_)))
            || !matches!(parse_v2_command(&allowed[1]), Ok(V2Command::Execute(_)))
            || !matches!(parse_v2_command(&allowed[2]), Ok(V2Command::Rollback(_)))
            || !matches!(parse_v2_command(&allowed[3]), Ok(V2Command::SelfTest))
            || !matches!(
                parse_v2_command(&allowed[4]),
                Ok(V2Command::ProbeLock { .. })
            )
        {
            return Err(ControllerError(
                "paired-v2 CLI rejected a reviewed command shape".to_owned(),
            ));
        }

        let malformed = [
            vec![executable.clone(), V2_PREFLIGHT_MODE.to_owned()],
            vec![
                executable.clone(),
                V2_SELF_TEST_MODE.to_owned(),
                repo.clone(),
            ],
            vec![
                executable.clone(),
                PROBE_LOCK_MODE.to_owned(),
                LOCK_DIRECTORY.to_owned(),
                LOCK_FILE.to_owned(),
            ],
        ];
        if malformed
            .iter()
            .any(|arguments| parse_v2_command(arguments).is_ok())
        {
            return Err(ControllerError(
                "paired-v2 CLI accepted an unreviewed command shape".to_owned(),
            ));
        }

        for encoded_mode in [
            "2d2d7665726966792d706f73742d7632302d686f73742d7570646174652d707265666c69676874",
            "2d2d657865637574652d617574686f72697a65642d706f73742d7632302d686f73742d757064617465",
            "2d2d726f6c6c6261636b2d617574686f72697a65642d706f73742d7632302d686f73742d757064617465",
            "2d2d73656c662d746573742d706f73742d7632302d686f73742d757064617465",
            "2d2d657865637574652d617574686f72697a65642d706f73742d7632302d686f73742d7570646174652d776974682d72657669657765642d7072656275696c74",
        ] {
            let mode = String::from_utf8(decode_marker_hex(encoded_mode)?).map_err(|_| {
                ControllerError("paired-v2 CLI test mode is not UTF-8".to_owned())
            })?;
            let arguments = vec![executable.clone(), mode, repo.clone()];
            if parse_v2_command(&arguments).is_ok() {
                return Err(ControllerError(
                    "paired-v2 CLI exposed an inherited update mode".to_owned(),
                ));
            }
        }
        Ok(())
    }

    fn paired_v2_dynamic_self_test() -> Result<()> {
        let unique = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map_err(|_| ControllerError("system clock predates Unix epoch".to_owned()))?
            .as_nanos();
        let directory = PathBuf::from(format!(
            "/private/tmp/opensteamer-paired-v2-selftest-{}-{unique}",
            std::process::id()
        ));
        require_path_absent(&directory, "paired-v2 self-test directory")?;
        fs::create_dir(&directory)?;
        fs::set_permissions(&directory, fs::Permissions::from_mode(0o700))?;
        let result = paired_v2_dynamic_self_test_in(&directory);
        let cleanup = fs::remove_dir_all(&directory);
        match (result, cleanup) {
            (Err(error), _) => Err(error),
            (Ok(()), Err(error)) => Err(ControllerError(format!(
                "cannot remove paired-v2 self-test directory: {error}"
            ))),
            (Ok(()), Ok(())) => Ok(()),
        }
    }

    fn paired_v2_dynamic_self_test_in(directory: &Path) -> Result<()> {
        let recoverable = directory.join("recoverable.log");
        let mut journal = V2Journal::create(&recoverable)?;
        journal.record(
            V2State::SourceExported,
            &[
                ("commit", "a".repeat(40)),
                ("tree", "b".repeat(40)),
                ("initial_pid", "41".to_owned()),
            ],
        )?;
        let before_rejected = fs::metadata(&recoverable)?.len();
        if journal
            .record(
                V2State::BuildVerified,
                &[("executable_sha256", "unsafe value".to_owned())],
            )
            .is_ok()
            || fs::metadata(&recoverable)?.len() != before_rejected
        {
            return Err(ControllerError(
                "paired-v2 journal validation failure changed durable bytes".to_owned(),
            ));
        }
        drop(journal);
        let mut partial = OpenOptions::new().append(true).open(&recoverable)?;
        partial.write_all(
            format!("STATE BUILD_VERIFIED executable_sha256={}", "c".repeat(64)).as_bytes(),
        )?;
        partial.sync_all()?;
        drop(partial);
        let mut reopened = V2Journal::open(&recoverable)?;
        if reopened.state != V2State::SourceExported {
            return Err(ControllerError(
                "paired-v2 journal recovery accepted an incomplete final record".to_owned(),
            ));
        }
        reopened.record(
            V2State::BuildVerified,
            &[("executable_sha256", "c".repeat(64))],
        )?;
        drop(reopened);

        let corrupt = directory.join("corrupt.log");
        let mut corrupt_journal = V2Journal::create(&corrupt)?;
        corrupt_journal.record(
            V2State::SourceExported,
            &[
                ("commit", "a".repeat(40)),
                ("tree", "b".repeat(40)),
                ("initial_pid", "41".to_owned()),
            ],
        )?;
        drop(corrupt_journal);
        let mut corrupt_append = OpenOptions::new().append(true).open(&corrupt)?;
        corrupt_append.write_all(b"STATE NEW_PUBLISHED\n")?;
        corrupt_append.sync_all()?;
        drop(corrupt_append);
        if V2Journal::open(&corrupt).is_ok() {
            return Err(ControllerError(
                "paired-v2 journal recovery accepted a malformed complete record".to_owned(),
            ));
        }

        let transaction_lock = directory.join("transaction.lock");
        let first = acquire_update_transaction_lock_at(&transaction_lock)?;
        if acquire_update_transaction_lock_at(&transaction_lock).is_ok() {
            return Err(ControllerError(
                "paired-v2 transaction lock allowed concurrent ownership".to_owned(),
            ));
        }
        drop(first);
        drop(acquire_update_transaction_lock_at(&transaction_lock)?);

        let pointer_fixture = directory.join("v1-pointer-fixture");
        let mut pointer = create_new_private(&pointer_fixture)?;
        pointer.write_all(COMMITTED_V1_EVIDENCE.as_bytes())?;
        pointer.write_all(b"\n")?;
        pointer.sync_all()?;
        drop(pointer);
        let pointer_hash = sha256(&pointer_fixture)?;
        verify_self_test_pinned_file(&pointer_fixture, &pointer_hash)?;
        let mut mutate_pointer = OpenOptions::new().append(true).open(&pointer_fixture)?;
        mutate_pointer.write_all(b"x")?;
        mutate_pointer.sync_all()?;
        drop(mutate_pointer);
        if verify_self_test_pinned_file(&pointer_fixture, &pointer_hash).is_ok() {
            return Err(ControllerError(
                "v1 pointer corruption was accepted".to_owned(),
            ));
        }

        let evidence_fixture = directory.join("v1-evidence-fixture");
        let mut evidence = create_new_private(&evidence_fixture)?;
        evidence.write_all(b"committed-evidence\n")?;
        evidence.sync_all()?;
        drop(evidence);
        let evidence_hash = sha256(&evidence_fixture)?;
        verify_self_test_pinned_file(&evidence_fixture, &evidence_hash)?;
        let evidence_file = OpenOptions::new().write(true).open(&evidence_fixture)?;
        evidence_file.set_len(1)?;
        evidence_file.sync_all()?;
        drop(evidence_file);
        if verify_self_test_pinned_file(&evidence_fixture, &evidence_hash).is_ok() {
            return Err(ControllerError(
                "v1 evidence corruption was accepted".to_owned(),
            ));
        }

        self_test_v1_oracle_pin_mutation(directory)?;
        self_test_publication_boundary_recovery(directory)
    }

    fn verify_self_test_pinned_file(path: &Path, expected_sha256: &str) -> Result<()> {
        verify_self_test_pinned_file_with_mode(path, 0o600, expected_sha256)
    }

    fn verify_self_test_pinned_file_with_mode(
        path: &Path,
        mode: u32,
        expected_sha256: &str,
    ) -> Result<()> {
        require_regular(path, mode)?;
        if sha256(path)? != expected_sha256 {
            return Err(ControllerError("pinned self-test file changed".to_owned()));
        }
        Ok(())
    }

    fn self_test_v1_oracle_pin_mutation(directory: &Path) -> Result<()> {
        for (name, mode) in [
            ("verify-bundle-oracle-fixture", 0o700),
            ("verify-live-process-oracle-fixture", 0o700),
            ("verify-deployment-oracle-fixture", 0o700),
            ("verify-launch-state-oracle-fixture", 0o700),
            ("launch-agent-oracle-fixture", 0o600),
        ] {
            let path = directory.join(name);
            let mut oracle = create_new_private(&path)?;
            writeln!(oracle, "immutable-v1-oracle={name}")?;
            oracle.sync_all()?;
            drop(oracle);
            fs::set_permissions(&path, fs::Permissions::from_mode(mode))?;
            let expected_sha256 = sha256(&path)?;
            verify_self_test_pinned_file_with_mode(&path, mode, &expected_sha256)?;
            let mut mutation = OpenOptions::new().append(true).open(&path)?;
            mutation.write_all(b"mutation")?;
            mutation.sync_all()?;
            drop(mutation);
            if verify_self_test_pinned_file_with_mode(&path, mode, &expected_sha256).is_ok() {
                return Err(ControllerError(format!(
                    "v1 rollback oracle corruption was accepted: {name}"
                )));
            }
        }
        Ok(())
    }

    #[derive(Clone, Copy)]
    struct PublicationBoundaryCase {
        name: &'static str,
        current_held: bool,
        new_published: bool,
    }

    const PUBLICATION_BOUNDARY_CASES: [PublicationBoundaryCase; 5] = [
        PublicationBoundaryCase {
            name: "pre-current-hold",
            current_held: false,
            new_published: false,
        },
        PublicationBoundaryCase {
            name: "current-held-pre-new-publish",
            current_held: true,
            new_published: false,
        },
        PublicationBoundaryCase {
            name: "new-published-pre-bootstrap",
            current_held: true,
            new_published: true,
        },
        PublicationBoundaryCase {
            name: "bootstrapped-pre-ready",
            current_held: true,
            new_published: true,
        },
        PublicationBoundaryCase {
            name: "ready-pre-commit",
            current_held: true,
            new_published: true,
        },
    ];

    fn self_test_publication_boundary_recovery(directory: &Path) -> Result<()> {
        for case in PUBLICATION_BOUNDARY_CASES {
            self_test_publication_boundary_case(directory, case)?;
        }
        Ok(())
    }

    fn self_test_publication_boundary_case(
        directory: &Path,
        case: PublicationBoundaryCase,
    ) -> Result<()> {
        const BASELINE_BYTES: &str = "current-isolated-baseline";
        const REPLACEMENT_BYTES: &str = "paired-v2-replacement";

        let case_root = directory.join(case.name);
        fs::create_dir(&case_root)?;
        fs::set_permissions(&case_root, fs::Permissions::from_mode(0o700))?;
        let canonical = case_root.join("canonical-app-fixture");
        let rollback = case_root.join("rollback-current-fixture");
        let pending = case_root.join("pending-new-fixture");
        let failed = case_root.join("failed-new-fixture");
        let pointer = case_root.join("pinned-v1-pointer-fixture");

        let mut pointer_file = create_new_private(&pointer)?;
        writeln!(pointer_file, "{COMMITTED_V1_EVIDENCE}")?;
        pointer_file.sync_all()?;
        drop(pointer_file);
        if sha256(&pointer)? != COMMITTED_V1_POINTER_SHA256 {
            return Err(ControllerError(
                "publication matrix v1 pointer does not match the committed bytes".to_owned(),
            ));
        }
        verify_self_test_pinned_file(&pointer, COMMITTED_V1_POINTER_SHA256)?;

        let mut baseline = create_new_private(&canonical)?;
        baseline.write_all(BASELINE_BYTES.as_bytes())?;
        baseline.sync_all()?;
        drop(baseline);
        let mut replacement = create_new_private(&pending)?;
        replacement.write_all(REPLACEMENT_BYTES.as_bytes())?;
        replacement.sync_all()?;
        drop(replacement);

        if case.current_held {
            self_test_checked_rename(&canonical, &rollback, &pointer, COMMITTED_V1_POINTER_SHA256)?;
        }
        if case.new_published {
            self_test_checked_rename(&pending, &canonical, &pointer, COMMITTED_V1_POINTER_SHA256)?;
        }
        verify_self_test_boundary_topology(case, &canonical, &rollback, &pending, &failed, false)?;
        verify_self_test_pinned_file(&pointer, COMMITTED_V1_POINTER_SHA256)?;

        if path_exists_without_follow(&rollback)? {
            if path_exists_without_follow(&canonical)? {
                verify_self_test_fixture(&canonical, Some(REPLACEMENT_BYTES))?;
                self_test_checked_rename(
                    &canonical,
                    &failed,
                    &pointer,
                    COMMITTED_V1_POINTER_SHA256,
                )?;
            }
            self_test_checked_rename(&rollback, &canonical, &pointer, COMMITTED_V1_POINTER_SHA256)?;
        }
        verify_self_test_boundary_topology(case, &canonical, &rollback, &pending, &failed, true)?;
        verify_self_test_pinned_file(&pointer, COMMITTED_V1_POINTER_SHA256)?;
        Ok(())
    }

    fn self_test_checked_rename(
        source: &Path,
        destination: &Path,
        pointer: &Path,
        pointer_sha256: &str,
    ) -> Result<()> {
        verify_self_test_pinned_file(pointer, pointer_sha256)?;
        rename_exclusive(source, destination)?;
        fsync_parent(source)?;
        fsync_parent(destination)?;
        verify_self_test_pinned_file(pointer, pointer_sha256)
    }

    fn verify_self_test_boundary_topology(
        case: PublicationBoundaryCase,
        canonical: &Path,
        rollback: &Path,
        pending: &Path,
        failed: &Path,
        recovered: bool,
    ) -> Result<()> {
        const BASELINE_BYTES: &str = "current-isolated-baseline";
        const REPLACEMENT_BYTES: &str = "paired-v2-replacement";

        if recovered {
            verify_self_test_fixture(canonical, Some(BASELINE_BYTES))?;
            verify_self_test_fixture(rollback, None)?;
            if case.new_published {
                verify_self_test_fixture(pending, None)?;
                verify_self_test_fixture(failed, Some(REPLACEMENT_BYTES))?;
            } else {
                verify_self_test_fixture(pending, Some(REPLACEMENT_BYTES))?;
                verify_self_test_fixture(failed, None)?;
            }
        } else if case.new_published {
            verify_self_test_fixture(canonical, Some(REPLACEMENT_BYTES))?;
            verify_self_test_fixture(rollback, Some(BASELINE_BYTES))?;
            verify_self_test_fixture(pending, None)?;
            verify_self_test_fixture(failed, None)?;
        } else if case.current_held {
            verify_self_test_fixture(canonical, None)?;
            verify_self_test_fixture(rollback, Some(BASELINE_BYTES))?;
            verify_self_test_fixture(pending, Some(REPLACEMENT_BYTES))?;
            verify_self_test_fixture(failed, None)?;
        } else {
            verify_self_test_fixture(canonical, Some(BASELINE_BYTES))?;
            verify_self_test_fixture(rollback, None)?;
            verify_self_test_fixture(pending, Some(REPLACEMENT_BYTES))?;
            verify_self_test_fixture(failed, None)?;
        }
        Ok(())
    }

    fn verify_self_test_fixture(path: &Path, expected: Option<&str>) -> Result<()> {
        if let Some(expected) = expected {
            if read_bounded_utf8(path, 128)? != expected {
                return Err(ControllerError(
                    "publication-boundary crash recovery failed".to_owned(),
                ));
            }
        } else if path_exists_without_follow(path)? {
            return Err(ControllerError(
                "current isolated baseline rollback restoration failed".to_owned(),
            ));
        }
        Ok(())
    }
}

fn main() {
    paired_v2::entry();
}
