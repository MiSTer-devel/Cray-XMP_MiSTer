//! `cray-xmp-job`: run a program built for COS on the CPU reference model,
//! with no COS: the tool answers the program's system requests.
//!
//! ```text
//! cray-xmp-job PROGRAM [--in FILE] [--ds NAME=FILE]... [--text NAME=FILE]...
//!              [--statement TEXT] [--batch] [--words N] [--max N] [--cp N]
//!              [--profile MAP] [--top N] [--attention N]... [--trace] [--quiet]
//! ```
//!
//! * `PROGRAM`: an absolute binary, as COS-Tools' `ldr` and `ack -mcos`
//!   make one.
//! * `$IN` is standard input, a line when the program asks for one, or the
//!   lines of `--in FILE`, which are shown as they are read.  `$OUT` is
//!   standard output.  They are those of an interactive session, which is
//!   how a program is run at the station; `--batch` makes them those of a
//!   batch job, whose `$OUT` is a printer: the first character of a line is
//!   not printed.
//! * `--ds NAME=FILE`: the dataset `NAME` is the file, in COS's blocked
//!   format (what `tools/py/expdisk.py put` takes).  A file that is not
//!   there is a dataset that does not exist yet.  If the program writes the
//!   dataset the file is written when it ends.  `--text NAME=FILE` is the
//!   same for a text file, a record a line.
//! * `--statement TEXT`: the control statement the program was called with
//!   (the name of the file and a period unless given).
//! * `--words N`: the field length.  Without it the program gets what COS
//!   leaves it, and asks for more itself as it would there.
//! * `--max N`: stop after N instructions.
//! * `--cp N`: the clock periods an instruction takes, for the clocks the
//!   program reads (4 unless given).
//! * `--profile MAP`: at the end, the instructions executed by routine,
//!   from the loader's map (`ldr -m`); `--top N` shows N of them (30).
//! * `--attention N`: the station sends an attention (`/ATTENTION`) after N
//!   instructions; the program's reprieve routine for it runs, or the
//!   program ends.  Given again for more.
//! * `--trace`: every system request, on standard error.
//! * `--quiet`: without the lines for the log and the summary.
//!
//! The exit status is 0 if the program ended, 1 if it aborted, 2 for the
//! instruction limit, 3 for an interrupt (the message says which and
//! where), 4 if it made a request the tool does not answer, 64 for a bad
//! command line and 66 for a file that could not be read or written.

use cray_xmp_job::{map_entries, profile, End, Job, Options, Program};
use std::process::ExitCode;

const USAGE: &str = "usage: cray-xmp-job PROGRAM [--in FILE] [--ds NAME=FILE]... [--text NAME=FILE]... [--statement TEXT] [--batch] [--words N] [--max N] [--cp N] [--profile MAP] [--top N] [--attention N]... [--trace] [--quiet]";

struct Arguments {
    program: String,
    input: Option<String>,
    datasets: Vec<(String, String, bool)>,
    max: u64,
    map: Option<String>,
    top: usize,
    quiet: bool,
    options: Options,
}

fn arguments() -> Result<Arguments, String> {
    let mut a = Arguments {
        program: String::new(),
        input: None,
        datasets: Vec::new(),
        max: u64::MAX,
        map: None,
        top: 30,
        quiet: false,
        options: Options::default(),
    };
    let mut program = None;
    let mut statement = None;
    let mut args = std::env::args().skip(1);
    while let Some(arg) = args.next() {
        let mut value = |name: &str| args.next().ok_or(format!("{} needs a value", name));
        fn number<T: std::str::FromStr>(name: &str, text: String) -> Result<T, String> {
            text.parse().map_err(|_| format!("{} takes a number", name))
        }
        match arg.as_str() {
            "--in" => a.input = Some(value("--in")?),
            "--ds" | "--text" => {
                let text = value(&arg)?;
                let (name, file) = text
                    .split_once('=')
                    .ok_or(format!("{} takes NAME=FILE", arg))?;
                a.datasets.push((name.into(), file.into(), arg == "--text"));
            }
            "--statement" => statement = Some(value("--statement")?),
            "--batch" => a.options.batch = true,
            "--words" => a.options.words = number("--words", value("--words")?)?,
            "--max" => a.max = number("--max", value("--max")?)?,
            "--cp" => a.options.clock_periods = number("--cp", value("--cp")?)?,
            "--profile" => a.map = Some(value("--profile")?),
            "--top" => a.top = number("--top", value("--top")?)?,
            "--trace" => a.options.trace = true,
            "--attention" => a
                .options
                .attentions
                .push(number("--attention", value("--attention")?)?),
            "--quiet" => a.quiet = true,
            _ if arg.starts_with("--") => return Err(format!("unknown option {}", arg)),
            _ if program.is_none() => program = Some(arg),
            _ => return Err(format!("unexpected argument {}", arg)),
        }
    }
    a.program = program.ok_or("no program given")?;
    a.options.statement = statement.unwrap_or_else(|| {
        let name = std::path::Path::new(&a.program)
            .file_stem()
            .map(|s| s.to_string_lossy().to_uppercase());
        format!("{}.", name.unwrap_or_default())
    });
    a.options.profile = a.map.is_some();
    a.options.log = !a.quiet;
    a.options.echo = a.input.is_some();
    Ok(a)
}

fn main() -> ExitCode {
    let a = match arguments() {
        Ok(a) => a,
        Err(e) => {
            eprintln!("cray-xmp-job: {}\n{}", e, USAGE);
            return ExitCode::from(64);
        }
    };
    let file_error = |e: String| {
        eprintln!("cray-xmp-job: {}", e);
        ExitCode::from(66)
    };
    let data = match std::fs::read(&a.program) {
        Ok(d) => d,
        Err(e) => return file_error(format!("{}: {}", a.program, e)),
    };
    let program = match Program::from_dataset(&data) {
        Ok(p) => p,
        Err(e) => return file_error(format!("{}: {}", a.program, e)),
    };
    let map = match &a.map {
        Some(file) => match std::fs::read_to_string(file) {
            Ok(text) => Some(map_entries(&text)),
            Err(e) => return file_error(format!("{}: {}", file, e)),
        },
        None => None,
    };
    let mut job = match Job::new(&program, a.options, Box::new(std::io::stdout())) {
        Ok(job) => job,
        Err(e) => return file_error(e),
    };
    for (name, file, text) in &a.datasets {
        if let Err(e) = job.bind(name, file, *text) {
            return file_error(e);
        }
    }
    match &a.input {
        Some(file) => match std::fs::read(file) {
            Ok(text) => job.input_text(&text),
            Err(e) => return file_error(format!("{}: {}", file, e)),
        },
        None => job.input_reader(Box::new(std::io::BufReader::new(std::io::stdin()))),
    }
    let end = job.run(a.max);
    let written = match job.save() {
        Ok(names) => names,
        Err(e) => return file_error(e),
    };
    let status = match &end {
        End::Done => 0,
        End::Aborted => {
            eprintln!("cray-xmp-job: the program aborted");
            1
        }
        End::Limit => {
            eprintln!("cray-xmp-job: stopped after {} instructions", a.max);
            2
        }
        End::Fault(what) => {
            eprint!("cray-xmp-job: {}\n{}", what, job.registers());
            3
        }
        End::Stopped(what) => {
            eprintln!("cray-xmp-job: {}", what);
            4
        }
    };
    if !a.quiet {
        for name in &written {
            eprintln!("cray-xmp-job: wrote {}", name);
        }
        eprintln!(
            "cray-xmp-job: {} instructions, {:.2} s of CPU time",
            job.machine.instructions(),
            job.seconds()
        );
    }
    if let Some(entries) = map {
        let all: u64 = job.counts.iter().sum();
        for (count, name) in profile(&job.counts, &entries).iter().take(a.top) {
            eprintln!(
                "{:7.2}% {:13}  {}",
                *count as f64 * 100.0 / all.max(1) as f64,
                count,
                name
            );
        }
    }
    ExitCode::from(status)
}
