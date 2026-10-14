//! A program built for COS, run on the CPU reference model with no COS under
//! it: this crate loads an absolute binary as COS's loader would, and answers
//! the system requests the program makes itself.
//!
//! It is for trying and measuring programs written for the core (C and
//! FORTRAN from the cross-compilers of `tools/ack`, or assembly) without a
//! dead start, and for running one as a step of a build.  What it knows of
//! COS is what the libraries of those compilers ask of it:
//!
//! * the job communication block: the high limit of the program, the field
//!   length, where the system's tables begin, the control statement, the
//!   clock period;
//! * `F$ADV` and `F$ABT` (the end of the program), `F$MSG` (a line for the
//!   log), `F$DAT`, `F$TIM` and `F$JTI` (the date, the time of day and the
//!   CPU time used), `F$RCL` (recall, which has nothing to wait for here);
//! * local datasets: `F$DNT`, `F$OPN`, `F$CLS`, `F$RLS`, and `F$BIO`, the
//!   buffered I/O request that reads and writes records;
//! * `$IN` and `$OUT` of an interactive session, which take the circular
//!   I/O requests `F$RDC` and `F$WDC` and refuse `F$BIO`, as COS has it;
//! * `F$MEMORY`, which adds words to the end of the user area.
//!
//! Any other request stops the run with a message that names it.
//!
//! A dataset is a sequence of records and file marks.  On the host it is a
//! file in COS's blocked format, the same as `tools/py/expdisk.py` puts on
//! the expander disk, or a text file with a record a line.
//!
//! The time a program sees is counted in instructions: every one takes the
//! same number of clock periods (four unless said otherwise).  Counts of
//! instructions are exact; times are only as good as that average.

use cray_xmp_model::{flag, mode, Machine, StepResult};
use std::collections::HashMap;
use std::io::{BufRead, Write};

/// The user area begins at this word of the model's memory; below it are
/// the exchange package and the two instructions of the stand-in monitor.
const BASE_UNITS: u32 = 8;
const BASE: u32 = BASE_UNITS * 32;
const MONITOR: u32 = 32;
/// Words at the top of the field for the system's tables: the logical file
/// table, and the dataset parameter tables and buffers of `$IN` and `$OUT`.
const SYSTEM_AREA: u32 = 4096;

const CW_EOR: u64 = 0o10;
const CW_EOF: u64 = 0o16;
const CW_EOD: u64 = 0o17;

/// A record (its words and the bits not used in the last one) or a file mark.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Item {
    Record(Vec<u64>, u8),
    FileMark,
}

/// The records of a dataset in COS's blocked format: blocks of 512 words,
/// each begun by a block control word, with a record control word at the
/// end of a record, of a file and of the data.
pub fn unblock(data: &[u8]) -> Result<Vec<Item>, String> {
    let words: Vec<u64> = data
        .as_chunks::<8>()
        .0
        .iter()
        .map(|c| u64::from_be_bytes(*c))
        .collect();
    let mut items = Vec::new();
    let mut record = Vec::new();
    let mut at = 0;
    while at < words.len() {
        let control = words[at];
        let ahead = (control & 0o777) as usize;
        match control >> 60 {
            0 => {}
            CW_EOR => items.push(Item::Record(
                std::mem::take(&mut record),
                (control >> 54 & 0o77) as u8,
            )),
            CW_EOF => items.push(Item::FileMark),
            CW_EOD => return Ok(items),
            _ => return Err(format!("not a blocked dataset (word {})", at)),
        }
        record.extend_from_slice(&words[at + 1..(at + 1 + ahead).min(words.len())]);
        at += 1 + ahead;
    }
    Err("the dataset has no end".into())
}

/// A blocked dataset of these records, byte for byte as `expdisk.py` makes
/// one.  A dataset whose last record has no file mark behind it gets one.
pub fn block(items: &[Item]) -> Vec<u8> {
    // a control word: kind, unused bits, blocks back to the start of its
    // file and of its record, words ahead to the next one, its own block
    enum Word {
        Control(u64, u64, u64, u64, u64, u64),
        Data(u64),
    }
    fn control(
        words: &mut Vec<Word>,
        last: &mut Option<usize>,
        kind: u64,
        unused: u64,
        file: u64,
        record: u64,
    ) {
        if words.len().is_multiple_of(512) && kind != 0 {
            control(words, last, 0, 0, 0, 0);
        }
        let here = (words.len() / 512) as u64;
        if let Some(l) = *last {
            let n = (words.len() - l - 1) as u64;
            if let Word::Control(_, _, _, _, ahead, _) = &mut words[l] {
                *ahead = n;
            }
        }
        *last = Some(words.len());
        words.push(Word::Control(
            kind,
            unused,
            here.wrapping_sub(file),
            here.wrapping_sub(record),
            0,
            here,
        ));
    }
    let mut words: Vec<Word> = Vec::new();
    let mut last = None;
    control(&mut words, &mut last, 0, 0, 0, 0);
    let mut file_block = 0u64;
    let mut closed = false; // the last thing written was a file mark
    for item in items {
        match item {
            Item::Record(data, unused) => {
                let record_block = (words.len() / 512) as u64;
                for w in data {
                    if words.len().is_multiple_of(512) {
                        control(&mut words, &mut last, 0, 0, 0, 0);
                    }
                    words.push(Word::Data(*w));
                }
                control(
                    &mut words,
                    &mut last,
                    CW_EOR,
                    *unused as u64,
                    file_block,
                    record_block,
                );
                closed = false;
            }
            Item::FileMark => {
                let here = (words.len() / 512) as u64;
                control(&mut words, &mut last, CW_EOF, 0, file_block, here);
                file_block = (words.len() / 512) as u64;
                closed = true;
            }
        }
    }
    if !closed {
        let here = (words.len() / 512) as u64;
        control(&mut words, &mut last, CW_EOF, 0, file_block, here);
    }
    control(&mut words, &mut last, CW_EOD, 0, 0, 0);
    let n = words.len();
    if let Word::Control(_, _, file, record, _, _) = &mut words[n - 1] {
        *file = 0;
        *record = 0;
    }
    let mut out = Vec::with_capacity(words.len() * 8);
    for w in &words {
        let v = match w {
            Word::Data(v) => *v,
            Word::Control(0, _, _, _, ahead, here) => here << 9 | ahead,
            Word::Control(kind, unused, file, record, ahead, _) => {
                kind << 60 | unused << 54 | (file & 0xF_FFFF) << 24 | (record & 0x7FFF) << 9 | ahead
            }
        };
        out.extend_from_slice(&v.to_be_bytes());
    }
    out
}

/// A line of text as a record: eight characters a word, the last word
/// filled out with zeros.
pub fn text_record(line: &[u8]) -> Item {
    let words = line
        .chunks(8)
        .map(|chunk| {
            let mut b = [0u8; 8];
            b[..chunk.len()].copy_from_slice(chunk);
            u64::from_be_bytes(b)
        })
        .collect();
    Item::Record(words, ((8 - line.len() % 8) % 8 * 8) as u8)
}

/// A text as a dataset: a record a line, without the blanks at its end.
pub fn from_text(text: &[u8]) -> Vec<Item> {
    let mut items: Vec<Item> = text
        .split(|&c| c == b'\n')
        .map(|mut line| {
            while let [rest @ .., b' ' | b'\r'] = line {
                line = rest;
            }
            text_record(line)
        })
        .collect();
    if text.ends_with(b"\n") || text.is_empty() {
        items.pop();
    }
    items.push(Item::FileMark);
    items
}

/// The characters of a record.  COS writes a run of blanks as an escape
/// (033) and a count that has 036 added to it.
pub fn record_text(words: &[u64], unused: u8) -> Vec<u8> {
    let mut bytes: Vec<u8> = words.iter().flat_map(|w| w.to_be_bytes()).collect();
    bytes.truncate(bytes.len().saturating_sub(unused as usize / 8));
    let mut out = Vec::new();
    let mut i = 0;
    while i < bytes.len() {
        if bytes[i] == 0x1b && i + 1 < bytes.len() && bytes[i + 1] >= 0o36 {
            out.resize(out.len() + (bytes[i + 1] - 0o36) as usize, b' ');
            i += 2;
        } else {
            out.push(bytes[i]);
            i += 1;
        }
    }
    out
}

/// A number in the machine's floating point format, cut off to 48 bits.
pub fn cray_float(x: f64) -> u64 {
    if x == 0.0 || !x.is_finite() {
        return 0;
    }
    let (sign, mut m) = if x < 0.0 { (1u64, -x) } else { (0, x) };
    let mut e = 0i64;
    while m >= 1.0 {
        m /= 2.0;
        e += 1;
    }
    while m < 0.5 {
        m *= 2.0;
        e -= 1;
    }
    let fraction = (m * (1u64 << 48) as f64) as u64;
    sign << 63 | ((0o40000 + e) as u64 & 0x7fff) << 48 | (fraction & 0xffff_ffff_ffff)
}

/// An absolute binary as the loader writes it: a program description table
/// and a text table with the program from its origin on.
pub struct Program {
    /// The first word of the program, 200 (octal) for a COS program.
    pub origin: u32,
    pub words: Vec<u64>,
    /// Where it starts, as a parcel address.
    pub start: u32,
    /// The end of its memory, the high limit of the binary: beyond the
    /// words it was written with when it has blank common, which the
    /// binary leaves out.
    pub limit: u32,
}

impl Program {
    pub fn from_dataset(data: &[u8]) -> Result<Program, String> {
        let mut words: Vec<u64> = Vec::new();
        for item in unblock(data)? {
            if let Item::Record(w, _) = item {
                words.extend_from_slice(&w);
            }
        }
        if words.first().map(|w| w >> 60) != Some(0o17) {
            return Err("not an absolute binary: no program description table".into());
        }
        let length = (words[0] >> 36 & 0xff_ffff) as usize;
        // header word, header entry (its length in its first word), one
        // block entry of two words, then the entry point: name, flags, address
        let header = *words
            .get(1)
            .ok_or("the program description table is cut short")? as usize;
        let entry = 1 + header + 2;
        if (words[0] >> 8 & 0x3fff) < 3 || entry + 2 >= length || length >= words.len() {
            return Err("the binary has no start address".into());
        }
        let start = words[entry + 2] as u32;
        let start = if words[entry + 1] & 1 != 0 {
            start
        } else {
            start * 4
        };
        let text = words[length];
        if text >> 60 != 0o16 {
            return Err("not an absolute binary: no text table".into());
        }
        let count = (text >> 36 & 0xff_ffff) as usize - 1;
        let image = words
            .get(length + 1..length + 1 + count)
            .ok_or("the text table is cut short")?;
        let origin = (text & 0xff_ffff) as u32;
        // the high limit of the binary, word 14 (octal) of the header entry
        let limit = words.get(1 + 0o14).map_or(0, |w| (w & 0xff_ffff) as u32);
        Ok(Program {
            origin,
            words: image.to_vec(),
            start,
            limit: limit.max(origin + count as u32),
        })
    }
}

#[derive(Default)]
struct Dataset {
    items: Vec<Item>,
    position: usize,
    offset: usize,
    partial: Vec<u64>,
    written: bool,
    /// Written since it was opened, and not ended with an end of data.
    unended: bool,
    /// The host file it came from and goes back to, and whether that is text.
    host: Option<(String, bool)>,
}

/// Where `$IN` gets its lines when the dataset has run out.
pub type Input = Box<dyn BufRead>;

/// What the run is given besides the program.
pub struct Options {
    /// The control statement the program finds in its job communication
    /// block, such as `PROG.`
    pub statement: String,
    /// Field length in words; 0 for what COS would leave such a program.
    pub words: u32,
    /// Clock periods an instruction takes, for the clocks.
    pub clock_periods: u32,
    /// `$IN` and `$OUT` are those of a batch job, not of a session.
    pub batch: bool,
    /// Show the lines of `$IN` on standard output as they are read.
    pub echo: bool,
    /// Print every system request to standard error.
    pub trace: bool,
    /// Print the lines the program sends to the log to standard error.
    pub log: bool,
    /// Count the instructions of every word, for a profile.
    pub profile: bool,
    /// Instruction counts at which the station sends an attention
    /// (`/ATTENTION`), in order.
    pub attentions: Vec<u64>,
}

impl Default for Options {
    fn default() -> Options {
        Options {
            statement: "PROG.".into(),
            words: 0,
            clock_periods: 4,
            batch: false,
            echo: false,
            trace: false,
            log: true,
            profile: false,
            attentions: Vec::new(),
        }
    }
}

/// How a run ended.
#[derive(Debug, PartialEq, Eq)]
pub enum End {
    /// The program advanced to the next job step: it is done.
    Done,
    /// The program asked for the job to be aborted.
    Aborted,
    /// The step limit was reached.
    Limit,
    /// The program was interrupted: an error exit, a floating point error,
    /// an address outside its field.  The text says which and where.
    Fault(String),
    /// A request this crate does not answer, or one the model cannot follow.
    Stopped(String),
}

pub struct Job {
    pub machine: Machine,
    options: Options,
    words: u32,
    datasets: HashMap<String, Dataset>,
    tables: HashMap<u32, String>,
    next_table: u32,
    input: Option<Input>,
    output: Box<dyn Write>,
    /// Instructions executed at each word of the program, with `profile`.
    pub counts: Vec<u64>,
    /// Reprieve set with F$RPV: the routine (a parcel address), the save
    /// area for the exchange package, the classes.
    reprieve: Option<(u32, u32, u64)>,
    /// An attention was sent and the program was interrupted for it.
    attention_pending: bool,
}

impl Job {
    /// The program loaded, its job communication block filled in, ready to run.
    pub fn new(program: &Program, options: Options, output: Box<dyn Write>) -> Result<Job, String> {
        let high_limit = program
            .limit
            .max(program.origin + program.words.len() as u32);
        // COS leaves a small program the field of the control statement
        // processor before it, and a large one little more than itself
        let mut words = if options.words != 0 {
            options.words
        } else {
            (high_limit + 4096).max(55_000)
        };
        words = words.max(high_limit + SYSTEM_AREA + 64).div_ceil(32) * 32;
        let mut machine = Machine::new();
        machine.set_system();
        machine.set_timing(options.clock_periods.max(1));
        if BASE as u64 + words as u64 > machine.memory_words() as u64 - 16 {
            return Err(format!("{} words do not fit in memory", words));
        }
        // the stand-in monitor: a normal exit, and a jump back to it
        let monitor = 0o004000u64 << 48 | 0o006000u64 << 32 | ((MONITOR * 4) as u64) << 16;
        machine.load_words(MONITOR, &[monitor])?;
        machine.load_words(BASE + program.origin, &program.words)?;
        let limit = (BASE_UNITS + words / 32) as u64;
        let mut package = [0u64; 16];
        package[0] = (program.start as u64) << 24;
        package[1] = (BASE_UNITS as u64) << 29;
        package[2] = limit << 29 | ((mode::FLOATING_POINT | mode::OPERAND_RANGE) as u64) << 24;
        package[4] = (BASE_UNITS as u64) << 29;
        package[5] = limit << 29;
        machine.load_words(0, &package)?;
        machine.start_at(MONITOR * 4, 0, machine.memory_words() / 32, mode::MONITOR);
        let counts = if options.profile {
            vec![0; words as usize]
        } else {
            Vec::new()
        };
        let mut job = Job {
            machine,
            options,
            words,
            datasets: HashMap::new(),
            tables: HashMap::new(),
            next_table: 0,
            input: None,
            output,
            counts,
            reprieve: None,
            attention_pending: false,
        };
        job.lay_out(high_limit);
        let statement = job.options.statement.clone();
        for (n, chunk) in statement.as_bytes().chunks(8).enumerate() {
            let mut b = [0u8; 8];
            b[..chunk.len()].copy_from_slice(chunk);
            job.store(5 + n as u32, u64::from_be_bytes(b));
        }
        // JCIA, the job is interactive; JCCYCL, the clock period in picoseconds
        if !job.options.batch {
            job.store(0o104, 1 << 57);
        }
        job.store(0o105, 9500u64 << 43);
        job.datasets.insert(
            "$IN".into(),
            Dataset {
                items: vec![],
                ..Default::default()
            },
        );
        Ok(job)
    }

    /// A dataset the program finds when it starts, bound to a host file
    /// that is written back if the program writes the dataset.
    pub fn bind(&mut self, name: &str, file: &str, text: bool) -> Result<(), String> {
        let mut dataset = Dataset::default();
        match std::fs::read(file) {
            Ok(data) => {
                dataset.items = if text {
                    from_text(&data)
                } else {
                    unblock(&data).map_err(|e| format!("{}: {}", file, e))?
                };
            }
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => {}
            Err(e) => return Err(format!("{}: {}", file, e)),
        }
        dataset.host = Some((file.into(), text));
        self.datasets.insert(name.into(), dataset);
        Ok(())
    }

    /// The lines of `$IN`: a text whole, or a reader that gives a line when
    /// the program asks for one (a terminal).
    pub fn input_text(&mut self, text: &[u8]) {
        self.datasets.get_mut("$IN").unwrap().items = from_text(text);
    }
    pub fn input_reader(&mut self, reader: Input) {
        self.input = Some(reader);
    }

    /// True if the dataset exists (was bound, or made by the program).
    pub fn has_dataset(&self, name: &str) -> bool {
        self.datasets
            .get(name)
            .is_some_and(|d| d.host.is_some() || !d.items.is_empty() || d.written)
    }

    fn load(&self, address: u32) -> u64 {
        if address < self.words {
            self.machine.mem(BASE + address).unwrap_or(0)
        } else {
            0
        }
    }
    fn store(&mut self, address: u32, value: u64) {
        if address < self.words {
            self.machine.store(BASE + address, Some(value));
        }
    }
    fn package(&self, word: u32) -> u64 {
        self.machine.mem(word).unwrap_or(0)
    }

    /// The words of the job communication block that say where things are:
    /// JCHLM and JCFL, JCDSP, JCLFT.
    fn lay_out(&mut self, high_limit: u32) {
        let files = self.words - SYSTEM_AREA;
        let tables = self.words - SYSTEM_AREA * 3 / 4;
        self.store(0o101, (high_limit as u64) << 24 | self.words as u64);
        self.store(0o102, (tables as u64) << 24 | tables as u64);
        self.store(
            0o103,
            (self.machine.memory_words() as u64 - BASE as u64 - 16) << 24 | files as u64,
        );
        self.next_table = tables;
    }

    fn dataset(&mut self, name: &str) -> &mut Dataset {
        self.datasets.entry(name.to_string()).or_default()
    }

    fn name_at(&self, address: u32) -> String {
        self.load(address)
            .to_be_bytes()
            .iter()
            .take_while(|&&c| c != 0 && c != b' ')
            .map(|&c| c as char)
            .collect()
    }

    /// More of `$IN` from the reader, a line at a time.
    fn more_input(&mut self) {
        if let Some(reader) = self.input.as_mut() {
            let _ = self.output.flush();
            let mut line = Vec::new();
            if reader.read_until(b'\n', &mut line).unwrap_or(0) > 0 {
                while let Some(b'\n' | b'\r') = line.last() {
                    line.pop();
                }
                self.dataset("$IN").items.push(text_record(&line));
            }
        }
    }

    fn print(&mut self, line: &[u8]) {
        let _ = self.output.write_all(line);
        let _ = self.output.write_all(b"\n");
    }

    /// `F$BIO`: read or write a record of a dataset, or part of one.  The
    /// request is in word 7 of the dataset parameter table: the function,
    /// a count of words and the address of the data.  The answer goes there
    /// too, and what ended the read into word 5.
    fn buffered(&mut self, table: u32) {
        let name = self
            .tables
            .get(&table)
            .cloned()
            .unwrap_or_else(|| self.name_at(table));
        let request = self.load(table + 7);
        let function = request >> 54 & 0xff;
        let count = (request >> 24 & 0xff_ffff) as usize;
        let area = (request & 0xff_ffff) as u32;
        let unused_given = (request >> 48 & 0o77) as u8;
        if self.load(table + 1) >> 28 & 1 != 0 {
            // an interactive dataset takes circular I/O only
            self.store(table + 7, request & !(1 << 63) | 1 << 62);
            return;
        }
        let mut detected = 0u64;
        let mut end_of_information = false;
        let mut done = 0usize;
        let mut unused = 0u8;
        let mut line = None;
        let mut data: Vec<u64> = Vec::new();
        if function == 0o40 || function == 0o50 {
            data = (0..count).map(|n| self.load(area + n as u32)).collect();
        }
        if name == "$IN" && self.dataset("$IN").position >= self.dataset("$IN").items.len() {
            self.more_input();
        }
        let dataset = self.dataset(&name);
        match function {
            // read: part of a record, or to its end
            0o00 | 0o10 => match dataset.items.get(dataset.position) {
                // the end of the data; one never written has no end of
                // data to meet, and COS says so in the table's error flags
                // (DPEOI), with every control word flag set and the words
                // asked for, which are not data, as it hands them over
                None if dataset.items.is_empty() && !dataset.written => {
                    end_of_information = true;
                    detected = 0o17;
                    done = count;
                }
                None => detected = 1,
                Some(Item::FileMark) => {
                    detected = 2;
                    dataset.position += 1;
                    dataset.offset = 0;
                }
                Some(Item::Record(words, u)) => {
                    let left = words.len() - dataset.offset;
                    done = left.min(count);
                    data = words[dataset.offset..dataset.offset + done].to_vec();
                    if left <= count || function == 0o10 {
                        detected = 0o10;
                        unused = *u;
                        dataset.position += 1;
                        dataset.offset = 0;
                    } else {
                        dataset.offset += done;
                    }
                }
            },
            // write: part of a record, a record, a file mark, the end of the data
            0o40 | 0o50 | 0o52 | 0o56 => {
                dataset.items.truncate(dataset.position);
                dataset.written = true;
                dataset.unended = function != 0o56;
                done = count;
                dataset.partial.extend_from_slice(&data);
                if function == 0o50 {
                    let record = std::mem::take(&mut dataset.partial);
                    if name == "$OUT" {
                        line = Some(record_text(&record, unused_given));
                    } else {
                        dataset.items.push(Item::Record(record, unused_given));
                        dataset.position += 1;
                    }
                }
                if function == 0o52 && name != "$OUT" {
                    dataset.items.push(Item::FileMark);
                    dataset.position += 1;
                }
                data.clear();
            }
            // rewind
            0o156 => {
                dataset.position = 0;
                dataset.offset = 0;
            }
            _ => {
                self.store(table + 7, request & !(1 << 63) | 1 << 62);
                return;
            }
        }
        for (n, w) in data.iter().enumerate() {
            self.store(area + n as u32, *w);
        }
        if let Some(line) = line {
            // the first character of a printed line moves the paper
            self.print(line.get(1..).unwrap_or(&[]));
        }
        if self.options.trace {
            eprintln!(
                "  {} function {:o}: {} of {} words, ended by {:o}",
                name, function, done, count, detected
            );
        }
        let flags = self.load(table + 5);
        self.store(table + 5, flags & !(0xf << 60) | detected << 60);
        // DPEOI, bit 1 of word 1: the end of the data on a read
        let word = self.load(table + 1) & !(1 << 62);
        self.store(table + 1, word | (end_of_information as u64) << 62);
        self.store(
            table + 7,
            function << 54 | (unused as u64) << 48 | (done as u64) << 24 | area as u64,
        );
    }

    /// `F$RDC`: the next line of an interactive dataset into its buffer, as
    /// a block control word, the text and an end of record control word.
    fn read_circular(&mut self, table: u32) {
        let name = self.tables.get(&table).cloned().unwrap_or_default();
        let first = self.load(table + 1) as u32 & 0xff_ffff;
        let limit = self.load(table + 4) as u32 & 0xff_ffff;
        let mut at = self.load(table + 2) as u32 & 0xff_ffff;
        if self.dataset(&name).position >= self.dataset(&name).items.len() {
            if self.input.is_some() {
                let _ = self.output.write_all(b"? ");
            }
            self.more_input();
        }
        let dataset = self.dataset(&name);
        let item = dataset.items.get(dataset.position).cloned();
        dataset.position += 1;
        let mut status = self.load(table + 1) & !(3 << 62);
        match item {
            Some(Item::Record(words, unused)) => {
                if self.options.echo {
                    let mut line = b"? ".to_vec();
                    line.extend(record_text(&words, unused));
                    self.print(&line);
                }
                let control = 0o10 << 60 | (unused as u64) << 54;
                for w in std::iter::once(words.len() as u64)
                    .chain(words.iter().copied())
                    .chain(std::iter::once(control))
                {
                    self.store(at, w);
                    at += 1;
                    if at >= limit {
                        at = first;
                    }
                }
                let word = self.load(table + 2);
                self.store(table + 2, word & !0xff_ffff | at as u64);
            }
            _ => status |= 1 << 62, // the end of the input
        }
        self.store(table + 1, status);
    }

    /// `F$WDC`: what the program put into the buffer of an interactive
    /// dataset, a line for every record.
    fn write_circular(&mut self, table: u32) {
        let first = self.load(table + 1) as u32 & 0xff_ffff;
        let limit = self.load(table + 4) as u32 & 0xff_ffff;
        let end = self.load(table + 2) as u32 & 0xff_ffff;
        let mut at = self.load(table + 3) as u32 & 0xff_ffff;
        let mut record: Vec<u64> = Vec::new();
        while at != end {
            let w = self.load(at);
            at += 1;
            if at >= limit {
                at = first;
            }
            if w >> 63 != 0 {
                let line = record_text(&record, (w >> 54 & 0o77) as u8);
                self.print(&line);
                record.clear();
            } else if w >> 56 != 0 {
                record.push(w);
            }
        }
        let word = self.load(table + 3);
        self.store(table + 3, word & !0xff_ffff | at as u64);
        let status = self.load(table + 1) & !(1 << 63);
        self.store(table + 1, status);
    }

    /// A system request: the function is in S0 of the program's exchange
    /// package and its argument in S1.  `Some` when the run is over.
    fn request(&mut self) -> Option<End> {
        let (function, s1) = (self.package(8), self.package(9));
        let address = s1 as u32 & 0xff_ffff;
        let mut answer = 0u64;
        if self.options.trace && function != 0o34 && function != 5 {
            eprintln!(
                "request {:o}, S1 {:o} ({})",
                function,
                s1,
                self.name_at(address)
            );
        }
        match function {
            0o000 => return Some(End::Done),
            0o001 => return Some(End::Aborted),
            // the date and the time of day, eight characters each
            0o002 => self.store(address, u64::from_be_bytes(*b"01/01/89")),
            0o003 => {
                let seconds = 12 * 3600 + (self.machine.time() as f64 * 9.5e-9) as u64;
                let text = format!(
                    "{:02}:{:02}:{:02}",
                    seconds / 3600 % 24,
                    seconds / 60 % 60,
                    seconds % 60
                );
                self.store(
                    address,
                    u64::from_be_bytes(text.as_bytes().try_into().unwrap()),
                );
            }
            0o004 => {
                let mut text = Vec::new();
                'message: for n in 0..10 {
                    for b in self.load(address + n).to_be_bytes() {
                        if b == 0 {
                            break 'message;
                        }
                        text.push(b);
                    }
                }
                if self.options.log {
                    let _ = self.output.flush();
                    eprintln!("log: {}", String::from_utf8_lossy(&text));
                }
            }
            0o005 => {}
            // open: the dataset's parameter table is the program's own, or
            // one made here for it (for $IN and $OUT, with a buffer)
            0o010 => {
                let name = self.name_at(address);
                let mut table = self.load(address + 1) as u32 & 0xff_ffff;
                if table == 0 {
                    table = self.next_table;
                    self.next_table += 32;
                    for n in 0..32 {
                        self.store(table + n, 0);
                    }
                    let word = self.load(address);
                    self.store(table, word);
                    let word = self.load(address + 1);
                    self.store(address + 1, word & !0xff_ffff | table as u64);
                    if !self.options.batch {
                        let first = self.next_table as u64;
                        self.next_table += 512;
                        self.store(table + 1, 1 << 28 | first);
                        self.store(table + 2, first);
                        self.store(table + 3, first);
                        self.store(table + 4, first + 512);
                    }
                }
                self.dataset(&name);
                self.tables.insert(table, name);
            }
            // close; a dataset written and not ended has no data under
            // COS: a read after it is opened again finds the end at once
            0o013 => {
                let name = self.name_at(address);
                let dataset = self.dataset(&name);
                if dataset.unended {
                    dataset.items.clear();
                    dataset.partial.clear();
                    dataset.unended = false;
                }
                dataset.position = 0;
                dataset.offset = 0;
            }
            // is there such a dataset, or make one
            0o014 => {
                let name = self.name_at(address);
                if !self.datasets.contains_key(&name) {
                    if self.load(address + 2) >> 61 & 1 != 0 {
                        answer = 1;
                    } else {
                        self.dataset(&name);
                    }
                }
            }
            0o020 => {
                let name = self.name_at(address);
                if let Some(dataset) = self.datasets.get_mut(&name) {
                    let host = dataset.host.take();
                    *dataset = Dataset {
                        host,
                        written: true,
                        ..Default::default()
                    };
                }
            }
            // COS makes the job wait for a line with or without automatic recall
            0o022 => self.read_circular(address),
            0o023 => self.write_circular(address),
            // reprieve: set (S2 = 0) with a table of the routine's parcel
            // address, the save area and the classes; go on with an
            // exchange package (S2 = -1); or end (anything else)
            0o045 => match self.package(10) {
                0 => {
                    let routine = self.load(address) as u32 & 0xff_ffff;
                    let save = self.load(address + 1) as u32 & 0xff_ffff;
                    let classes = self.load(address + 2);
                    self.reprieve = (classes != 0).then_some((routine, save, classes));
                }
                u64::MAX => {
                    // the saved package, but where the program is in memory
                    // stays the system's; no answer in S0
                    for n in 0..16u32 {
                        let mut word = self.load(address + n);
                        if n == 1 || n == 2 {
                            word = word & !(0x7ffff << 29) | self.package(n) & (0x7ffff << 29);
                        }
                        self.machine.store(n, Some(word));
                    }
                    return None;
                }
                _ => return Some(End::Aborted),
            },
            0o027 => {
                let seconds = self.machine.time() as f64 * 9.5e-9;
                self.store(address, cray_float(seconds));
            }
            0o034 => self.buffered(address),
            // more memory: the user area grows at its end and the tables move up
            0o073 => {
                let more = (self.load(address) & 0xff_ffff) as u32;
                let high_limit = (self.load(0o101) >> 24 & 0xff_ffff) as u32;
                let words = (self.words + more).div_ceil(32) * 32;
                if BASE as u64 + words as u64 > self.machine.memory_words() as u64 - 16 {
                    return Some(End::Stopped(format!(
                        "the program asks for {} words more than the {} it has: memory is full",
                        more, self.words
                    )));
                }
                self.words = words;
                if !self.counts.is_empty() {
                    self.counts.resize(words as usize, 0);
                }
                self.lay_out(high_limit);
                let limit = (BASE_UNITS + words / 32) as u64;
                for n in [2, 5] {
                    let word = self.package(n);
                    self.machine
                        .store(n, Some(word & !(0x7ffff << 29) | limit << 29));
                }
            }
            _ => {
                return Some(End::Stopped(format!(
                    "system request {:o} (octal) is not answered here",
                    function
                )))
            }
        }
        self.machine.store(8, Some(answer));
        None
    }

    /// Run until the program ends or `max` instructions have been executed.
    pub fn run(&mut self, max: u64) -> End {
        let handler = MONITOR * 4 + 1;
        let profile = !self.counts.is_empty();
        loop {
            if self.machine.instructions() >= max {
                return End::Limit;
            }
            if self
                .options
                .attentions
                .first()
                .is_some_and(|&at| self.machine.instructions() >= at)
            {
                self.options.attentions.remove(0);
                self.attention_pending = true;
                self.machine.request_mcu_interrupt();
            }
            if profile && !self.machine.monitor_mode() {
                let word = (self.machine.p() >> 2) as usize;
                if word < self.counts.len() {
                    self.counts[word] += 1;
                }
            }
            match self.machine.step() {
                StepResult::Running => {}
                StepResult::Exit(code) => {
                    return End::Stopped(format!("the model stopped with exit {}", code))
                }
                StepResult::Error(e) => return End::Stopped(e.to_string()),
            }
            if self.machine.monitor_mode() && self.machine.p() == handler {
                let word = self.package(3);
                let flags = (word >> 24) as u16 & 0o777;
                if flags & flag::MCU_INTERRUPT != 0 && self.attention_pending {
                    self.attention_pending = false;
                    self.machine.store(3, Some(word & !(0o777 << 24)));
                    if let Some(end) = self.attention() {
                        return end;
                    }
                    continue;
                }
                if flags & flag::NORMAL_EXIT == 0 {
                    let p = (self.package(0) >> 24) as u32 & 0xff_ffff;
                    let what = if flags & flag::ERROR_EXIT != 0 {
                        "error exit"
                    } else if flags & flag::FLOATING_POINT != 0 {
                        "floating point error"
                    } else if flags & flag::OPERAND_RANGE != 0 {
                        "operand range error"
                    } else if flags & flag::PROGRAM_RANGE != 0 {
                        "program range error"
                    } else {
                        "interrupt"
                    };
                    return End::Fault(format!(
                        "{} at P = {:o}{}",
                        what,
                        p >> 2,
                        (b'a' + (p & 3) as u8) as char
                    ));
                }
                self.machine.store(3, Some(word & !(0o777 << 24)));
                if let Some(end) = self.request() {
                    return end;
                }
            }
        }
    }

    /// The station's attention: the program's reprieve routine for it gets
    /// the exchange package and runs, or the program is ended.  Reprieve
    /// ends when its routine is entered, as under COS.
    fn attention(&mut self) -> Option<End> {
        const ATTENTION: u64 = 0o10000;
        match self.reprieve.take() {
            Some((routine, save, classes)) if classes & ATTENTION != 0 => {
                for n in 0..16u32 {
                    let word = self.package(n);
                    self.store(save + n, word);
                }
                let word = self.package(0);
                self.machine
                    .store(0, Some(word & !(0xff_ffff << 24) | (routine as u64) << 24));
                None
            }
            _ => Some(End::Aborted),
        }
    }

    /// Write the datasets the program wrote back to their host files.
    /// Returns the names written.
    pub fn save(&mut self) -> Result<Vec<String>, String> {
        let _ = self.output.flush();
        let mut names = Vec::new();
        for (name, dataset) in &self.datasets {
            if let (Some((file, text)), true) = (&dataset.host, dataset.written) {
                let data = if *text {
                    let mut out = Vec::new();
                    for item in &dataset.items {
                        if let Item::Record(words, unused) = item {
                            out.extend(record_text(words, *unused));
                            out.push(b'\n');
                        }
                    }
                    out
                } else {
                    block(&dataset.items)
                };
                std::fs::write(file, data).map_err(|e| format!("{}: {}", file, e))?;
                names.push(name.clone());
            }
        }
        names.sort();
        Ok(names)
    }

    /// The registers of the program as they were when it last gave up
    /// control, for a message after a fault.
    pub fn registers(&self) -> String {
        let mut text = String::new();
        for n in 0..8 {
            text.push_str(&format!(
                "  A{} {:08o}  S{} {:022o}\n",
                n,
                self.package(n) & 0xff_ffff,
                n,
                self.package(8 + n)
            ));
        }
        text.push_str(&format!("  B00 {:08o}\n", self.machine.b(0).unwrap_or(0)));
        text
    }

    /// Seconds of CPU time by the count of instructions.
    pub fn seconds(&self) -> f64 {
        self.machine.time() as f64 * 9.5e-9
    }
}

/// The entry points of a load map from the loader (`ldr -m`): word address
/// and name, in order of address.
pub fn map_entries(map: &str) -> Vec<(u32, String)> {
    let mut entries: Vec<(u32, String)> = Vec::new();
    let mut inside = false;
    for line in map.lines() {
        let t: Vec<&str> = line.split_whitespace().collect();
        match t.first() {
            Some(&"Entry") => inside = true,
            None | Some(&"External") | Some(&"Module:") => inside = false,
            Some(name) if inside && (t.len() == 2 || t.len() == 3) && !name.starts_with('-') => {
                let address = t[t.len() - 1].trim_end_matches(|c| "abcd".contains(c));
                if let Ok(address) = u32::from_str_radix(address, 8) {
                    entries.push((address, name.to_string()));
                }
            }
            _ => {}
        }
    }
    entries.sort();
    entries.dedup_by_key(|e| e.0);
    entries
}

/// Instructions by routine: every word's count goes to the entry point at
/// or below it.  Most first.
pub fn profile(counts: &[u64], entries: &[(u32, String)]) -> Vec<(u64, String)> {
    let mut totals: Vec<(u64, String)> = entries.iter().map(|e| (0, e.1.clone())).collect();
    if totals.is_empty() {
        return totals;
    }
    let mut entry = 0;
    for (word, count) in counts.iter().enumerate() {
        while entry + 1 < entries.len() && entries[entry + 1].0 as usize <= word {
            entry += 1;
        }
        totals[entry].0 += count;
    }
    totals.retain(|t| t.0 != 0);
    totals.sort_by_key(|t| std::cmp::Reverse(t.0));
    totals
}
