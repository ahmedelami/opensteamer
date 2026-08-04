//! Standard-library-only primitives for the physical iPhone microphone release oracle.
//!
//! Build with `rustc --edition=2021 -D warnings physical-validation-oracle.rs -o <binary>` using
//! the repository-pinned Rust compiler, then invoke a subcommand described by `usage()`. The
//! executable is intentionally a multicall helper: validation drivers can pin one binary identity
//! instead of trusting ad-hoc interpreter snippets at each evidence boundary.
//!
//! Argument-shape errors exit 2; malformed or unauthenticated evidence exits 3; a valid causal
//! proof that does not overlap exits 9; a timeout exits 124; indeterminate or surviving cleanup
//! exits 125; a runtime-UID leak exits 86 when the wrapped probe would otherwise pass. Wrapped
//! commands otherwise preserve their 0...255 status.

use std::collections::{BTreeMap, HashSet};
use std::env;
use std::ffi::OsString;
use std::fs::{self, File, OpenOptions};
use std::io::{self, Read, Write};
use std::os::fd::OwnedFd;
use std::os::unix::fs::{symlink, FileExt, MetadataExt};
use std::os::unix::net::UnixStream;
use std::os::unix::process::{CommandExt, ExitStatusExt};
use std::path::{Path, PathBuf};
use std::process::{self, Command, ExitStatus, Stdio};
use std::thread;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

const INVALID: i32 = 3;
const NON_OVERLAP: i32 = 9;
const MAXIMUM: u64 = i64::MAX as u64;
const CLOCK_MONOTONIC: i32 = 6; // Darwin's CLOCK_MONOTONIC.
const SIGHUP: i32 = 1;
const SIGTERM: i32 = 15;
const SIGKILL: i32 = 9;
const SIG_IGN: usize = 1;

#[repr(C)]
struct Timespec {
    tv_sec: i64,
    tv_nsec: i64,
}

unsafe extern "C" {
    fn clock_gettime(clock_id: i32, value: *mut Timespec) -> i32;
    fn getpid() -> i32;
    fn getpgrp() -> i32;
    fn getsid(pid: i32) -> i32;
    fn setsid() -> i32;
    fn signal(signal: i32, handler: usize) -> usize;
    fn kill(pid: i32, signal: i32) -> i32;
}

fn usage() -> &'static str {
    "usage: physical-validation-oracle <subcommand> [arguments]\n\
     subcommands:\n\
       wav-tone PATH DURATION_SECONDS\n\
       argv-json [VALUE ...]\n\
       validate-payload-id PAYLOAD_ID\n\
       probe-supervise DIAGNOSTIC COMPLETION UID LIMIT NONCE START_NS PID REPORTED|- MODE END_OFFSET|- -- COMMAND [ARG ...]\n\
       scan-no-bytes ROOT NEEDLE\n\
       unix-ns\n\
       monotonic-ns\n\
       parse-completion PATH EXPECTED_NONCE EXPECTED_START_NS EXPECTED_PID\n\
       validate-overlap REQUEST READINESS UI START COMPLETION OBSERVATION WAIT WRAPPER RESULT NONCE REQUESTED_NS RESUMED_NS UI_COMPLETION UI_CAUSAL_STATE|- BOUNDS_OUT PROBE_OUT VERDICT_OUT NOW_NS\n\
       log-snapshot LOG EXPECTED_ID|- PRIOR_OFFSET PRIOR_SHA256 APPENDED_OUT\n\
       split-lines APPENDED PARTIAL_STATE COMPLETED_OUT\n\
       run-timeout TIMEOUT_SECONDS COMMAND [ARG ...]\n\
       process-group-state PROCESS_GROUP_ID\n\
       isolated-exec COMMAND [ARG ...]\n\
       self-test"
}

fn main() {
    let mut args = env::args_os();
    let _program = args.next();
    let Some(subcommand) = args.next().and_then(|value| value.into_string().ok()) else {
        eprintln!("{}", usage());
        process::exit(2);
    };
    let remaining: Vec<OsString> = args.collect();
    let result = match subcommand.as_str() {
        "wav-tone" => command_wav_tone(&remaining),
        "argv-json" => command_argv_json(&remaining),
        "validate-payload-id" => command_validate_payload_id(&remaining),
        "probe-supervise" => command_probe_supervise(&remaining),
        "scan-no-bytes" => command_scan_no_bytes(&remaining),
        "unix-ns" => command_unix_ns(&remaining),
        "monotonic-ns" => command_monotonic_ns(&remaining),
        "parse-completion" => command_parse_completion(&remaining),
        "validate-overlap" => command_validate_overlap(&remaining),
        "log-snapshot" => command_log_snapshot(&remaining),
        "split-lines" => command_split_lines(&remaining),
        "run-timeout" => command_run_timeout(&remaining),
        "process-group-state" => command_process_group_state(&remaining),
        "isolated-exec" => command_isolated_exec(&remaining),
        "self-test" => command_self_test(&remaining),
        "self-test-session" => command_self_test_session(&remaining),
        "self-test-ignore-signals" => command_self_test_ignore_signals(&remaining),
        _ => {
            eprintln!("unknown subcommand: {subcommand}\n{}", usage());
            Err(2)
        }
    };
    process::exit(result.err().unwrap_or(0));
}

fn utf8(value: &OsString) -> Result<&str, i32> {
    value.to_str().ok_or_else(|| {
        eprintln!("argument is not valid UTF-8");
        2
    })
}

fn exact_args<'a>(args: &'a [OsString], count: usize) -> Result<Vec<&'a str>, i32> {
    if args.len() != count {
        eprintln!("expected {count} arguments, received {}", args.len());
        return Err(2);
    }
    args.iter().map(utf8).collect()
}

fn parse_decimal_u64(text: &str, positive: bool) -> Result<u64, i32> {
    if text.is_empty() || !text.bytes().all(|byte| byte.is_ascii_digit()) {
        return Err(INVALID);
    }
    let value = text.parse::<u64>().map_err(|_| INVALID)?;
    if value > MAXIMUM || (positive && value == 0) {
        return Err(INVALID);
    }
    Ok(value)
}

fn parse_usize(text: &str, positive: bool) -> Result<usize, i32> {
    let value = parse_decimal_u64(text, positive)?;
    usize::try_from(value).map_err(|_| INVALID)
}

fn status_code(status: ExitStatus) -> i32 {
    if let Some(code) = status.code() {
        code
    } else {
        128 + status.signal().unwrap_or(0)
    }
}

fn temporary_path(path: &Path) -> PathBuf {
    let mut name = path.as_os_str().to_os_string();
    name.push(format!(".tmp.{}", process::id()));
    PathBuf::from(name)
}

fn atomic_write(path: &Path, contents: &[u8]) -> io::Result<()> {
    let temporary = temporary_path(path);
    let _ = fs::remove_file(&temporary);
    let mut file = OpenOptions::new()
        .write(true)
        .create_new(true)
        .open(&temporary)?;
    file.write_all(contents)?;
    file.sync_all()?;
    drop(file);
    if let Err(error) = fs::rename(&temporary, path) {
        let _ = fs::remove_file(&temporary);
        return Err(error);
    }
    Ok(())
}

fn command_validate_payload_id(args: &[OsString]) -> Result<(), i32> {
    let values = exact_args(args, 1)?;
    if payload_id_is_valid(values[0]) {
        Ok(())
    } else {
        Err(INVALID)
    }
}

fn payload_id_is_valid(value: &str) -> bool {
    let Some(body) = value.strip_prefix("0~") else {
        return false;
    };
    if body.is_empty() {
        return false;
    }
    let mut padding = false;
    let mut padding_count = 0usize;
    let mut payload_count = 0usize;
    for byte in body.bytes() {
        if byte == b'=' {
            padding = true;
            padding_count += 1;
            if padding_count > 2 {
                return false;
            }
        } else if byte.is_ascii_alphanumeric() || byte == b'_' || byte == b'-' {
            if padding {
                return false;
            }
            payload_count += 1;
        } else {
            return false;
        }
    }
    payload_count > 0
}

fn command_argv_json(args: &[OsString]) -> Result<(), i32> {
    let mut output = String::from("[");
    for (index, value) in args.iter().enumerate() {
        let value = utf8(value)?;
        if index != 0 {
            output.push(',');
            output.push(' ');
        }
        append_json_string(&mut output, value);
    }
    output.push(']');
    println!("{output}");
    Ok(())
}

fn append_json_string(output: &mut String, value: &str) {
    output.push('"');
    for character in value.chars() {
        match character {
            '"' => output.push_str("\\\""),
            '\\' => output.push_str("\\\\"),
            '\u{08}' => output.push_str("\\b"),
            '\u{0c}' => output.push_str("\\f"),
            '\n' => output.push_str("\\n"),
            '\r' => output.push_str("\\r"),
            '\t' => output.push_str("\\t"),
            character if character <= '\u{1f}' => {
                output.push_str(&format!("\\u{:04x}", character as u32));
            }
            character if character.is_ascii() => output.push(character),
            character => {
                let scalar = character as u32;
                if scalar <= 0xffff {
                    output.push_str(&format!("\\u{scalar:04x}"));
                } else {
                    let adjusted = scalar - 0x1_0000;
                    let high = 0xd800 + (adjusted >> 10);
                    let low = 0xdc00 + (adjusted & 0x3ff);
                    output.push_str(&format!("\\u{high:04x}\\u{low:04x}"));
                }
            }
        }
    }
    output.push('"');
}

fn command_wav_tone(args: &[OsString]) -> Result<(), i32> {
    let values = exact_args(args, 2)?;
    let duration = parse_decimal_u64(values[1], true)?;
    if duration > 86_400 {
        eprintln!("tone duration exceeds the 24-hour safety bound");
        return Err(INVALID);
    }
    write_tone(Path::new(values[0]), duration).map_err(|error| {
        eprintln!("could not write deterministic tone: {error}");
        1
    })
}

fn write_tone(path: &Path, duration: u64) -> io::Result<()> {
    const SAMPLE_RATE: u32 = 48_000;
    const CHANNELS: u16 = 2;
    const BITS_PER_SAMPLE: u16 = 16;
    let frame_bytes = u64::from(CHANNELS) * u64::from(BITS_PER_SAMPLE / 8);
    let data_size_u64 = duration
        .checked_mul(u64::from(SAMPLE_RATE))
        .and_then(|value| value.checked_mul(frame_bytes))
        .ok_or_else(|| io::Error::new(io::ErrorKind::InvalidInput, "WAV size overflow"))?;
    let data_size = u32::try_from(data_size_u64)
        .map_err(|_| io::Error::new(io::ErrorKind::InvalidInput, "WAV exceeds RIFF size"))?;
    let riff_size = data_size
        .checked_add(36)
        .ok_or_else(|| io::Error::new(io::ErrorKind::InvalidInput, "RIFF size overflow"))?;

    let mut one_second = Vec::with_capacity(SAMPLE_RATE as usize * frame_bytes as usize);
    for frame in 0..SAMPLE_RATE {
        let high_band = frame >= SAMPLE_RATE / 2;
        let amplitude = if high_band { 3_000.0 } else { 9_000.0 };
        let left_frequency = if high_band { 8_003.0 } else { 997.0 };
        let right_frequency = if high_band { 11_003.0 } else { 1_499.0 };
        let left_phase =
            2.0 * std::f64::consts::PI * left_frequency * f64::from(frame) / f64::from(SAMPLE_RATE);
        let right_phase = 2.0 * std::f64::consts::PI * right_frequency * f64::from(frame)
            / f64::from(SAMPLE_RATE);
        let left = (amplitude * left_phase.sin()) as i16;
        let right = (amplitude * right_phase.sin()) as i16;
        one_second.extend_from_slice(&left.to_le_bytes());
        one_second.extend_from_slice(&right.to_le_bytes());
    }

    let mut file = File::create(path)?;
    file.write_all(b"RIFF")?;
    file.write_all(&riff_size.to_le_bytes())?;
    file.write_all(b"WAVEfmt ")?;
    file.write_all(&16u32.to_le_bytes())?;
    file.write_all(&1u16.to_le_bytes())?;
    file.write_all(&CHANNELS.to_le_bytes())?;
    file.write_all(&SAMPLE_RATE.to_le_bytes())?;
    let byte_rate = SAMPLE_RATE * u32::from(CHANNELS) * u32::from(BITS_PER_SAMPLE / 8);
    file.write_all(&byte_rate.to_le_bytes())?;
    let block_align = CHANNELS * (BITS_PER_SAMPLE / 8);
    file.write_all(&block_align.to_le_bytes())?;
    file.write_all(&BITS_PER_SAMPLE.to_le_bytes())?;
    file.write_all(b"data")?;
    file.write_all(&data_size.to_le_bytes())?;
    for _ in 0..duration {
        file.write_all(&one_second)?;
    }
    file.sync_all()
}

fn command_unix_ns(args: &[OsString]) -> Result<(), i32> {
    exact_args(args, 0)?;
    let duration = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_err(|_| 1)?;
    println!("{}", duration.as_nanos());
    Ok(())
}

fn monotonic_ns() -> Result<u64, i32> {
    let mut value = Timespec {
        tv_sec: 0,
        tv_nsec: 0,
    };
    // SAFETY: `value` points to writable storage of the ABI-compatible `timespec` shape.
    if unsafe { clock_gettime(CLOCK_MONOTONIC, &mut value) } != 0
        || value.tv_sec < 0
        || !(0..1_000_000_000).contains(&value.tv_nsec)
    {
        return Err(1);
    }
    u64::try_from(value.tv_sec)
        .ok()
        .and_then(|seconds| seconds.checked_mul(1_000_000_000))
        .and_then(|base| base.checked_add(value.tv_nsec as u64))
        .ok_or(1)
}

fn command_monotonic_ns(args: &[OsString]) -> Result<(), i32> {
    exact_args(args, 0)?;
    println!("{}", monotonic_ns()?);
    Ok(())
}

#[derive(Clone)]
struct Sha256 {
    state: [u32; 8],
    buffer: [u8; 64],
    buffered: usize,
    length_bytes: u64,
}

impl Sha256 {
    fn new() -> Self {
        Self {
            state: [
                0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab,
                0x5be0cd19,
            ],
            buffer: [0; 64],
            buffered: 0,
            length_bytes: 0,
        }
    }

    fn update(&mut self, mut input: &[u8]) {
        self.length_bytes = self
            .length_bytes
            .checked_add(input.len() as u64)
            .expect("SHA-256 input length overflow");
        if self.buffered != 0 {
            let count = (64 - self.buffered).min(input.len());
            self.buffer[self.buffered..self.buffered + count].copy_from_slice(&input[..count]);
            self.buffered += count;
            input = &input[count..];
            if self.buffered == 64 {
                let block = self.buffer;
                self.compress(&block);
                self.buffered = 0;
            }
        }
        while input.len() >= 64 {
            let block: &[u8; 64] = input[..64].try_into().expect("fixed SHA-256 block");
            self.compress(block);
            input = &input[64..];
        }
        self.buffer[..input.len()].copy_from_slice(input);
        self.buffered = input.len();
    }

    fn finish(mut self) -> [u8; 32] {
        let bit_length = self
            .length_bytes
            .checked_mul(8)
            .expect("SHA-256 bit length overflow");
        self.buffer[self.buffered] = 0x80;
        self.buffered += 1;
        if self.buffered > 56 {
            self.buffer[self.buffered..].fill(0);
            let block = self.buffer;
            self.compress(&block);
            self.buffer = [0; 64];
        } else {
            self.buffer[self.buffered..56].fill(0);
        }
        self.buffer[56..].copy_from_slice(&bit_length.to_be_bytes());
        let block = self.buffer;
        self.compress(&block);
        let mut output = [0u8; 32];
        for (chunk, word) in output.chunks_exact_mut(4).zip(self.state) {
            chunk.copy_from_slice(&word.to_be_bytes());
        }
        output
    }

    fn compress(&mut self, block: &[u8; 64]) {
        const K: [u32; 64] = [
            0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4,
            0xab1c5ed5, 0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe,
            0x9bdc06a7, 0xc19bf174, 0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f,
            0x4a7484aa, 0x5cb0a9dc, 0x76f988da, 0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7,
            0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967, 0x27b70a85, 0x2e1b2138, 0x4d2c6dfc,
            0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85, 0xa2bfe8a1, 0xa81a664b,
            0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070, 0x19a4c116,
            0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
            0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7,
            0xc67178f2,
        ];
        let mut words = [0u32; 64];
        for (index, chunk) in block.chunks_exact(4).enumerate() {
            words[index] = u32::from_be_bytes(chunk.try_into().expect("four-byte word"));
        }
        for index in 16..64 {
            let s0 = words[index - 15].rotate_right(7)
                ^ words[index - 15].rotate_right(18)
                ^ (words[index - 15] >> 3);
            let s1 = words[index - 2].rotate_right(17)
                ^ words[index - 2].rotate_right(19)
                ^ (words[index - 2] >> 10);
            words[index] = words[index - 16]
                .wrapping_add(s0)
                .wrapping_add(words[index - 7])
                .wrapping_add(s1);
        }
        let [mut a, mut b, mut c, mut d, mut e, mut f, mut g, mut h] = self.state;
        for index in 0..64 {
            let s1 = e.rotate_right(6) ^ e.rotate_right(11) ^ e.rotate_right(25);
            let choice = (e & f) ^ ((!e) & g);
            let first = h
                .wrapping_add(s1)
                .wrapping_add(choice)
                .wrapping_add(K[index])
                .wrapping_add(words[index]);
            let s0 = a.rotate_right(2) ^ a.rotate_right(13) ^ a.rotate_right(22);
            let majority = (a & b) ^ (a & c) ^ (b & c);
            let second = s0.wrapping_add(majority);
            h = g;
            g = f;
            f = e;
            e = d.wrapping_add(first);
            d = c;
            c = b;
            b = a;
            a = first.wrapping_add(second);
        }
        for (state, value) in self.state.iter_mut().zip([a, b, c, d, e, f, g, h]) {
            *state = state.wrapping_add(value);
        }
    }
}

fn sha256_hex(bytes: &[u8]) -> String {
    let mut digest = Sha256::new();
    digest.update(bytes);
    digest
        .finish()
        .iter()
        .map(|byte| format!("{byte:02x}"))
        .collect()
}

fn command_log_snapshot(args: &[OsString]) -> Result<(), i32> {
    let values = exact_args(args, 5)?;
    let expected_identity = match values[1] {
        "" | "-" => None,
        value => Some(value),
    };
    let prior_offset = parse_usize(values[2], false)?;
    let prior_digest = values[3];
    if prior_digest.len() != 64 || !prior_digest.bytes().all(|byte| byte.is_ascii_hexdigit()) {
        return Err(2);
    }
    let log_path = Path::new(values[0]);
    let output_path = Path::new(values[4]);
    let _ = fs::remove_file(output_path);
    let ready_path = env::var_os("OPENSTEAMER_LOG_SNAPSHOT_TEST_READY").map(PathBuf::from);
    let proceed_path = env::var_os("OPENSTEAMER_LOG_SNAPSHOT_TEST_PROCEED").map(PathBuf::from);
    let mut hook_used = false;
    let mut last_reason = String::from("log snapshot did not stabilize");

    for _ in 0..20 {
        let file = match File::open(log_path) {
            Ok(file) => file,
            Err(error) => {
                last_reason = format!("could not open log: {error}");
                thread::sleep(Duration::from_millis(10));
                continue;
            }
        };
        let before = match file.metadata() {
            Ok(metadata) => metadata,
            Err(error) => {
                last_reason = format!("could not stat opened log: {error}");
                thread::sleep(Duration::from_millis(10));
                continue;
            }
        };
        let identity = format!("{}:{}", before.dev(), before.ino());
        if expected_identity.is_some_and(|expected| expected != identity) {
            eprintln!("log path identity changed");
            return Err(INVALID);
        }
        let length = usize::try_from(before.size()).map_err(|_| INVALID)?;
        if length < prior_offset {
            eprintln!("log became shorter than the consumed byte offset");
            return Err(INVALID);
        }

        if let (Some(ready), Some(proceed)) = (&ready_path, &proceed_path) {
            if !hook_used {
                hook_used = true;
                fs::write(ready, b"ready\n").map_err(|error| {
                    eprintln!("snapshot test hook could not publish readiness: {error}");
                    4
                })?;
                let deadline = Instant::now() + Duration::from_secs(2);
                while !proceed.exists() && Instant::now() < deadline {
                    thread::sleep(Duration::from_millis(5));
                }
                if !proceed.exists() {
                    eprintln!("snapshot test hook timed out");
                    return Err(4);
                }
            }
        }

        let mut data = vec![0u8; length];
        if let Err(error) = read_exact_at(&file, &mut data, 0) {
            last_reason = format!("short read from opened log: {error}");
            thread::sleep(Duration::from_millis(10));
            continue;
        }
        let after = match file.metadata() {
            Ok(metadata) => metadata,
            Err(error) => {
                last_reason = format!("could not restat opened log: {error}");
                thread::sleep(Duration::from_millis(10));
                continue;
            }
        };
        let path_after = match fs::metadata(log_path) {
            Ok(metadata) => metadata,
            Err(error) => {
                last_reason = format!("could not restat log path: {error}");
                thread::sleep(Duration::from_millis(10));
                continue;
            }
        };
        if metadata_version(&before) != metadata_version(&after) {
            last_reason = String::from("opened log changed during snapshot");
            thread::sleep(Duration::from_millis(10));
            continue;
        }
        if (path_after.dev(), path_after.ino()) != (after.dev(), after.ino()) {
            last_reason = String::from("log path changed during snapshot");
            thread::sleep(Duration::from_millis(10));
            continue;
        }
        if sha256_hex(&data[..prior_offset]) != prior_digest {
            eprintln!("consumed log prefix digest changed");
            return Err(INVALID);
        }
        let digest = sha256_hex(&data);
        atomic_write(output_path, &data[prior_offset..]).map_err(|error| {
            eprintln!("could not publish appended log snapshot: {error}");
            1
        })?;
        println!("{identity}");
        println!("{}", data.len());
        println!("{digest}");
        println!("{}", u8::from(data.is_empty() || data.ends_with(b"\n")));
        return Ok(());
    }
    let _ = fs::remove_file(output_path);
    eprintln!("{last_reason}");
    Err(INVALID)
}

fn metadata_version(metadata: &fs::Metadata) -> (u64, u64, u64, i64, i64, i64, i64) {
    (
        metadata.dev(),
        metadata.ino(),
        metadata.size(),
        metadata.mtime(),
        metadata.mtime_nsec(),
        metadata.ctime(),
        metadata.ctime_nsec(),
    )
}

fn read_exact_at(file: &File, mut destination: &mut [u8], mut offset: u64) -> io::Result<()> {
    while !destination.is_empty() {
        let count = file.read_at(destination, offset)?;
        if count == 0 {
            return Err(io::Error::new(io::ErrorKind::UnexpectedEof, "short pread"));
        }
        destination = &mut destination[count..];
        offset += count as u64;
    }
    Ok(())
}

fn command_split_lines(args: &[OsString]) -> Result<(), i32> {
    let values = exact_args(args, 3)?;
    split_lines(
        Path::new(values[0]),
        Path::new(values[1]),
        Path::new(values[2]),
    )
    .map_err(|error| {
        eprintln!("could not split completed log lines: {error}");
        1
    })
}

fn split_lines(appended: &Path, partial_state: &Path, completed: &Path) -> io::Result<()> {
    let mut payload = match fs::read(partial_state) {
        Ok(bytes) => bytes,
        Err(error) if error.kind() == io::ErrorKind::NotFound => Vec::new(),
        Err(error) => return Err(error),
    };
    payload.extend_from_slice(&fs::read(appended)?);
    let (complete_bytes, partial_bytes) = match payload.iter().rposition(|byte| *byte == b'\n') {
        Some(boundary) => (&payload[..=boundary], &payload[boundary + 1..]),
        None => (&[][..], payload.as_slice()),
    };
    atomic_write(completed, complete_bytes)?;
    atomic_write(partial_state, partial_bytes)
}

fn command_scan_no_bytes(args: &[OsString]) -> Result<(), i32> {
    let values = exact_args(args, 2)?;
    if values[1].is_empty() {
        return Err(INVALID);
    }
    match scan_tree(Path::new(values[0]), values[1].as_bytes()) {
        Ok(false) => Ok(()),
        Ok(true) => Err(1),
        Err(error) => {
            eprintln!("retained-artifact scan failed closed: {error}");
            Err(1)
        }
    }
}

fn scan_tree(root: &Path, needle: &[u8]) -> io::Result<bool> {
    let mut pending = vec![root.to_path_buf()];
    while let Some(directory) = pending.pop() {
        for entry in fs::read_dir(&directory)? {
            let entry = entry?;
            let file_type = entry.file_type()?;
            if file_type.is_dir() {
                pending.push(entry.path());
            } else if file_type.is_file() {
                if file_contains(&entry.path(), needle)? {
                    return Ok(true);
                }
            } else if file_type.is_symlink() {
                // Match `os.walk(..., followlinks=False)`: a valid directory symlink is not
                // traversed, while a file symlink is scanned. Broken or unsupported targets fail
                // the privacy gate closed instead of disappearing from the retained-artifact set.
                let target = entry.path().metadata()?;
                if target.is_file() {
                    if file_contains(&entry.path(), needle)? {
                        return Ok(true);
                    }
                } else if !target.is_dir() {
                    return Err(io::Error::new(
                        io::ErrorKind::InvalidData,
                        "unsupported retained-artifact symlink target",
                    ));
                }
            } else {
                return Err(io::Error::new(
                    io::ErrorKind::InvalidData,
                    "unsupported retained-artifact filesystem node",
                ));
            }
        }
    }
    Ok(false)
}

fn file_contains(path: &Path, needle: &[u8]) -> io::Result<bool> {
    let mut file = File::open(path)?;
    let mut buffer = vec![0u8; 1024 * 1024];
    let keep = needle.len().saturating_sub(1);
    let mut carry = Vec::with_capacity(keep);
    loop {
        let count = file.read(&mut buffer)?;
        if count == 0 {
            return Ok(false);
        }
        let mut combined = Vec::with_capacity(carry.len() + count);
        combined.extend_from_slice(&carry);
        combined.extend_from_slice(&buffer[..count]);
        if contains_bytes(&combined, needle) {
            return Ok(true);
        }
        let start = combined.len().saturating_sub(keep);
        carry.clear();
        carry.extend_from_slice(&combined[start..]);
    }
}

fn contains_bytes(haystack: &[u8], needle: &[u8]) -> bool {
    !needle.is_empty()
        && haystack
            .windows(needle.len())
            .any(|window| window == needle)
}

fn command_isolated_exec(args: &[OsString]) -> Result<(), i32> {
    if args.is_empty() {
        return Err(2);
    }
    // SAFETY: these calls take no pointers. Failure is handled before replacing the process.
    unsafe {
        if getpgrp() != getpid() && setsid() == -1 {
            eprintln!(
                "could not create isolated validation session: {}",
                io::Error::last_os_error()
            );
            return Err(127);
        }
    }
    let error = Command::new(&args[0]).args(&args[1..]).exec();
    eprintln!("could not execute isolated command: {error}");
    Err(127)
}

fn command_self_test_session(args: &[OsString]) -> Result<(), i32> {
    exact_args(args, 0)?;
    // SAFETY: these identity calls take no pointers and cannot mutate process state.
    let (pid, group, session) = unsafe { (getpid(), getpgrp(), getsid(0)) };
    if pid > 0 && pid == group && pid == session {
        Ok(())
    } else {
        Err(1)
    }
}

fn command_self_test_ignore_signals(args: &[OsString]) -> Result<(), i32> {
    let values = exact_args(args, 1)?;
    // SAFETY: Darwin defines SIG_IGN as the special handler value 1. This hidden self-test mode
    // deliberately survives TERM/HUP until the timeout supervisor's unconditional KILL sweep.
    unsafe {
        if signal(SIGTERM, SIG_IGN) == usize::MAX || signal(SIGHUP, SIG_IGN) == usize::MAX {
            return Err(1);
        }
    }
    atomic_write(
        Path::new(values[0]),
        format!("{}\n", process::id()).as_bytes(),
    )
    .map_err(|_| 1)?;
    loop {
        thread::sleep(Duration::from_secs(30));
    }
}

fn command_run_timeout(args: &[OsString]) -> Result<(), i32> {
    if args.len() < 2 {
        return Err(2);
    }
    let timeout_text = utf8(&args[0])?;
    let timeout = timeout_text.parse::<f64>().map_err(|_| 2)?;
    if !timeout.is_finite() || timeout <= 0.0 || timeout > 86_400.0 {
        return Err(2);
    }
    let mut command = Command::new(&args[1]);
    command.args(&args[2..]);
    // SAFETY: `setsid` is async-signal-safe and the closure does not allocate or capture state.
    unsafe {
        command.pre_exec(|| {
            if setsid() == -1 {
                Err(io::Error::last_os_error())
            } else {
                Ok(())
            }
        });
    }
    let mut child = command.spawn().map_err(|error| {
        eprintln!("could not start bounded command: {error}");
        127
    })?;
    let group = child.id() as i32;
    let deadline = Instant::now() + Duration::from_secs_f64(timeout);
    loop {
        if !observation_precedes_deadline(Instant::now(), deadline) {
            break;
        }
        match child.try_wait() {
            Ok(Some(status)) => {
                // `try_wait` can observe an exit after the absolute deadline even when the
                // preceding loop condition sampled just before it. Never turn that race into a
                // successful bounded command.
                if !observation_precedes_deadline(Instant::now(), deadline) {
                    break;
                }
                let leader_result = exit_result(status_code(status));
                match process_group_state(group) {
                    Ok(false) => {
                        if observation_precedes_deadline(Instant::now(), deadline) {
                            return leader_result;
                        }
                        break;
                    }
                    Ok(true) => eprintln!(
                        "bounded command leader exited while descendants remained in its process group"
                    ),
                    Err(_) => eprintln!(
                        "bounded command process-group absence could not be proven after leader exit"
                    ),
                }
                if sweep_surviving_process_group(group).is_err() {
                    eprintln!(
                        "bounded command descendants survived the forced process-group sweep"
                    );
                    return Err(125);
                }
                return match leader_result {
                    Ok(()) => Err(1),
                    Err(status) => Err(status),
                };
            }
            Ok(None) if observation_precedes_deadline(Instant::now(), deadline) => {
                thread::sleep(Duration::from_millis(10));
            }
            Ok(None) => break,
            Err(error) => {
                eprintln!("could not wait for bounded command: {error}");
                return Err(1);
            }
        }
    }
    signal_group(group, SIGTERM);
    let term_deadline = Instant::now() + Duration::from_secs(1);
    while Instant::now() < term_deadline {
        match child.try_wait() {
            Ok(Some(_)) => break,
            Ok(None) => thread::sleep(Duration::from_millis(10)),
            Err(_) => break,
        }
    }
    // Always sweep the group: the leader can exit while a descendant ignores TERM.
    signal_group(group, SIGKILL);
    let _ = child.wait();
    match wait_for_process_group_exit(group, Duration::from_secs(1)) {
        Ok(true) => {}
        Ok(false) | Err(_) => {
            // Retain the process-group handle and re-sweep once. A cleanup failure is distinct
            // from the wrapped command's ordinary timeout and must never be reported as 124.
            signal_group(group, SIGKILL);
            if wait_for_process_group_exit(group, Duration::from_secs(1)) != Ok(true) {
                eprintln!("timed-out command process group survived the repeated KILL sweep");
                return Err(125);
            }
        }
    }
    Err(124)
}

fn observation_precedes_deadline(observed_at: Instant, deadline: Instant) -> bool {
    observed_at < deadline
}

fn signal_group(group: i32, signal: i32) {
    if group > 0 {
        // SAFETY: a negative PID addresses exactly the newly-created process group.
        unsafe {
            kill(-group, signal);
        }
    }
}

fn classify_process_group_probe(result: i32, error: Option<i32>) -> Result<bool, i32> {
    if result == 0 {
        Ok(true)
    } else if error == Some(3) {
        Ok(false)
    } else {
        Err(125)
    }
}

fn process_group_state(group: i32) -> Result<bool, i32> {
    if group <= 0 {
        return Err(2);
    }
    // SAFETY: signal zero performs only an existence/permission check against the isolated group.
    let result = unsafe { kill(-group, 0) };
    let error = if result == 0 {
        None
    } else {
        io::Error::last_os_error().raw_os_error()
    };
    classify_process_group_probe(result, error)
}

fn wait_for_process_group_exit(group: i32, timeout: Duration) -> Result<bool, i32> {
    let deadline = Instant::now() + timeout;
    loop {
        match process_group_state(group)? {
            false => return Ok(true),
            true if Instant::now() < deadline => thread::sleep(Duration::from_millis(10)),
            true => return Ok(false),
        }
    }
}

fn sweep_surviving_process_group(group: i32) -> Result<(), i32> {
    signal_group(group, SIGTERM);
    let _ = wait_for_process_group_exit(group, Duration::from_secs(1));
    // The KILL sweep is unconditional so a TERM-handling leader cannot hide a resistant child.
    signal_group(group, SIGKILL);
    if wait_for_process_group_exit(group, Duration::from_secs(1)) == Ok(true) {
        return Ok(());
    }
    signal_group(group, SIGKILL);
    if wait_for_process_group_exit(group, Duration::from_secs(1)) == Ok(true) {
        Ok(())
    } else {
        Err(125)
    }
}

fn command_process_group_state(args: &[OsString]) -> Result<(), i32> {
    let values = exact_args(args, 1)?;
    let group = values[0].parse::<i32>().map_err(|_| 2)?;
    match process_group_state(group)? {
        true => {
            println!("exists");
            Ok(())
        }
        false => {
            println!("absent");
            Err(1)
        }
    }
}

fn process_exists(pid: i32) -> bool {
    if pid <= 0 {
        return false;
    }
    // SAFETY: signal zero performs only an existence/permission check.
    unsafe { kill(pid, 0) == 0 }
}

fn exit_result(code: i32) -> Result<(), i32> {
    if code == 0 {
        Ok(())
    } else {
        Err(code.clamp(1, 255))
    }
}

fn command_probe_supervise(args: &[OsString]) -> Result<(), i32> {
    let separator = args.iter().position(|value| value == "--").ok_or(2)?;
    if separator != 10 || separator + 1 >= args.len() {
        eprintln!("probe-supervise requires ten metadata arguments, --, and a command");
        return Err(2);
    }
    let values: Vec<&str> = args[..separator]
        .iter()
        .map(utf8)
        .collect::<Result<_, _>>()?;
    let diagnostic_path = Path::new(values[0]);
    let completion_path = Path::new(values[1]);
    let runtime_uid = values[2].as_bytes();
    if runtime_uid.is_empty() {
        return Err(INVALID);
    }
    let limit = parse_usize(values[3], true)?;
    if limit > 16 * 1024 * 1024 {
        return Err(INVALID);
    }
    let nonce = values[4];
    if nonce.is_empty()
        || nonce.len() > 128
        || !nonce
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || byte == b'-')
    {
        return Err(INVALID);
    }
    let probe_start = parse_decimal_u64(values[5], false)?;
    let production_pid = parse_decimal_u64(values[6], false)?;
    let reported_status = match values[7] {
        "" | "-" => None,
        text => Some(parse_decimal_u64(text, false)?),
    };
    let completion_mode = values[8];
    if !matches!(
        completion_mode,
        "normal" | "missing" | "nonce-mismatch" | "malformed" | "wedged-after-completion"
    ) {
        return Err(INVALID);
    }
    let end_offset = match values[9] {
        "" | "-" => None,
        text => Some(parse_decimal_u64(text, false)?),
    };
    let _ = fs::remove_file(diagnostic_path);
    let _ = fs::remove_file(completion_path);

    let command = &args[separator + 1];
    let command_args = &args[separator + 2..];
    let mut retained = Vec::with_capacity(limit.min(65_536));
    let mut total = 0usize;
    let mut leaked = false;
    let mut carry = Vec::with_capacity(runtime_uid.len().saturating_sub(1));

    let mut child_command = Command::new(command);
    child_command.args(command_args);
    let (mut reader, writer) = UnixStream::pair().map_err(|error| {
        eprintln!("could not create probe output pipe: {error}");
        1
    })?;
    let second_writer = writer.try_clone().map_err(|error| {
        eprintln!("could not duplicate probe output pipe: {error}");
        1
    })?;
    let stdout_fd: OwnedFd = writer.into();
    let stderr_fd: OwnedFd = second_writer.into();
    child_command.stdout(Stdio::from(stdout_fd));
    child_command.stderr(Stdio::from(stderr_fd));

    let spawn_result = child_command.spawn();
    // `Command` owns the parent copies of the configured Stdio descriptors. Drop it before the
    // read loop so EOF reflects only the spawned command and its descendants.
    drop(child_command);
    let (mut return_code, launched) = match spawn_result {
        Ok(mut child) => {
            let mut chunk = [0u8; 4096];
            loop {
                let count = reader.read(&mut chunk).map_err(|error| {
                    eprintln!("could not consume probe diagnostics: {error}");
                    1
                })?;
                if count == 0 {
                    break;
                }
                total = total.saturating_add(count);
                let mut combined = Vec::with_capacity(carry.len() + count);
                combined.extend_from_slice(&carry);
                combined.extend_from_slice(&chunk[..count]);
                if contains_bytes(&combined, runtime_uid) {
                    leaked = true;
                }
                let keep = runtime_uid.len().saturating_sub(1);
                let start = combined.len().saturating_sub(keep);
                carry.clear();
                carry.extend_from_slice(&combined[start..]);
                if retained.len() < limit {
                    let take = (limit - retained.len()).min(count);
                    retained.extend_from_slice(&chunk[..take]);
                }
            }
            let status = child.wait().map_err(|error| {
                eprintln!("could not wait for probe: {error}");
                1
            })?;
            (status_code(status), true)
        }
        Err(_) => {
            retained.extend_from_slice(b"diagnostic=probe-launch-failed\n");
            (127, false)
        }
    };
    drop(reader);
    if leaked && return_code == 0 {
        return_code = 86;
    }

    if return_code == 0 {
        match fs::remove_file(diagnostic_path) {
            Ok(()) => {}
            Err(error) if error.kind() == io::ErrorKind::NotFound => {}
            Err(error) => {
                eprintln!("could not remove stale probe diagnostics: {error}");
                return Err(1);
            }
        }
    } else {
        let payload = if leaked {
            b"diagnostic=runtime-uid-output-rejected\n".to_vec()
        } else if retained.is_empty() {
            b"diagnostic=probe-failed-without-output\n".to_vec()
        } else if total > limit {
            let marker = b"\ndiagnostic=truncated\n";
            let prefix = limit.saturating_sub(marker.len()).min(retained.len());
            let mut payload = retained[..prefix].to_vec();
            payload.extend_from_slice(marker);
            payload
        } else {
            retained
        };
        atomic_write(diagnostic_path, &payload).map_err(|error| {
            eprintln!("could not publish bounded probe diagnostics: {error}");
            1
        })?;
    }

    if completion_mode != "missing" {
        let completion_nonce = if completion_mode == "nonce-mismatch" {
            format!("{nonce}-mismatch")
        } else {
            nonce.to_owned()
        };
        let probe_end = match end_offset {
            Some(offset) => probe_start.checked_add(offset).ok_or(INVALID)?,
            None => monotonic_ns()?,
        };
        let completion = if completion_mode == "malformed" {
            String::from("malformed\n")
        } else {
            format!(
                "schema=opensteamer.blackhole-probe-completion.v1\n\
                 nonce={completion_nonce}\n\
                 probeStartMonotonicNs={probe_start}\n\
                 probeEndMonotonicNs={probe_end}\n\
                 status={}\n\
                 productionPIDAtStart={production_pid}\n",
                reported_status.unwrap_or(return_code as u64),
            )
        };
        atomic_write(completion_path, completion.as_bytes()).map_err(|error| {
            eprintln!("could not publish probe completion: {error}");
            1
        })?;
        if completion_mode == "wedged-after-completion" {
            loop {
                thread::sleep(Duration::from_secs(60));
            }
        }
    }
    let _ = launched; // Kept explicit: launch failure is represented by status 127 and evidence.
    exit_result(return_code)
}

fn command_parse_completion(args: &[OsString]) -> Result<(), i32> {
    let values = exact_args(args, 4)?;
    let expected_start = parse_decimal_u64(values[2], false)?;
    let expected_pid = parse_decimal_u64(values[3], false)?;
    let (end, status) = parse_completion(
        Path::new(values[0]),
        values[1],
        expected_start,
        expected_pid,
    )?;
    println!("{end} {status}");
    Ok(())
}

fn parse_completion(
    path: &Path,
    expected_nonce: &str,
    expected_start: u64,
    expected_pid: u64,
) -> Result<(u64, u64), i32> {
    let expected = [
        "schema",
        "nonce",
        "probeStartMonotonicNs",
        "probeEndMonotonicNs",
        "status",
        "productionPIDAtStart",
    ];
    let values = parse_exact_record(path, &expected)?;
    if values["schema"] != "opensteamer.blackhole-probe-completion.v1"
        || values["nonce"] != expected_nonce
    {
        return Err(INVALID);
    }
    let start = record_number(&values, "probeStartMonotonicNs", false)?;
    let end = record_number(&values, "probeEndMonotonicNs", false)?;
    let status = record_number(&values, "status", false)?;
    let pid = record_number(&values, "productionPIDAtStart", false)?;
    if start != expected_start || pid != expected_pid || end <= start {
        return Err(INVALID);
    }
    if expected_nonce != "unbound" && (start == 0 || pid == 0) {
        return Err(INVALID);
    }
    Ok((end, status))
}

fn parse_exact_record(path: &Path, expected: &[&str]) -> Result<BTreeMap<String, String>, i32> {
    let text = fs::read_to_string(path).map_err(|_| INVALID)?;
    let lines: Vec<&str> = text.lines().collect();
    if lines.len() != expected.len() {
        return Err(INVALID);
    }
    let mut values = BTreeMap::new();
    for raw_line in lines {
        let line = raw_line.strip_suffix('\r').unwrap_or(raw_line);
        let Some((key, value)) = line.split_once('=') else {
            return Err(INVALID);
        };
        if key.is_empty() || values.insert(key.to_owned(), value.to_owned()).is_some() {
            return Err(INVALID);
        }
    }
    let observed: HashSet<&str> = values.keys().map(String::as_str).collect();
    let required: HashSet<&str> = expected.iter().copied().collect();
    if observed != required {
        return Err(INVALID);
    }
    Ok(values)
}

fn record_number(values: &BTreeMap<String, String>, key: &str, positive: bool) -> Result<u64, i32> {
    parse_decimal_u64(values.get(key).ok_or(INVALID)?, positive)
}

fn command_validate_overlap(args: &[OsString]) -> Result<(), i32> {
    let values = exact_args(args, 18)?;
    let outputs = [
        Path::new(values[14]),
        Path::new(values[15]),
        Path::new(values[16]),
    ];
    for output in outputs {
        let _ = fs::remove_file(output);
    }
    match validate_overlap(&values) {
        Ok((bounds, probe, verdict)) => {
            if let Err(error) = atomic_write(outputs[0], bounds.as_bytes())
                .and_then(|_| atomic_write(outputs[1], probe.as_bytes()))
                .and_then(|_| atomic_write(outputs[2], verdict.as_bytes()))
            {
                for output in outputs {
                    let _ = fs::remove_file(output);
                }
                eprintln!("could not atomically publish overlap proof: {error}");
                Err(INVALID)
            } else {
                Ok(())
            }
        }
        Err(status) => {
            for output in outputs {
                let _ = fs::remove_file(output);
            }
            Err(status)
        }
    }
}

fn validate_overlap(values: &[&str]) -> Result<(String, String, String), i32> {
    let request = parse_exact_record(
        Path::new(values[0]),
        &[
            "schema",
            "nonce",
            "requestedAtMonotonicNs",
            "cursorOffset",
            "cursorDigest",
        ],
    )?;
    let readiness = parse_exact_record(
        Path::new(values[1]),
        &[
            "schema",
            "nonce",
            "requestedAtMonotonicNs",
            "resumedAtMonotonicNs",
            "readyAtMonotonicNs",
            "probeStartedAtMonotonicNs",
            "productionPID",
            "hostPID",
            "blackHolePeerGeneration",
            "authenticatedConnectionCount",
            "cursorOffset",
            "cursorDigest",
        ],
    )?;
    let ui = parse_exact_record(
        Path::new(values[2]),
        &[
            "schema",
            "nonce",
            "continuityDurationNs",
            "appPIDAtStart",
            "appPIDAtEnd",
        ],
    )?;
    let start = parse_exact_record(
        Path::new(values[3]),
        &[
            "schema",
            "boundary",
            "nonce",
            "bundleIdentifier",
            "pid",
            "observedAtMonotonicNs",
        ],
    )?;
    let completion = parse_exact_record(
        Path::new(values[4]),
        &[
            "schema",
            "boundary",
            "nonce",
            "bundleIdentifier",
            "pid",
            "observedAtMonotonicNs",
        ],
    )?;
    let observation = parse_exact_record(
        Path::new(values[5]),
        &[
            "schema",
            "nonce",
            "probeEndMonotonicNs",
            "completionObservedAtMonotonicNs",
            "status",
            "productionPIDAtCompletion",
        ],
    )?;
    let waited = parse_exact_record(
        Path::new(values[6]),
        &[
            "schema",
            "nonce",
            "wrapperPID",
            "probeEndMonotonicNs",
            "completionStatus",
            "waitStatus",
        ],
    )?;
    let wrapper = parse_exact_record(
        Path::new(values[7]),
        &[
            "schema",
            "nonce",
            "probeStartMonotonicNs",
            "probeEndMonotonicNs",
            "status",
            "productionPIDAtStart",
        ],
    )?;
    let ui_completion = parse_exact_record(
        Path::new(values[12]),
        &["schema", "nonce", "observedAtMonotonicNs"],
    )?;
    let ui_causal_state = match values[13] {
        "-" => None,
        path => Some(parse_exact_record(
            Path::new(path),
            &[
                "schema",
                "nonce",
                "state",
                "sequence",
                "acousticToken",
                "resumedAtMonotonicNs",
                "acknowledgementAcceptedAtMonotonicNs",
                "observedAtMonotonicNs",
            ],
        )?),
    };
    let result_text = fs::read_to_string(values[8]).map_err(|_| INVALID)?;
    let result = JsonParser::new(&result_text).parse().map_err(|_| INVALID)?;
    let result_object = result.as_object().ok_or(INVALID)?;
    let expected_nonce = values[9];
    if !(16..=128).contains(&expected_nonce.len())
        || !expected_nonce
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || byte == b'-')
    {
        return Err(INVALID);
    }
    let expected_bundle =
        env::var("OPENSTEAMER_EXPECTED_APP_BUNDLE_IDENTIFIER").map_err(|_| INVALID)?;
    if request["schema"] != "opensteamer.raw-session-readiness.v2"
        || readiness["schema"] != "opensteamer.raw-session-readiness.v3"
        || ui["schema"] != "opensteamer.raw-ui-runtime.v1"
        || ui_completion["schema"] != "opensteamer.raw-ui-completion-observation.v1"
        || start["schema"] != "opensteamer.production-app-probe-boundary.v1"
        || completion["schema"] != start["schema"]
        || observation["schema"] != "opensteamer.blackhole-probe-completion-observation.v1"
        || waited["schema"] != "opensteamer.blackhole-probe-wait.v1"
        || wrapper["schema"] != "opensteamer.blackhole-probe-completion.v1"
        || json_object_string(result_object, "schema")
            != Some("opensteamer.physical-blackhole-microphone.v1")
        || json_object_string(result_object, "status") != Some("passed")
        || json_object_string(result_object, "runNonce") != Some(expected_nonce)
    {
        return Err(INVALID);
    }
    for record in [
        &request,
        &readiness,
        &ui,
        &start,
        &completion,
        &observation,
        &waited,
        &wrapper,
        &ui_completion,
    ] {
        if record["nonce"] != expected_nonce {
            return Err(INVALID);
        }
    }
    if start["boundary"] != "start"
        || completion["boundary"] != "completion"
        || start["bundleIdentifier"] != expected_bundle
        || completion["bundleIdentifier"] != expected_bundle
    {
        return Err(INVALID);
    }

    let requested = record_number(&request, "requestedAtMonotonicNs", true)?;
    let resumed = record_number(&readiness, "resumedAtMonotonicNs", true)?;
    let ready = record_number(&readiness, "readyAtMonotonicNs", true)?;
    let probe_start = record_number(&wrapper, "probeStartMonotonicNs", true)?;
    let probe_end = record_number(&wrapper, "probeEndMonotonicNs", true)?;
    let continuity = record_number(&ui, "continuityDurationNs", true)?;
    let ui_completion_observed = record_number(&ui_completion, "observedAtMonotonicNs", true)?;
    let now = parse_decimal_u64(values[17], true)?;
    let expected_requested = parse_decimal_u64(values[10], true)?;
    let expected_resumed = parse_decimal_u64(values[11], true)?;
    if requested != expected_requested || resumed != expected_resumed {
        return Err(INVALID);
    }
    if let Some(causal_state) = &ui_causal_state {
        let acoustic_token = &causal_state["acousticToken"];
        if causal_state["schema"] != "opensteamer.call-ui-hosted-state-observation.v2"
            || causal_state["nonce"] != expected_nonce
            || causal_state["state"] != "hosted-call-active"
            || record_number(causal_state, "sequence", true)? != 2
            || !(16..=128).contains(&acoustic_token.len())
            || !acoustic_token
                .bytes()
                .all(|byte| byte.is_ascii_alphanumeric() || byte == b'-')
            || record_number(causal_state, "resumedAtMonotonicNs", true)? != resumed
        {
            return Err(INVALID);
        }
        let acknowledged =
            record_number(causal_state, "acknowledgementAcceptedAtMonotonicNs", true)?;
        let observed = record_number(causal_state, "observedAtMonotonicNs", true)?;
        if !(resumed < acknowledged && acknowledged < observed && observed <= ready) {
            return Err(NON_OVERLAP);
        }
    }
    let start_pid = record_number(&start, "pid", true)?;
    let completion_pid = record_number(&completion, "pid", true)?;
    let ui_start_pid = record_number(&ui, "appPIDAtStart", true)?;
    let ui_end_pid = record_number(&ui, "appPIDAtEnd", true)?;
    let pid_values = [
        start_pid,
        completion_pid,
        ui_start_pid,
        ui_end_pid,
        record_number(&readiness, "productionPID", true)?,
        record_number(&wrapper, "productionPIDAtStart", true)?,
        record_number(&observation, "productionPIDAtCompletion", true)?,
    ];
    if pid_values.iter().any(|pid| *pid != start_pid)
        || record_number(&wrapper, "status", false)? != 0
        || record_number(&observation, "status", false)? != 0
        || record_number(&waited, "completionStatus", false)? != 0
        || record_number(&waited, "waitStatus", false)? != 0
    {
        return Err(INVALID);
    }
    record_number(&waited, "wrapperPID", true)?;
    record_number(&readiness, "hostPID", true)?;
    record_number(&readiness, "blackHolePeerGeneration", true)?;
    record_number(&readiness, "authenticatedConnectionCount", true)?;
    if record_number(&observation, "probeEndMonotonicNs", true)? != probe_end
        || record_number(&waited, "probeEndMonotonicNs", true)? != probe_end
    {
        return Err(INVALID);
    }
    let start_observed = record_number(&start, "observedAtMonotonicNs", true)?;
    let completion_observed = record_number(&completion, "observedAtMonotonicNs", true)?;
    if record_number(&observation, "completionObservedAtMonotonicNs", true)? != completion_observed
        || record_number(&readiness, "requestedAtMonotonicNs", true)? != requested
        || record_number(&readiness, "probeStartedAtMonotonicNs", true)? != probe_start
    {
        return Err(INVALID);
    }
    if !(requested < resumed
        && resumed < ready
        && ready <= start_observed
        && start_observed <= probe_start
        && probe_start < probe_end
        && probe_end <= completion_observed
        && completion_observed <= ui_completion_observed
        && ui_completion_observed <= now)
    {
        return Err(NON_OVERLAP);
    }
    if continuity < 30_000_000_000 || continuity > ui_completion_observed {
        return Err(NON_OVERLAP);
    }
    let latest_start = ui_completion_observed
        .checked_sub(continuity)
        .ok_or(NON_OVERLAP)?;
    let earliest_end = resumed
        .checked_add(continuity)
        .filter(|value| *value <= MAXIMUM)
        .ok_or(NON_OVERLAP)?;
    if latest_start < resumed
        || earliest_end > ui_completion_observed
        || latest_start >= earliest_end
    {
        return Err(NON_OVERLAP);
    }
    let proof_duration = probe_end.checked_sub(probe_start).ok_or(NON_OVERLAP)?;
    if proof_duration < 6_000_000_000 || probe_start < latest_start || probe_end > earliest_end {
        return Err(NON_OVERLAP);
    }
    let bounds = format!(
        "schema=opensteamer.raw-ui-host-bounds.v1\nnonce={expected_nonce}\n\
         resumedAtMonotonicNs={resumed}\nuiCompletionObservedAtMonotonicNs={ui_completion_observed}\n\
         continuityDurationNs={continuity}\nlatestPossibleUIStartNs={latest_start}\n\
         earliestPossibleUIEndNs={earliest_end}\nappPID={start_pid}\n",
    );
    let probe = format!(
        "schema=opensteamer.blackhole-proof-interval.v1\nnonce={expected_nonce}\n\
         probeStartMonotonicNs={probe_start}\nprobeEndMonotonicNs={probe_end}\n\
         durationNs={proof_duration}\nstatus=0\nproductionPID={start_pid}\n",
    );
    let verdict = format!(
        "schema=opensteamer.raw-blackhole-overlap-verdict.v1\nstate=passed\n\
         nonce={expected_nonce}\nproductionPID={start_pid}\nproofDurationNs={proof_duration}\n",
    );
    Ok((bounds, probe, verdict))
}

#[derive(Debug)]
enum JsonValue {
    Null,
    Bool,
    Number,
    String(String),
    Array,
    Object(BTreeMap<String, JsonValue>),
}

impl JsonValue {
    fn as_object(&self) -> Option<&BTreeMap<String, JsonValue>> {
        if let Self::Object(value) = self {
            Some(value)
        } else {
            None
        }
    }
}

fn json_object_string<'a>(object: &'a BTreeMap<String, JsonValue>, key: &str) -> Option<&'a str> {
    match object.get(key) {
        Some(JsonValue::String(value)) => Some(value),
        _ => None,
    }
}

struct JsonParser<'a> {
    bytes: &'a [u8],
    cursor: usize,
}

impl<'a> JsonParser<'a> {
    fn new(text: &'a str) -> Self {
        Self {
            bytes: text.as_bytes(),
            cursor: 0,
        }
    }

    fn parse(mut self) -> Result<JsonValue, ()> {
        self.whitespace();
        let value = self.value()?;
        self.whitespace();
        if self.cursor == self.bytes.len() {
            Ok(value)
        } else {
            Err(())
        }
    }

    fn whitespace(&mut self) {
        while self
            .bytes
            .get(self.cursor)
            .is_some_and(|byte| matches!(byte, b' ' | b'\t' | b'\n' | b'\r'))
        {
            self.cursor += 1;
        }
    }

    fn value(&mut self) -> Result<JsonValue, ()> {
        self.whitespace();
        match self.bytes.get(self.cursor).copied() {
            Some(b'n') => {
                self.literal(b"null")?;
                Ok(JsonValue::Null)
            }
            Some(b't') => {
                self.literal(b"true")?;
                Ok(JsonValue::Bool)
            }
            Some(b'f') => {
                self.literal(b"false")?;
                Ok(JsonValue::Bool)
            }
            Some(b'"') => Ok(JsonValue::String(self.string()?)),
            Some(b'[') => self.array(),
            Some(b'{') => self.object(),
            Some(b'-' | b'0'..=b'9') => {
                self.number()?;
                Ok(JsonValue::Number)
            }
            _ => Err(()),
        }
    }

    fn literal(&mut self, literal: &[u8]) -> Result<(), ()> {
        if self.bytes.get(self.cursor..self.cursor + literal.len()) == Some(literal) {
            self.cursor += literal.len();
            Ok(())
        } else {
            Err(())
        }
    }

    fn string(&mut self) -> Result<String, ()> {
        if self.bytes.get(self.cursor) != Some(&b'"') {
            return Err(());
        }
        self.cursor += 1;
        let mut output = String::new();
        let mut plain_start = self.cursor;
        loop {
            let byte = *self.bytes.get(self.cursor).ok_or(())?;
            match byte {
                b'"' => {
                    output.push_str(
                        std::str::from_utf8(&self.bytes[plain_start..self.cursor])
                            .map_err(|_| ())?,
                    );
                    self.cursor += 1;
                    return Ok(output);
                }
                b'\\' => {
                    output.push_str(
                        std::str::from_utf8(&self.bytes[plain_start..self.cursor])
                            .map_err(|_| ())?,
                    );
                    self.cursor += 1;
                    let escape = *self.bytes.get(self.cursor).ok_or(())?;
                    self.cursor += 1;
                    match escape {
                        b'"' => output.push('"'),
                        b'\\' => output.push('\\'),
                        b'/' => output.push('/'),
                        b'b' => output.push('\u{08}'),
                        b'f' => output.push('\u{0c}'),
                        b'n' => output.push('\n'),
                        b'r' => output.push('\r'),
                        b't' => output.push('\t'),
                        b'u' => output.push(self.unicode_escape()?),
                        _ => return Err(()),
                    }
                    plain_start = self.cursor;
                }
                0x00..=0x1f => return Err(()),
                _ => self.cursor += 1,
            }
        }
    }

    fn unicode_escape(&mut self) -> Result<char, ()> {
        let first = self.hex4()?;
        let scalar = if (0xd800..=0xdbff).contains(&first) {
            if self.bytes.get(self.cursor..self.cursor + 2) != Some(b"\\u") {
                return Err(());
            }
            self.cursor += 2;
            let second = self.hex4()?;
            if !(0xdc00..=0xdfff).contains(&second) {
                return Err(());
            }
            0x10000 + (((first - 0xd800) as u32) << 10) + (second - 0xdc00) as u32
        } else if (0xdc00..=0xdfff).contains(&first) {
            return Err(());
        } else {
            first as u32
        };
        char::from_u32(scalar).ok_or(())
    }

    fn hex4(&mut self) -> Result<u16, ()> {
        let bytes = self.bytes.get(self.cursor..self.cursor + 4).ok_or(())?;
        self.cursor += 4;
        bytes.iter().try_fold(0u16, |value, byte| {
            let digit = match byte {
                b'0'..=b'9' => byte - b'0',
                b'a'..=b'f' => byte - b'a' + 10,
                b'A'..=b'F' => byte - b'A' + 10,
                _ => return Err(()),
            };
            Ok(value * 16 + u16::from(digit))
        })
    }

    fn number(&mut self) -> Result<(), ()> {
        if self.bytes.get(self.cursor) == Some(&b'-') {
            self.cursor += 1;
        }
        match self.bytes.get(self.cursor) {
            Some(b'0') => self.cursor += 1,
            Some(b'1'..=b'9') => {
                while self.bytes.get(self.cursor).is_some_and(u8::is_ascii_digit) {
                    self.cursor += 1;
                }
            }
            _ => return Err(()),
        }
        if self.bytes.get(self.cursor) == Some(&b'.') {
            self.cursor += 1;
            let start = self.cursor;
            while self.bytes.get(self.cursor).is_some_and(u8::is_ascii_digit) {
                self.cursor += 1;
            }
            if self.cursor == start {
                return Err(());
            }
        }
        if self
            .bytes
            .get(self.cursor)
            .is_some_and(|byte| matches!(byte, b'e' | b'E'))
        {
            self.cursor += 1;
            if self
                .bytes
                .get(self.cursor)
                .is_some_and(|byte| matches!(byte, b'+' | b'-'))
            {
                self.cursor += 1;
            }
            let start = self.cursor;
            while self.bytes.get(self.cursor).is_some_and(u8::is_ascii_digit) {
                self.cursor += 1;
            }
            if self.cursor == start {
                return Err(());
            }
        }
        Ok(())
    }

    fn array(&mut self) -> Result<JsonValue, ()> {
        self.cursor += 1;
        self.whitespace();
        if self.bytes.get(self.cursor) == Some(&b']') {
            self.cursor += 1;
            return Ok(JsonValue::Array);
        }
        loop {
            self.value()?;
            self.whitespace();
            match self.bytes.get(self.cursor) {
                Some(b',') => {
                    self.cursor += 1;
                    self.whitespace();
                }
                Some(b']') => {
                    self.cursor += 1;
                    return Ok(JsonValue::Array);
                }
                _ => return Err(()),
            }
        }
    }

    fn object(&mut self) -> Result<JsonValue, ()> {
        self.cursor += 1;
        self.whitespace();
        let mut object = BTreeMap::new();
        if self.bytes.get(self.cursor) == Some(&b'}') {
            self.cursor += 1;
            return Ok(JsonValue::Object(object));
        }
        loop {
            let key = self.string()?;
            self.whitespace();
            if self.bytes.get(self.cursor) != Some(&b':') {
                return Err(());
            }
            self.cursor += 1;
            let value = self.value()?;
            if object.insert(key, value).is_some() {
                return Err(());
            }
            self.whitespace();
            match self.bytes.get(self.cursor) {
                Some(b',') => {
                    self.cursor += 1;
                    self.whitespace();
                }
                Some(b'}') => {
                    self.cursor += 1;
                    return Ok(JsonValue::Object(object));
                }
                _ => return Err(()),
            }
        }
    }
}

fn command_self_test(args: &[OsString]) -> Result<(), i32> {
    exact_args(args, 0)?;
    let unique = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_err(|_| 1)?
        .as_nanos();
    let root = env::temp_dir().join(format!(
        "opensteamer-physical-validation-oracle-selftest-{}-{unique}",
        process::id(),
    ));
    fs::create_dir(&root).map_err(|error| {
        eprintln!("self-test could not create isolated directory: {error}");
        1
    })?;
    let result = run_self_test(&root);
    if let Err(error) = fs::remove_dir_all(&root) {
        eprintln!("self-test could not remove its isolated directory: {error}");
        return Err(1);
    }
    result?;
    println!("SELF_TEST_OK physical-validation-oracle");
    Ok(())
}

fn run_self_test(root: &Path) -> Result<(), i32> {
    fn require(condition: bool, message: &str) -> Result<(), i32> {
        if condition {
            Ok(())
        } else {
            eprintln!("self-test failed: {message}");
            Err(1)
        }
    }

    require(
        sha256_hex(b"") == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
        "empty SHA-256 vector",
    )?;
    require(
        sha256_hex(b"abc") == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
        "abc SHA-256 vector",
    )?;
    require(
        payload_id_is_valid("0~abc_DEF-09=="),
        "valid payload identifier",
    )?;
    require(
        !payload_id_is_valid("0~abc=def"),
        "payload padding must be terminal",
    )?;
    require(!payload_id_is_valid("0~"), "payload must not be empty")?;
    let parsed = JsonParser::new(
        r#"{"schema":"opensteamer.physical-blackhole-microphone.v1","status":"passed","runNonce":"raw-123456789012","extra":[true,null,4]}"#,
    ).parse().map_err(|_| 1)?;
    require(parsed.as_object().is_some(), "strict JSON parser")?;

    let tone = root.join("tone.wav");
    write_tone(&tone, 1).map_err(|_| 1)?;
    require(
        fs::metadata(&tone).map_err(|_| 1)?.len() == 192_044,
        "deterministic WAV size",
    )?;
    require(
        fs::read(&tone).map_err(|_| 1)?.starts_with(b"RIFF"),
        "deterministic WAV header",
    )?;

    let appended = root.join("append.bin");
    let partial = root.join("partial.bin");
    let completed = root.join("completed.bin");
    fs::write(&partial, b"hel").map_err(|_| 1)?;
    fs::write(&appended, b"lo\ntrailing").map_err(|_| 1)?;
    split_lines(&appended, &partial, &completed).map_err(|_| 1)?;
    require(
        fs::read(&completed).map_err(|_| 1)? == b"hello\n",
        "completed log split",
    )?;
    require(
        fs::read(&partial).map_err(|_| 1)? == b"trailing",
        "partial log split",
    )?;

    let clean_tree = root.join("clean");
    fs::create_dir(&clean_tree).map_err(|_| 1)?;
    fs::write(clean_tree.join("one"), b"safe-prefix").map_err(|_| 1)?;
    fs::write(clean_tree.join("two"), b"safe-suffix").map_err(|_| 1)?;
    require(
        !scan_tree(&clean_tree, b"secret-uid").map_err(|_| 1)?,
        "clean binary scan",
    )?;
    fs::write(clean_tree.join("two"), b"has-secret-uid-inside").map_err(|_| 1)?;
    require(
        scan_tree(&clean_tree, b"secret-uid").map_err(|_| 1)?,
        "leak binary scan",
    )?;
    let mut boundary_payload = vec![b'x'; 1024 * 1024 + 32];
    let boundary_start = 1024 * 1024 - 4;
    boundary_payload[boundary_start..boundary_start + b"secret-uid".len()]
        .copy_from_slice(b"secret-uid");
    fs::write(clean_tree.join("boundary"), boundary_payload).map_err(|_| 1)?;
    require(
        scan_tree(&clean_tree, b"secret-uid").map_err(|_| 1)?,
        "chunk-boundary leak scan",
    )?;
    fs::remove_file(clean_tree.join("two")).map_err(|_| 1)?;
    fs::remove_file(clean_tree.join("boundary")).map_err(|_| 1)?;
    symlink(
        clean_tree.join("missing-target"),
        clean_tree.join("broken-link"),
    )
    .map_err(|_| 1)?;
    require(
        scan_tree(&clean_tree, b"secret-uid").is_err(),
        "broken retained-artifact symlink fails closed",
    )?;

    let log = root.join("host.log");
    let appended_snapshot = root.join("host.appended");
    fs::write(&log, b"one\n").map_err(|_| 1)?;
    let executable = env::current_exe().map_err(|_| 1)?;
    let first_snapshot = Command::new(&executable)
        .args([
            OsString::from("log-snapshot"),
            log.as_os_str().to_os_string(),
            OsString::from("-"),
            OsString::from("0"),
            OsString::from("e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"),
            appended_snapshot.as_os_str().to_os_string(),
        ])
        .output()
        .map_err(|_| 1)?;
    require(
        first_snapshot.status.success(),
        "initial coherent log snapshot",
    )?;
    require(
        fs::read(&appended_snapshot).map_err(|_| 1)? == b"one\n",
        "initial appended log bytes",
    )?;
    let first_metadata = String::from_utf8(first_snapshot.stdout).map_err(|_| 1)?;
    let first_fields: Vec<&str> = first_metadata.lines().collect();
    require(first_fields.len() == 4, "coherent log metadata shape")?;
    let mut log_writer = OpenOptions::new().append(true).open(&log).map_err(|_| 1)?;
    log_writer.write_all(b"two\n").map_err(|_| 1)?;
    log_writer.sync_all().map_err(|_| 1)?;
    drop(log_writer);
    let second_snapshot = Command::new(&executable)
        .args([
            OsString::from("log-snapshot"),
            log.as_os_str().to_os_string(),
            OsString::from(first_fields[0]),
            OsString::from(first_fields[1]),
            OsString::from(first_fields[2]),
            appended_snapshot.as_os_str().to_os_string(),
        ])
        .output()
        .map_err(|_| 1)?;
    require(
        second_snapshot.status.success(),
        "incremental coherent log snapshot",
    )?;
    require(
        fs::read(&appended_snapshot).map_err(|_| 1)? == b"two\n",
        "incremental appended log bytes",
    )?;

    let completion = root.join("completion.txt");
    atomic_write(&completion, b"schema=opensteamer.blackhole-probe-completion.v1\nnonce=raw-123456789012\nprobeStartMonotonicNs=100\nprobeEndMonotonicNs=200\nstatus=0\nproductionPIDAtStart=42\n").map_err(|_| 1)?;
    require(
        parse_completion(&completion, "raw-123456789012", 100, 42)? == (200, 0),
        "completion parser",
    )?;
    require(
        parse_completion(&completion, "raw-wrong-123456", 100, 42).is_err(),
        "completion nonce binding",
    )?;

    let first = monotonic_ns()?;
    thread::sleep(Duration::from_millis(1));
    require(monotonic_ns()? > first, "monotonic clock advances")?;
    let timing_anchor = Instant::now();
    let timing_deadline = timing_anchor + Duration::from_nanos(2);
    require(
        observation_precedes_deadline(timing_anchor, timing_deadline)
            && !observation_precedes_deadline(timing_deadline, timing_deadline)
            && !observation_precedes_deadline(
                timing_deadline + Duration::from_nanos(1),
                timing_deadline,
            ),
        "absolute deadlines reject observations at or after the boundary",
    )?;
    require(
        classify_process_group_probe(0, None) == Ok(true)
            && classify_process_group_probe(-1, Some(3)) == Ok(false)
            && classify_process_group_probe(-1, Some(1)) == Err(125),
        "only ESRCH proves process-group absence",
    )?;
    let current_group = unsafe { getpgrp() };
    require(
        process_group_state(current_group) == Ok(true)
            && process_group_state(i32::MAX) == Ok(false),
        "process-group state distinguishes existence from ESRCH absence",
    )?;

    let timeout_args = vec![
        OsString::from("1"),
        OsString::from("/bin/sh"),
        OsString::from("-c"),
        OsString::from("exit 0"),
    ];
    command_run_timeout(&timeout_args)?;
    let clean_leader_leak_pid_path = root.join("clean-leader-leak-pid.txt");
    let clean_leader_leak_args = vec![
        OsString::from("2"),
        OsString::from("/bin/sh"),
        OsString::from("-c"),
        OsString::from("/bin/sleep 30 & child=$!; printf '%s\\n' \"$child\" > \"$1\"; exit 0"),
        OsString::from("opensteamer-clean-leader-leak"),
        clean_leader_leak_pid_path.as_os_str().to_os_string(),
    ];
    let clean_leader_leak_result = command_run_timeout(&clean_leader_leak_args);
    let clean_leader_leak_pid = fs::read_to_string(&clean_leader_leak_pid_path)
        .map_err(|_| 1)?
        .trim()
        .parse::<i32>()
        .map_err(|_| 1)?;
    let clean_leader_gone_deadline = Instant::now() + Duration::from_secs(1);
    while process_exists(clean_leader_leak_pid) && Instant::now() < clean_leader_gone_deadline {
        thread::sleep(Duration::from_millis(10));
    }
    if process_exists(clean_leader_leak_pid) {
        // Avoid leaking the deliberate descendant if the supervisor contract regresses.
        unsafe {
            kill(clean_leader_leak_pid, SIGKILL);
        }
        return require(
            false,
            "normal leader exit KILL sweep removes surviving descendant",
        );
    }
    require(
        clean_leader_leak_result == Err(1),
        "normal leader exit with a surviving descendant is not reported as success",
    )?;
    let timed_out_args = vec![
        OsString::from("0.02"),
        OsString::from("/bin/sleep"),
        OsString::from("2"),
    ];
    require(
        command_run_timeout(&timed_out_args) == Err(124),
        "bounded command timeout status",
    )?;
    let isolated_status = Command::new(&executable)
        .arg("isolated-exec")
        .arg(&executable)
        .arg("self-test-session")
        .status()
        .map_err(|_| 1)?;
    require(
        isolated_status.success(),
        "isolated exec preserves PID as process-group and session leader",
    )?;
    let resistant_pid_path = root.join("term-resistant-pid.txt");
    let resistant_args = vec![
        OsString::from("0.25"),
        OsString::from("/bin/sh"),
        OsString::from("-c"),
        OsString::from(
            "exec 2>/dev/null; trap 'exit 0' TERM; \"$1\" self-test-ignore-signals \"$2\" & while :; do /bin/sleep 30; done",
        ),
        OsString::from("opensteamer-timeout-tree"),
        executable.as_os_str().to_os_string(),
        resistant_pid_path.as_os_str().to_os_string(),
    ];
    require(
        command_run_timeout(&resistant_args) == Err(124),
        "TERM-resistant process tree timeout status",
    )?;
    let resistant_pid = fs::read_to_string(&resistant_pid_path)
        .map_err(|_| 1)?
        .trim()
        .parse::<i32>()
        .map_err(|_| 1)?;
    let gone_deadline = Instant::now() + Duration::from_secs(1);
    while process_exists(resistant_pid) && Instant::now() < gone_deadline {
        thread::sleep(Duration::from_millis(10));
    }
    if process_exists(resistant_pid) {
        // Avoid leaking a deliberately resistant self-test process if the assertion fails.
        unsafe {
            kill(resistant_pid, SIGKILL);
        }
        return require(
            false,
            "timeout KILL sweep removes TERM-resistant descendant",
        );
    }

    let diagnostic = root.join("probe-diagnostic.txt");
    let wrapper = root.join("probe-wrapper.txt");
    let probe_args = vec![
        diagnostic.as_os_str().to_os_string(),
        wrapper.as_os_str().to_os_string(),
        OsString::from("secret-uid"),
        OsString::from("128"),
        OsString::from("raw-123456789012"),
        OsString::from("100"),
        OsString::from("42"),
        OsString::from("-"),
        OsString::from("normal"),
        OsString::from("100"),
        OsString::from("--"),
        OsString::from("/bin/sh"),
        OsString::from("-c"),
        OsString::from("printf harmless"),
    ];
    command_probe_supervise(&probe_args)?;
    require(!diagnostic.exists(), "successful probe has no diagnostic")?;
    require(
        parse_completion(&wrapper, "raw-123456789012", 100, 42)? == (200, 0),
        "probe completion publication",
    )?;

    let nonce = "raw-123456789012";
    let request = root.join("request.txt");
    let readiness = root.join("readiness.txt");
    let ui = root.join("ui.txt");
    let start = root.join("start.txt");
    let process_completion = root.join("process-completion.txt");
    let observation = root.join("observation.txt");
    let waited = root.join("wait.txt");
    let ui_completion = root.join("ui-completion.txt");
    let ui_causal_state = root.join("ui-causal-state.txt");
    let early_ui_causal_state = root.join("early-ui-causal-state.txt");
    let late_ui_completion = root.join("late-ui-completion.txt");
    let result = root.join("result.json");
    atomic_write(&request, format!("schema=opensteamer.raw-session-readiness.v2\nnonce={nonce}\nrequestedAtMonotonicNs=1000000000\ncursorOffset=0\ncursorDigest=abc\n").as_bytes()).map_err(|_| 1)?;
    // Production-shaped post-call timing: the Mac resumed bound predates both the 180-second
    // acoustic acknowledgement and 90-second end-call acknowledgement. Readiness then arrives
    // after bounded verifier work, and the 330-second iPhone duration still yields a conservative
    // six-second same-clock intersection.
    atomic_write(&readiness, format!("schema=opensteamer.raw-session-readiness.v3\nnonce={nonce}\nrequestedAtMonotonicNs=1000000000\nresumedAtMonotonicNs=2000000000\nreadyAtMonotonicNs=283000000000\nprobeStartedAtMonotonicNs=293000000000\nproductionPID=42\nhostPID=99\nblackHolePeerGeneration=1\nauthenticatedConnectionCount=1\ncursorOffset=0\ncursorDigest=abc\n").as_bytes()).map_err(|_| 1)?;
    atomic_write(&ui, format!("schema=opensteamer.raw-ui-runtime.v1\nnonce={nonce}\ncontinuityDurationNs=330000000000\nappPIDAtStart=42\nappPIDAtEnd=42\n").as_bytes()).map_err(|_| 1)?;
    atomic_write(&start, format!("schema=opensteamer.production-app-probe-boundary.v1\nboundary=start\nnonce={nonce}\nbundleIdentifier=com.elamin.opensteamer\npid=42\nobservedAtMonotonicNs=292000000000\n").as_bytes()).map_err(|_| 1)?;
    atomic_write(&process_completion, format!("schema=opensteamer.production-app-probe-boundary.v1\nboundary=completion\nnonce={nonce}\nbundleIdentifier=com.elamin.opensteamer\npid=42\nobservedAtMonotonicNs=300000000000\n").as_bytes()).map_err(|_| 1)?;
    atomic_write(&observation, format!("schema=opensteamer.blackhole-probe-completion-observation.v1\nnonce={nonce}\nprobeEndMonotonicNs=299000000000\ncompletionObservedAtMonotonicNs=300000000000\nstatus=0\nproductionPIDAtCompletion=42\n").as_bytes()).map_err(|_| 1)?;
    atomic_write(&waited, format!("schema=opensteamer.blackhole-probe-wait.v1\nnonce={nonce}\nwrapperPID=77\nprobeEndMonotonicNs=299000000000\ncompletionStatus=0\nwaitStatus=0\n").as_bytes()).map_err(|_| 1)?;
    atomic_write(&wrapper, format!("schema=opensteamer.blackhole-probe-completion.v1\nnonce={nonce}\nprobeStartMonotonicNs=293000000000\nprobeEndMonotonicNs=299000000000\nstatus=0\nproductionPIDAtStart=42\n").as_bytes()).map_err(|_| 1)?;
    atomic_write(&ui_completion, format!("schema=opensteamer.raw-ui-completion-observation.v1\nnonce={nonce}\nobservedAtMonotonicNs=621000000000\n").as_bytes()).map_err(|_| 1)?;
    atomic_write(&ui_causal_state, format!("schema=opensteamer.call-ui-hosted-state-observation.v2\nnonce={nonce}\nstate=hosted-call-active\nsequence=2\nacousticToken=call-acoustic-123456789\nresumedAtMonotonicNs=2000000000\nacknowledgementAcceptedAtMonotonicNs=2500000000\nobservedAtMonotonicNs=3000000000\n").as_bytes()).map_err(|_| 1)?;
    atomic_write(&early_ui_causal_state, format!("schema=opensteamer.call-ui-hosted-state-observation.v2\nnonce={nonce}\nstate=hosted-call-active\nsequence=2\nacousticToken=call-acoustic-123456789\nresumedAtMonotonicNs=2000000000\nacknowledgementAcceptedAtMonotonicNs=2000000000\nobservedAtMonotonicNs=3000000000\n").as_bytes()).map_err(|_| 1)?;
    atomic_write(&late_ui_completion, format!("schema=opensteamer.raw-ui-completion-observation.v1\nnonce={nonce}\nobservedAtMonotonicNs=631000000000\n").as_bytes()).map_err(|_| 1)?;
    atomic_write(&result, format!(r#"{{"schema":"opensteamer.physical-blackhole-microphone.v1","status":"passed","runNonce":"{nonce}"}}"#).as_bytes()).map_err(|_| 1)?;
    env::set_var(
        "OPENSTEAMER_EXPECTED_APP_BUNDLE_IDENTIFIER",
        "com.elamin.opensteamer",
    );
    let bounds_output = root.join("bounds.txt");
    let probe_output = root.join("interval.txt");
    let verdict_output = root.join("verdict.txt");
    let overlap_values = [
        request.to_str().ok_or(1)?,
        readiness.to_str().ok_or(1)?,
        ui.to_str().ok_or(1)?,
        start.to_str().ok_or(1)?,
        process_completion.to_str().ok_or(1)?,
        observation.to_str().ok_or(1)?,
        waited.to_str().ok_or(1)?,
        wrapper.to_str().ok_or(1)?,
        result.to_str().ok_or(1)?,
        nonce,
        "1000000000",
        "2000000000",
        ui_completion.to_str().ok_or(1)?,
        ui_causal_state.to_str().ok_or(1)?,
        bounds_output.to_str().ok_or(1)?,
        probe_output.to_str().ok_or(1)?,
        verdict_output.to_str().ok_or(1)?,
        "622000000000",
    ];
    let (bounds, interval, verdict) = validate_overlap(&overlap_values)?;
    require(
        bounds.contains("latestPossibleUIStartNs=291000000000")
            && bounds.contains("earliestPossibleUIEndNs=332000000000"),
        "delayed-call conservative UI bounds",
    )?;
    require(
        interval.contains("durationNs=6000000000"),
        "causal probe interval",
    )?;
    require(verdict.contains("state=passed"), "causal overlap verdict")?;
    let mut non_overlap_values = overlap_values;
    non_overlap_values[12] = late_ui_completion.to_str().ok_or(1)?;
    non_overlap_values[17] = "632000000000";
    require(
        validate_overlap(&non_overlap_values) == Err(NON_OVERLAP),
        "causal non-overlap status",
    )?;
    let mut invalid_causal_values = overlap_values;
    invalid_causal_values[13] = early_ui_causal_state.to_str().ok_or(1)?;
    require(
        validate_overlap(&invalid_causal_values) == Err(NON_OVERLAP),
        "UI causal state must be observed strictly after the Mac lower bound",
    )?;

    let leak_diagnostic = root.join("leak-diagnostic.txt");
    let leak_completion = root.join("leak-completion.txt");
    let leak_args = vec![
        leak_diagnostic.as_os_str().to_os_string(),
        leak_completion.as_os_str().to_os_string(),
        OsString::from("secret-uid"),
        OsString::from("128"),
        OsString::from(nonce),
        OsString::from("100"),
        OsString::from("42"),
        OsString::from("-"),
        OsString::from("normal"),
        OsString::from("100"),
        OsString::from("--"),
        OsString::from("/bin/sh"),
        OsString::from("-c"),
        OsString::from("printf secret-uid"),
    ];
    require(
        command_probe_supervise(&leak_args) == Err(86),
        "runtime UID leak status",
    )?;
    require(
        fs::read(&leak_diagnostic).map_err(|_| 1)? == b"diagnostic=runtime-uid-output-rejected\n",
        "runtime UID is redacted from diagnostics",
    )?;
    Ok(())
}
