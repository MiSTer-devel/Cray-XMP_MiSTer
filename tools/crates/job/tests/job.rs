//! The dataset format against bytes from `tools/py/expdisk.py`, and a
//! program that makes its requests the way a library does.

use cray_xmp_job::{
    block, cray_float, from_text, map_entries, profile, unblock, End, Item, Job, Options, Program,
};
use std::cell::RefCell;
use std::io::Write;
use std::rc::Rc;

/// `expdisk.from_text` of these five lines, the fourth of them `/EOF`.
const BLOCKED: [u64; 14] = [
    0x0000000000000001,
    0x48454c4c4f000000,
    0x8600000000000000,
    0x8000000000000004,
    0x41204c494e45204f,
    0x46204d4f52452054,
    0x48414e2045494748,
    0x5400000000000000,
    0x8e00000000000000,
    0xe000000000000001,
    0x4c41535400000000,
    0x8800000000000000,
    0xe000000000000000,
    0xf000000000000000,
];

fn bytes(words: &[u64]) -> Vec<u8> {
    words.iter().flat_map(|w| w.to_be_bytes()).collect()
}

#[test]
fn a_dataset_is_blocked_as_the_expander_disk_tool_blocks_it() {
    let mut items = from_text(b"HELLO\n\nA LINE OF MORE THAN EIGHT\n");
    items.extend(from_text(b"LAST\n"));
    assert_eq!(items.len(), 6);
    assert_eq!(items[3], Item::FileMark);
    assert_eq!(block(&items), bytes(&BLOCKED));
    assert_eq!(unblock(&bytes(&BLOCKED)).unwrap(), items);
}

#[test]
fn a_record_crosses_blocks() {
    let long = Item::Record((0..1500).collect(), 0);
    let items = vec![long.clone(), Item::FileMark];
    let data = block(&items);
    // three blocks: each begins with a control word that counts to the next one
    assert_eq!(data.len(), (1500 + 3 + 3) * 8);
    assert_eq!(&data[..8], &511u64.to_be_bytes());
    assert_eq!(unblock(&data).unwrap(), items);
}

#[test]
fn numbers_in_the_machines_format() {
    assert_eq!(cray_float(0.0), 0);
    assert_eq!(cray_float(1.0), 0o0400014000000000000000);
    assert_eq!(cray_float(0.5), 0o0400004000000000000000);
    assert_eq!(cray_float(-2.5), 0o1400025000000000000000);
}

/// An absolute binary of an image assembled from word 0: the tables the
/// loader writes around the words from 200 (octal) on.
fn absolute(image: &[u8], start_parcel: u64) -> Vec<u8> {
    let words: Vec<u64> = image[0o200 * 8..]
        .as_chunks::<8>()
        .0
        .iter()
        .map(|c| u64::from_be_bytes(*c))
        .collect();
    let mut table = vec![0u64; 1 + 20 + 2 + 3 + 11];
    let length = table.len() as u64;
    table[0] = 0o17 << 60 | length << 36 | 3 << 8 | 2;
    table[1] = 20;
    table[24] = 0o401; // the primary entry point, a parcel address
    table[25] = start_parcel;
    table.push(0o16 << 60 | (words.len() as u64 + 1) << 36 | 0o200);
    table.extend_from_slice(&words);
    block(&[Item::Record(table, 0)])
}

#[derive(Clone, Default)]
struct Output(Rc<RefCell<Vec<u8>>>);

impl Write for Output {
    fn write(&mut self, data: &[u8]) -> std::io::Result<usize> {
        self.0.borrow_mut().extend_from_slice(data);
        Ok(data.len())
    }
    fn flush(&mut self) -> std::io::Result<()> {
        Ok(())
    }
}

#[test]
fn a_program_reads_and_writes_records_and_ends() {
    let assembly = cray_xmp_asm::assemble_source(include_str!("hello.cal"));
    assert!(!assembly.has_errors(), "{}", assembly.listing_text());
    let start = assembly.symbol("START").unwrap().value as u64;
    let program = Program::from_dataset(&absolute(&assembly.image(), start)).unwrap();
    assert_eq!(program.origin, 0o200);
    assert_eq!(program.start as u64, start);

    let directory = std::env::temp_dir().join(format!("cray-xmp-job-test-{}", std::process::id()));
    std::fs::create_dir_all(&directory).unwrap();
    let file = directory.join("data");
    std::fs::write(&file, b"=SIXTEEN LETTERS\nand a second line\n").unwrap();

    let output = Output::default();
    let options = Options {
        batch: true,
        profile: true,
        log: false,
        ..Options::default()
    };
    let mut job = Job::new(&program, options, Box::new(output.clone())).unwrap();
    job.bind("DATA", file.to_str().unwrap(), true).unwrap();
    assert!(job.has_dataset("DATA"));
    assert!(!job.has_dataset("OTHER"));
    assert_eq!(job.run(10_000), End::Done);
    // the first character of a line a batch job prints moves the paper
    assert_eq!(
        String::from_utf8_lossy(&output.0.borrow()),
        "HELLO FROM A PROGRAM   \nSIXTEEN LETTERS\n"
    );
    // the dataset was only read: its file is not written
    assert!(job.save().unwrap().is_empty());
    std::fs::remove_dir_all(&directory).unwrap();

    let counts: u64 = job.counts.iter().sum();
    // the monitor's exit that starts the program, and a jump and an exit
    // behind each of the six requests that come back
    assert_eq!(counts, job.machine.instructions() - 1 - 2 * 6);
    let by_routine = profile(
        &job.counts,
        &map_entries("   Entry     Section   Address\n   START     TEXT          200a\n"),
    );
    assert_eq!(by_routine, vec![(counts, "START".to_string())]);
}

#[test]
fn a_request_that_is_not_answered_stops_the_run() {
    // S0 = 77 (F$TASK), EX
    let assembly = cray_xmp_asm::assemble_source(
        "         ORG       200\nSTART    S0        77\n         EX\n",
    );
    let start = assembly.symbol("START").unwrap().value as u64;
    let program = Program::from_dataset(&absolute(&assembly.image(), start)).unwrap();
    let mut job = Job::new(&program, Options::default(), Box::new(std::io::sink())).unwrap();
    assert_eq!(
        job.run(100),
        End::Stopped("system request 77 (octal) is not answered here".into())
    );
}

#[test]
fn an_address_outside_the_field_is_a_fault() {
    // load from the last word of memory, far above the field
    let assembly = cray_xmp_asm::assemble_source(
        "         ORG       200\nSTART    S1        17777700,\n         EX\n",
    );
    let start = assembly.symbol("START").unwrap().value as u64;
    let program = Program::from_dataset(&absolute(&assembly.image(), start)).unwrap();
    let mut job = Job::new(&program, Options::default(), Box::new(std::io::sink())).unwrap();
    assert_eq!(
        job.run(100),
        End::Fault("operand range error at P = 200c".into())
    );
}
