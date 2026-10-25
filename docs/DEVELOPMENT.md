# Development

How to build, simulate, test, format and lint the core. For what the machine
is made of and where it differs from a real one, see [MACHINE.md](MACHINE.md).

## Layout

- `Cray-XMP.sv`: the MiSTer `emu` wrapper. `files.qip` lists what Quartus builds.
- `rtl/mister/xmp_frontend.sv`: console clock crossings, keyboard and screen
  selection, printer display, terminal rendering and audio.
- `rtl/mister/xmp_reset.sv`: reset synchronization and stretching for the CPU,
  I/O Subsystem, display and serial receiver. The frame-aligned terminal reset
  remains in `Cray-XMP.sv` with the MiSTer video integration.
- `rtl/xmp_machine.v`: the machine. The CPU with the X-MP features and the I/O
  Subsystem, joined by the channel pair between them.
- `rtl/cray/`: CPU modules written for this core.
- `rtl/cray/cray-1x/`: CPU modules that started in the cray-1x project. That
  project is no longer maintained, so they are maintained here like the rest.
- `rtl/ios/`: the I/O Subsystem. Three I/O Processors with their Local
  Memories, clocks, Buffer Memory channels and the channels between them; the
  consoles; the Peripheral Expander with its tape, disk and printer; the
  BIOP's disk drives and its channel into central memory; the MIOP's channel
  pair to the mainframe.
- `rtl/mister/`: what joins the machine to the MiSTer. The DDR3 port and its
  sharing, the check and copy of the boot file, the consoles on the serial
  port, the printer's file, clock domain crossings.
- `rtl/terminal/`: the screens, the keyboard and the video.
- `sys/`: the MiSTer framework, an unmodified copy of
  [Template_MiSTer at `5dda373`](https://github.com/MiSTer-devel/Template_MiSTer/tree/5dda37366d02b04b8448da7b322235c1831af811/sys).
  Update it by copying the entire upstream `sys/` directory unchanged.
- `sim/`: Verilator simulations. `tools/`: assembler, reference models, scripts.
- `tests/`: test programs.
- `software/cos-1.17/`: COS 1.17 as it was recovered: the I/O Subsystem's
  kernel, its boot tape and the expander disk.
- `software/cos-tools/`: the programs and libraries that are installed on the
  drive of the package for the SD card, built to run under COS.
- `docs/spec/`: the specifications the models and the hardware description
  were written from.
- `releases/`: the core and that package.
- `lint/`: Verilator file list, waivers and a PLL stub for `make lint`.

`make` lists the commands below.

## Building the core

Quartus Prime 17.0 Lite builds the core. On Windows or Linux open
`Cray-XMP.qpf` in it and compile, or run `quartus_sh --flow compile Cray-XMP`;
the result is `output_files/Cray-XMP.rbf`. On macOS `build.sh` runs Quartus
through a CrossOver bottle named `Quartus` (the header of the script has the
environment variables for another bottle or another place):

```sh
./build.sh map        # analysis and synthesis only
./build.sh compile    # full flow, writes output_files/Cray-XMP.rbf
```

`compile` exits with status 2 if timing is not met, and with Quartus's own
status if a step failed, as when the design does not fit. The device is
nearly full, so either can come from the fitter's starting point alone:
change `SEED` in `Cray-XMP.qsf` and build again
([MACHINE.md](MACHINE.md#resources) has how the seeds went). Seeds are
independent builds, so several machines can try one each. A Linux machine
without Quartus can run it from a Docker image; the released core was built
in `theypsilon/quartus-lite-c5:17.0.2.docker0`, where Quartus is
`/opt/intelFPGA_lite/quartus/bin/quartus_sh`. Three at a time went well on
a machine of 32 cores; thirteen at once were slower than that.

Everything else needs a Rust toolchain (`cargo`), Verilator 5, Python 3.9 or
later and GNU Make, on macOS or Linux; nothing is fetched from outside the
repository except Rust's own crates, of which the tools use none. The whole
test suite passes with Verilator 5.032 on Ubuntu and with 5.052 on macOS.

**Do not edit `files.qip`, `Cray-XMP.qsf` or any RTL while a build runs.** Quartus
stops with "Settings File changed outside of the Quartus Prime software" and
rewrites `Cray-XMP.qsf` as one large flattened file. If that happens, restore
`Cray-XMP.qsf` to its 78-line form before building again.

A memory that both of its ports write must carry `(* ramstyle = "no_rw_check" *)`,
or Quartus builds it from flip-flops; the first synthesis of this core needed
75,000 logic modules for that reason. The attribute promises that nothing
reads a cell in the clock it is written in. `RW_POISON` checks the promise:
see "Simulations".

## Host tools

A Rust toolchain builds the assembler and the reference model:

```sh
make tools
tools/target/release/cray-xmp asm prog.cal -o prog.img -l prog.lst
tools/target/release/cray-xmp dis prog.img
tools/target/release/cray-xmp isa                 # the instruction table
tools/target/release/cray-xmp-run prog.img --input 'text\r' --max 1000000
```

`cray-xmp-run` is the reference model of the CPU: the CPU of a one-processor
CRAY X-MP at instruction level, written from the hardware reference manuals,
independent of the RTL. The programs it runs are test programs: they print
and stop through a page of memory that only the model and the CPU's test
bench have ([ASSEMBLER.md](ASSEMBLER.md)). It keeps track of values a program
has no right to rely on, such as registers at power-up or the real-time
clock, and stops if one decides a branch, an address or console output.

### The system model

`cray-xmp-sys` joins that CPU model to a model of the
I/O Subsystem: three I/O Processors with their channels, Buffer Memory, the
Peripheral Expander with its tape, disk and printer, nine DD-29 disk drives,
the consoles, and the two links to the mainframe. It runs the I/O Subsystem's
own software, and through it COS 1.17. The hardware description was written
from this model and is checked against it.

`cray-xmp-sys` takes the directory of the ready-to-run COS 1.17 system of the
cray-sim project (the IOP kernel, the boot tape, the expander disk and the
drive images) and never writes to it; a channel whose drive image is missing
has no drive. `--save DIR` writes the disks that were written to into another
directory at the end. What the operator types comes from a script:

```sh
tools/target/release/cray-xmp-sys DIRECTORY --script tests/sys/cos.script
```

`tests/sys/cos.script` gives the date, dead starts COS, logs the station on,
answers the start-up questions and submits a batch job. The kernel console
is copied to the terminal; a `screen` step prints a console as the 24 lines
an operator would see. `--log FILE` writes every channel function of every
I/O Processor. The header of `tools/crates/ios/src/bin/cray-xmp-sys.rs` lists
the script steps and the options, among them the timing of the devices.

### A program without COS

`cray-xmp-job` runs a program built for COS on the CPU model alone. It loads
an absolute binary as COS's loader would and answers the program's system
requests itself, which are the ones the libraries of the
[cross-compilers](#programs-in-c) make: the end of the program, a line for the
log, the date and the clocks, local datasets with buffered I/O, the circular
I/O of a session's `$IN` and `$OUT`, and a request for more memory. Any other
request stops the run with a message that names it.

```sh
tools/target/release/cray-xmp-job hello.abs
tools/target/release/cray-xmp-job prog.abs --in lines.txt --ds DATA=data.bin --profile prog.map
```

`$IN` is the terminal, or the lines of `--in`; `$OUT` is the terminal.
`--attention N` has the station send an attention after N instructions, for a
program that catches it (`_onattn` below). A dataset is a file on the
computer: `--ds NAME=FILE` in COS's blocked format,
which is what `expdisk.py put` takes, or `--text NAME=FILE` as text. A dataset
the program wrote is written back to its file at the end. `--profile` with the
loader's map (`ldr -m`) lists the instructions executed by routine, and
`--trace` every request. A program that is interrupted (an address outside its
field, a floating point error) ends the run with the place and its registers.
The header of `tools/crates/job/src/bin/cray-xmp-job.rs` has the options.

Where COS was found to do something a library can trip over, the tool does
it too: a read of a dataset never written gets words that are not data
along with COS's end-of-data flag, and a dataset written and closed without
an end of data reads as empty.

A run is a second where the system model with COS takes minutes, and its
counts of instructions are exact. Its times are not: every instruction takes
four clock periods, as on the system model. And it is not COS: what a program
does with a request the tool answers differently than COS would only shows
under COS. The tool is also in the image of the cross-compilers, where the
chess program of [Cray-COS-Games](https://github.com/jakesjews/Cray-COS-Games)
uses it to make its opening book.

The tests that run this software look for it in the directory the
environment variable `CRAY_XMP_SYSTEM` names: the ready-to-run COS 1.17 of
the cray-sim project after its install, with the nine drive images. Without
it they are left out. `cargo test` in `tools/` then boots the kernel as far
as its first question, and `make test` runs the script above.

## The package for the SD card

`releases/Cray-XMP_COS-1.17.zip` is made by the system model:

```sh
make tools
python3 tools/py/mkcos.py out --zip releases/Cray-XMP_COS-1.17.zip
```

It starts from the kernel, the boot tape and the expander disk in
[software/cos-1.17](../software/cos-1.17/README.md). The script
gives the model an empty drive and has COS install itself on it
(`START COS_117 INSTALL`), starts COS again and runs one job that saves the
programs and libraries of [software/cos-tools](../software/cos-tools/README.md)
on the drive and enters the programs as commands, then starts COS from the
finished files and runs the three example jobs and one that assembles with
the macros of `SYSTXT`, whose printout it checks. It
takes about eight minutes. The header of the script says what is changed in
the software and why: one drive instead of nine, and which user the jobs
run as.

## Simulations

With Verilator 5 on `PATH`:

```sh
make sim
sim/build/cpu/Vcray_cpu --image prog.img --mem ddr3 --input 'text\r'
sim/build/fp/Vfp_tb tests/fp/xmp_ref.vec
sim/build/core/Vemu BOOTFILE --disk 0=exp_disk.img --until 'ENTER DATE'
```

- `Vcray_cpu` is the CPU with a memory model of four million words, and with
  each output channel cabled to the input channel of its pair. `--mem` picks
  the memory timing: `0`, `fixed:N`, `rand:A-B`, `mister` (the DE10-Nano's
  DDR3 as measured under COS: a word about 16 clocks after its read), `ddr3`
  or `slow`. `--step` holds each instruction until the one before has
  finished. `tools/py/membench.py` runs the memory loops of `tests/cos` on
  it (`tests/bench/membench.cal`) and prints the clock periods each takes
  for an element, for one or more `--mem` profiles.
- `Vfp_tb` checks the floating-point units against vector files.
- `sim/build/iop/Viop_cpu RECORD` is the I/O Processor following a record of
  the reference model's steps; `tools/py/ioptest.py` makes the records.
- `sim/build/ios/Vios KERNEL TAPE [DISK]` is the I/O Subsystem
  (`rtl/ios/ios.v`) booting its kernel. The test bench is Buffer Memory,
  central memory, the file that is the tape, and the sectors of the expander
  disk and of the nine drives (`--drive N=FILE`), which it serves the way the
  MiSTer framework does. `--type TEXT=KEYS` presses keys on a console when it
  has shown TEXT.
- `sim/build/xmp/Vxmp_machine` takes the same arguments and is the whole
  machine (`rtl/xmp_machine.v`), CPU included, with central memory served by
  the test bench. `--quick` leaves out the tests of memory and most of the
  BIOP's test of its drives.
- `sim/build/core/Vemu` is the core as the MiSTer runs it (`Cray-XMP.sv`), with
  stand-ins for `hps_io`, the PLL, DDR3 and the framework's `video_mixer` and
  `video_freak`, which pass the picture through. It loads a boot file into memory
  that is otherwise full of junk, serves the image slots, types on the serial
  port (`--type`) or on the keyboard (`--press`, with `{f1}` to `{f3}`), reads
  the serial port and the video, presses the menu's reset, and at the end
  compares the screens in the core with what the serial port carried. Run it
  from the top of the source tree; the header of `sim/harness/core_main.cpp`
  lists the options.
- `sim/build/ampex/Vterm_ampex_tb` and `sim/build/spool/Vprint_spool` are the
  benches of the terminal and of the printer's file.

The model's terminal is itself checked against the firmware of the real one.
`tools/py/d80emu.py` runs the program ROMs of the Ampex Dialogue 80 on a
model of the terminal's hardware, and `tools/py/d80test.py SEED CASES`
compares it with the model on random streams of characters and keys,
everything a host or a person at the keyboard could tell apart. The ROMs
are not in the repository. They are on bitsavers
(`pdf/ampex/terminal/Ampex_Dialog_80/`, parts 3505240-01 to -06); joined in
that order they are the file the environment variable `CRAY_XMP_D80_ROM`
names. `runtests.py full` runs the comparison when the file is there.

Two of the benches take about a minute of real time for a second of the
machine's; `--quick` runs, where COS is started 2.4 seconds after the reset,
are the practical ones.

To check that no block memory is read in the clock it is written in, build a
bench with `+define+RW_POISON` and run its tests: such a read then returns
the wrong value.

```sh
verilator -f sim/ios.vc +define+RW_POISON --Mdir sim/build/ios_poison -o Vios
CRAY_IOS_SIM=sim/build/ios_poison/Vios python3 tools/py/ioptest.py selftest
```

## Tests

```sh
make test-quick    # about a minute
make test          # the same, then the long runs
```

`tools/py/runtests.py` lists what each runs. The long runs include COS 1.17 on
the system model and on the hardware description if the software is there
(see "The system model").

### The CPU

A test passes when the RTL and the reference model end with the same memory
contents, console output and exit code. Each program runs five ways on the
RTL: fast memory, random memory delays, slow memory, one instruction at a
time, and a second random seed. All five must agree with the model.

- `tests/smoke/` are short programs for each area of the machine. Each runs
  under up to four start-ups from `tests/rt/`: direct, through an exchange, in
  user mode, and in user mode at a non-zero base address.
- `tests/directed/` are the bring-up tests for exchange, floating point and
  vectors; `vload.cal`, vector loads at every alignment, step and length
  (written by `gen_vload.py`); the instruction buffer tests `ibuf.cal`,
  `ibufhalf.cal` and `ibufhop.cal` (written by `gen_ibuf.py`); and the tests
  of what the X-MP added: `xpkg.cal` for the exchange package and the two
  fields, `shared.cal` for the shared registers, semaphores and status
  register, `channels.cal` for the 6 Mbyte channels, `vlah.cal` for the VL
  register and the 24-bit constant, `imm.cal` for interrupt monitor mode,
  `vnu.cal` for the VNU and ESVL bits of the package, `gather.cal` for the
  gather, the scatter and the compress index; `vfar.cal`, vector
  transfers with long steps that leave a user's field; `vedge.cal`, vector
  loads with every small step that run off the end of a field (written by
  `gen_vedge.py`); `together.cal`,
  results of several units that are due in one clock period; `memq.cal`,
  memory references that go on behind the instructions that follow them;
  and `memrange.cal`, the operand range error of such a reference with
  every kind of instruction behind it.
- `tests/rtl_only/` holds programs that check themselves, for what the model
  cannot predict: the real-time clock, the programmable clock and its
  interrupt, the console interrupt, and how many clock periods instructions
  take (`timing.cal`, and `timing_esvl.cal` with the second vector logical
  unit enabled, both written by `gen_timing.py`). They run on the RTL
  alone. A line `* NOSTEP` keeps a program out of the run that holds issue
  to one instruction at a time. A line
  `* SIM: arguments` in such a program gives the simulator more arguments;
  `--ctrl-c 30000,400000` makes the console ask for its interrupt in those
  clocks. `tests/rt/rt_user.cal` has the macros these tests use to send off
  short user programs and look at the flags they come back with.
- `tools/py/randprog.py` writes random programs, shared registers and
  semaphores included. `tools/py/difftest.py rand FIRST LAST` runs a range of
  seeds and keeps failing cases in `build/diff`. With `--chain` the programs
  are mostly vector instructions on a few V registers, so that operations
  take their operands from results, loads and stores still on their way.
- `tests/fp/xmp_ref.vec` holds 79 floating-point cases whose results come from
  the cray-sim project's test program.

Random programs do not use the exits, the monitor instructions, channel
status or the clocks, and they index memory through A0 to A5 and A7.
The smoke tests cover exits, exchanges and range errors.

### The I/O Subsystem

`rtl/ios/iop_cpu.v` is checked against the model `tools/crates/ios/src/iop.rs`
step by step. The model runs a program and writes a record: Local Memory,
then for every instruction or interrupt what its channels answered and what
the registers held afterwards (`replay.rs` has the format). The simulation
is given the same memory and the same answers, and must take the same
interrupts, send the same functions, end every step with the same registers
after the same number of clock periods, and finish with the same memory,
operand registers and exit stack.

```sh
python3 tools/py/ioptest.py rand 1 200     # random programs, two kinds, and a directed one
python3 tools/py/ioptest.py kernel         # the real kernel's boot on each of the three processors
```

- A random program is either all random parcels, which reaches every
  operation code, or mostly register work with functions on the processor's
  own channels and frequent interrupts. Half way through each there is a
  Master Clear and a second dead start.
- `kernel` needs the COS 1.17 software (see "The system model"). The system
  model boots it and the simulation follows one processor: 150 million steps
  for the MIOP, 55 million each for the other two.
- `python3 tools/py/ioptest.py boot` runs the three processors together as
  hardware, each with its Local Memory, real-time clock, Buffer Memory channel,
  its channels to the others and its console, and the MIOP with its
  Peripheral Expander. The MIOP is dead started from Buffer Memory, loads its
  overlays from the tape, dead starts the BIOP and the XIOP and asks for the
  date and the time, which the test types; the BIOP and the XIOP say who they
  are on their own consoles. The test then types `FSTAT`, and the kernel
  lists the files on the expander disk as the system model lists them.
  Meanwhile the BIOP runs its own test of its nine drives and must have
  nothing to report.
- `python3 tools/py/ioptest.py machine` runs the whole machine: the operator
  types `START COS_117 DEADSTART`, and the kernel checks the mainframe. It
  holds the CPU with Master Clear, loads a test program into central memory
  through the BIOP, lets the CPU go, takes a word from it over the channel
  pair and reports `MFINIT: COMPLETE`. With `--start` the run goes on: COS
  is loaded from the expander disk and started, and the kernel reports the
  linkage with it and `START COMPLETE`. That is about two minutes.
- `python3 tools/py/ioptest.py selftest` runs `tests/ios/selftest.py`, a
  program for the I/O Processors that takes the kernel's place, on the system
  model and on the same hardware. It checks what the kernel's start does not
  depend on: the real-time clock, the order in which channels that ask for an
  interrupt are reported, the expander's tape and disk, a drive of the BIOP
  and its channel into central memory, that a word from each processor
  reaches each other one, and the printer. Each processor writes its verdict
  on its console, and what was printed must be the same on both. A second
  run is on the whole machine: the program puts a few instructions into
  central memory, lets the CPU go, exchanges parcels with it over the channel
  pair and tries I/O Master Clear on its own.
- `python3 tools/py/ioptest.py bridges` checks `rtl/xmp_bridge.v` by itself,
  which carries pulses, levels and memory requests between the CPU's clock
  and the I/O Subsystem's: clocks of random periods and the machine's own,
  requests that are taken back before their acknowledge, and resets in the
  middle. `sim/harness/bridge_main.cpp` says what must hold.
- `python3 tools/py/ioptest.py disks` runs the BIOP's disk drives by
  themselves (`rtl/ios/ios_disks.v`): what they read and write, and the
  clocks a seek and a sector take, fast and with the DD-29's own times of
  the menu's "Device times: Real". `python3 tools/py/ioptest.py times` does
  the same for a console, the tape and the printer of the Peripheral
  Expander and the channel pair to the mainframe. The simulations of the
  subsystem, the machine and the core take `--real-times` for that option,
  and `cray-xmp-sys` takes `--timing disk_real=1` for the drives.
- `python3 tools/py/ioptest.py tape` runs the tape drive with the reel on it
  (`rtl/ios/ios_expander.v`, `rtl/ios/ios_reel.v`) through random commands on
  tape files and on the boot tape, against a tape kept in the bench
  (`sim/harness/tape_main.cpp`). With the COS 1.17 software it also has the
  kernel dump a file to a blank tape, delete it and load it back, on the
  system model and on the machine, and compares the two tapes.

### The core

`tools/py/coretest.py` runs the core-level simulation and the two benches
beside it.

- `screens`: the consoles' terminal (`rtl/terminal/term_ampex.v`) against the
  model's (`tools/crates/ios/src/screen.rs`), on random streams of characters
  and keys that reach every function of the terminal: every cell of both
  pages with its protect bit and attributes, the status line, the cursor, the
  page origins, the characters the terminal sends and its bells are compared
  along each stream and at its end.
- `spool`: the printer's file. Random printing into files of random lengths,
  part of them used by an earlier session, and what the files hold afterwards.
- `nofile`: the core without a boot file says so on the screen.
- `printer`: the self-checking program as the boot file. It reports on the
  operator's console, and what it prints is on the printer's screen and in
  the printer's file.
- `boot`: the kernel boots from a boot file; date and time are typed on the
  keyboard; the menu's reset makes it boot again.
- `start`: COS is loaded and started, and the station is logged on from the
  keyboard after F2.
- `restart`: the menu's reset while the CPU runs. The kernel comes up again
  and the CPU waits for it.

Every run fails if the CPU runs before `START` has been typed.

## Files on the expander disk

The disk on the Peripheral Expander is where the station gets jobs and
programs from, and `tools/py/expdisk.py` reads and writes its file system:

```sh
python3 tools/py/expdisk.py list exp_disk.img
python3 tools/py/expdisk.py put exp_disk.img BIN/HELLO hello.abs      # a program from COS-Tools' ldr or from ack
python3 tools/py/expdisk.py puttext exp_disk.img STATION/JHELLO job.txt   # a job: a record a line, /EOF between files
python3 tools/py/expdisk.py gettext exp_disk.img STATION/JTEST30 jtest30.txt
```

On the machine, `SUBMIT,JHELLO` at the station queues the job, and a job or
an interactive session gets a file with `FETCH,DN=HELLO,MF=AP,TEXT=BIN/HELLO.`
and runs it with `HELLO.` The script's header has the layout of the disk and
of a dataset. Taking every dataset of the COS 1.17 disk apart and putting it
together again gives the same bytes. The directory holds 34 files, of which
the disk as it was recovered uses 26 and the one in the package 29.

This is the way to bring in a job with its own deck, or a program compiled
elsewhere.

## Programs in C

The C compiler for COS is a cross-compiler:
[the Amsterdam Compiler Kit for the X-MP](https://github.com/kej715/ack), which
runs on another computer and calls the assembler and the loader of
[COS-Tools](https://github.com/kej715/COS-Tools). `tools/ack/Dockerfile`
builds both, at the commits the programs on the drive were built from:

```sh
docker build -t cray-ack -f tools/ack/Dockerfile tools
docker run --rm -v "$PWD":/work cray-ack ack -mcos -o hello.abs hello.c
docker run --rm -v "$PWD":/work cray-ack cray-xmp-job hello.abs    # try it
python3 tools/py/expdisk.py put exp_disk.img BIN/HELLO hello.abs
python3 tools/py/expdisk.py puttext exp_disk.img STATION/JHELLO jhello.txt
```

`exp_disk.img` is the one in `games/Cray-XMP` on the SD card, and
`jhello.txt` the job that runs the program:

```
JOB,JN=JHELLO,T=60.
ACCOUNT,AC=CRAY,US=SYSTEM.
FETCH,DN=HELLO,MF=AP,TEXT=BIN/HELLO.
SAVE,DN=HELLO.
HELLO.
```

`SUBMIT,JHELLO` at the station runs it, and the printer prints what the
program wrote. With the `SAVE` the program stays on the drive: a later job
gets it with `ACCESS,DN=HELLO.`, and the file can come off the expander disk
again (`expdisk.py rm`).

- **The first character of a printed line is not printed**: it tells the
  printer how far to move the paper. Start every line with a blank.
- What a program writes to `$OUT` is printed when it runs in a job. In an
  interactive session the station shows it, and shows `?` while the program
  reads a line of `$IN`, if the program was built with the image
  (`tools/ack/ack-cos.patch`: the kit's C library reads and writes an
  interactive dataset with COS's circular I/O, the only requests such a
  dataset takes; `read` then returns a line at a time and `isatty` says the
  dataset is a terminal). The libraries on the package's drive
  ([software/cos-tools](../software/cos-tools/README.md)) are the kit's as
  it was, so a program compiled on the machine itself still shows nothing
  in a session, which is why FORTRAN and LISP are run as jobs there.
- A large program gets little room for its heap and stack from COS: the
  loader asks for the program alone, and only a small program inherits room
  from the control statement processor before it. The image's startup code
  asks COS for memory when fewer than 40,960 words are free (the same
  patch). Without it a program of a million words could not open a file. A
  program that needs more says so in a word of its own, `long _heapwds =
  380000;` in C.
- A FORTRAN direct access file (`ACCESS='DIRECT'`, `REC=`) is held in memory
  while it is open: read whole at `OPEN`, written whole at `CLOSE` or when
  the program ends, because the kit reads and writes a COS dataset in
  sequence. It has to fit in the heap (see `_heapwds`), and a program that
  is aborted does not write it back. Units that open the same file share it.
- The kit as it comes did integer multiplication, division and remainders in
  floating point, and wrongly for some numbers: the machine divides by a
  reciprocal that is close and not exact, so `1025000 / 1000` was 1024 and
  131070 was printed as `131060`. Its `realloc` wrote past the end of a
  block that grew by less than a block. Both are put right in the image
  (`ack-cos.patch`), and `memcpy`, `memset` and a binary `read` move words
  where they went a byte at a time.
- Three faults of COS-Tools are put right too (`cos-tools.patch`): the
  loader let an address that wraps around, a symbol less a constant, carry
  into the register field of its instruction, and a program of certain
  lengths above 127 blocks got an end of data where its record ends.
- Blank common (FORTRAN's `COMMON` without a name, or a CAL `SECTION COMMON`
  without one) comes last in the program and is not in the binary: the
  binary's high limit takes it in, and COS gives the program that memory.
  The startup code clears it, because the control statement processor
  that ran in the same memory before the program leaves words there. A
  table there costs no room on the disk: Cray Blitz's hash table made its
  binary 10 MB where it is 3 now.
- A read of a dataset stops at the end of its file and does not read the
  next record before it is asked for one, and a write after a read begins
  where the read stopped. The kit took the flag for an end of file to be 4,
  where COS sets 2, and read on into the next file; and the end of the data
  of a dataset not yet written, which COS reports among the error flags of
  the dataset's table, gave an empty record and then an I/O error. And to go
  back in a dataset (a rewind) the library opens it again: what was written
  is now ended first, as at its close, where COS had nothing to read in it
  after. That is what a FORTRAN program needs that reads a file to its end
  and adds to it, or reads back what it wrote.
- `_onattn(&flag)` has the station's attention (`/ATTENTION`, the BREAK
  key of a real station) set `flag` to -1 where it would end the program;
  the program goes on where it was. It is COS's reprieve (`F$RPV`, class
  10000 octal), which in COS 1.17 takes the routine's address as a parcel
  address. A program cannot see otherwise that something was typed while
  it works: COS keeps a job that reads the session's input waiting for the
  line, with or without automatic recall. Cray Blitz takes the opponent's
  move this way while it thinks on the opponent's time.
- The kit also compiles Pascal and BASIC. A first program in each did not
  link here (`Unsatisfied external reference`), and that was not followed up.
- On Linux the assembler of COS-Tools needs the one-line change the
  Dockerfile makes, or the kit's C library does not assemble. On macOS it
  builds as it is; the kit itself needs what
  [software/cos-tools](../software/cos-tools/README.md) says.

## Programs in FORTRAN

The same image has COS-Tools' FORTRAN 77 compiler as a cross-compiler,
`kftc`, with `cft77` to compile, assemble and link in one go:

```sh
docker run --rm -v "$PWD":/work cray-ack cft77 prog      # prog.f to prog.abs
```

`kftc -H` takes FORTRAN IV habits: a character constant where a number is
expected is a Hollerith constant, left-justified and blank-filled in a word,
and one passed to a routine is passed as words; a format may be held in an
integer array. `tools/ack/cos-tools-fortran.patch` adds that mode and what
else the compiler and its runtime lacked for such programs: `PRINT f` with
no list, `RETURN` with an expression, A input into a word left-justified,
direct access records (the record number was ignored), a fresh record after
a `/` at the end of a format, and room for formats of 256 descriptors. On
input a `/` reads the next record, also when it comes after the last item
(it read on in the same record), and `BACKSPACE` goes back over the record
read or written last, or after the end of the file back to before it (it
did nothing). An `OPEN` of a name that no dataset can have, longer than
seven characters, fails as one of a dataset that is not there does, so that
`ERR=` sees it; it stopped the program.

The same patch has the bit functions of Cray FORTRAN compiled in line (`AND`,
`OR`, `XOR`, `NOT` and `ISHFT`, with `IAND`, `IOR`, `IEOR` and `COMPL`), the
product of two integers below 2**24, and `MIN`, `MAX` and `ABS` of integers.
Each was a call. The condition of an `IF` is compiled as jumps, a compare
and a jump for each relation, with `.AND.` and `.OR.` jumping as soon as the
outcome is known: the compiler made each relation a value with a jump and
tested the result with another (`fortran/jumps.c`, a pass over the compiled
program, in the cross-compiler only). The code is otherwise what it was: a
statement at a time, every value through memory. An octal or hexadecimal
constant (`O'17'`, `X'FF'`) has all its 64
bits; it was cut to 32, so that a mask of 40 bits was all ones.

Routines in Cray's assembly language link with the compiler's code: its
external names have an `@` before them, it keeps its stack, frame and heap
pointers in A7, A6 and A5 and uses no B register but B00, it passes the
addresses of arguments on the stack and takes a function's result from S7.
Two games are built with it, in a repository of their own,
[Cray-COS-Games](https://github.com/jakesjews/Cray-COS-Games): Super Star
Trek of 1983, whose `prime2cray.py` shows what else such a program needs
before the compiler takes it, and Cray Blitz, the chess program of 1991,
whose `blitz2cray.py` and `lib/blitz.c` show what a Cray program of the time
needs: RANF and the clocks, and its routines in assembly language, written
for Cray's own compiler, joined to the kit's.

## Testing on a MiSTer

`tools/py/hil.py` drives a MiSTer over SSH (`MISTER`, default `root@mister`;
`MISTER_PW`, default `1`). It needs `sshpass`. Unpack the package for the SD
card on the MiSTer once.

```sh
python3 tools/py/hil.py deploy                  # copy the core
python3 tools/py/hil.py start cos117.ios -t 60 \
    --type 'ENTER DATE [MM/DD/YY]=10/05/89\r' \
    --type 'ENTER TIME [HH:MM:SS]=01:02:03\r' \
    --type '10/05/89  01:02:03=START COS_117 DEADSTART\r' \
    --until 'START COMPLETE'
python3 tools/py/hil.py session -t 20 --type '+500=STATION\r' --type '@0:CRAY STATION=LOGON\r' --screen 0
python3 tools/py/hil.py session -t 60 --type '@0:+1000=STMSG\r' --type '@0:+6000=REPLY,0,GO\r' \
    --type '@0:+30000=STMSG,I\r' --type '@0:+8000=CLASS,ALL,ON\r' --type '@0:+2000=LIMIT,5\r' --screen 0
python3 tools/py/hil.py session -t 30 --type '@0:+1000=SUBMIT,JCAL\r'
python3 tools/py/hil.py keys '{f2}stmsg\r'      # type on a virtual keyboard
python3 tools/py/hil.py printed                 # what the printer's file holds
```

No job runs before the second session's statements: COS waits for the
reply to its configuration question, then `STMSG,I` must end with
`STARTUP COMPLETE`, and the classes have to be on with a limit (the
README's steps 8 to 10). A `+N` wait types after N milliseconds, which
is what to use when the text to wait for is on the screen already; `@0:`
puts the keys on the station. The year has two digits, so the date has to
be 1989 or thereabouts. A job's log is on the printer within seconds.

Both consoles are on the HPS serial port, `/dev/ttyS1` at 115200 baud: bit 7
of a byte is clear for the operator's console and set for the station.
`start` and `session` wait for texts and type answers the way the benches do,
and print a console as its 24 lines with `--screen` (0 the station, 3 the
operator's). A serial BREAK resets the machine as the menu's reset does;
`session --break` sends one.

For a start as after a power cycle, stop the machine first (`hil.py session
--break`), then put a fresh `drives.img` in place and load the core again,
which clears the memories. A COS that is still running writes to the drive
again, and a start on a fresh drive with the old memory ends in `CRAY HALT`.

Screenshots need direct video off: `hil.py direct-video off`, `hil.py shot out.png`,
`hil.py direct-video on`.

## Formatting

With `verible-verilog-format`, Python 3.9+ and Git on `PATH`, run from the
repository root:

```sh
make format-check                       # read-only; fails if formatting differs
make format                             # apply formatting
make format FILES='rtl/xmp_machine.v'
```

The same operations are available through
`python3 tools/py/verible.py format|format-check [files...]`. `format-check`
returns nonzero when formatting differs; both return nonzero on tool errors.

The formatter covers Verilog and SystemVerilog sources under `rtl/` and
`sim/`, including new, untracked files. Ignored files are excluded.

These files are never formatted:

- `Cray-XMP.sv`, which follows upstream `Template.sv` layout and comments so
  framework integration changes can be pasted into the shared sections;
  it retains upstream CRLF line endings and whitespace. Unused port defaults
  stay in template order; actively used ports are driven in their corresponding
  functional sections. The Cray-specific implementation follows the shared sections
- `sys/`, the MiSTer framework
- `rtl/pll.v` and `rtl/pll/`, generated IP

Naming one of them is rejected: `make format FILES='sys/hps_io.sv'` changes
nothing.

The configuration is the one the Apple III core uses: tab indentation,
aligned declarations, ports and assignments, a 120-column target, settings in
`.verible-format.flags`. Verible emits spaces, so the wrapper expands leading
tabs at four-column stops before formatting and restores them afterwards. It
protects strings, comments and `verilog_format: off/on` regions. `.editorconfig`
uses the same tab width. Validated with Verible `v0.0-4296-g0f262651`.

## Linting

With Verilator on `PATH`:

```sh
make lint
```

This writes a fixed build ID to `lint/gen/` and runs Verilator with
`--lint-only -Wall -f lint/rtl.f` on the `emu` top, as built for the MiSTer.

`lint/rtl.f` lists the sources from `files.qip`; update both when adding a
synthesis source. `.v` files are parsed as Verilog 2005, as Quartus does.

Warnings are fatal. The policy and the waivers are in `lint/exclusions.vlt`:

- File naming, shadowing, declaration initialisers and explicitly empty port
  connections are not checked anywhere.
- `sys/` and the PLL stub are loaded so that connections from project RTL are
  checked, but their own diagnostics are suppressed.
- Keep upstream template code intact and put any necessary lint exceptions
  in `lint/exclusions.vlt`, rather than changing the shared code for lint.
- Everything else, the cray-1x sources included, has waivers only for
  reviewed cases, each with its reason: the `hps_io` ports this core does not
  use, named one by one; bits the floating-point arithmetic forms and then
  drops; ports and instruction fields a module takes but does not need.

Lint uses a port-only PLL stub, so it does not check Intel primitives or
timing. Validated with Verilator 5.052.

The host tools are not covered by `make lint` or `make format`.

## Proving that an edit changes nothing

With Yosys on `PATH`:

```sh
python3 tools/py/equiv.py                 # every RTL file that differs from HEAD
python3 tools/py/equiv.py --rev HEAD~1 rtl/cray/cray-1x/func_top.v
```

For each module in a changed file, Yosys compares the working tree with the
named revision: the same outputs, the same next state of every register and
the same values sent to every submodule, for all inputs. Use it after
reformatting or a lint clean-up, to cover what the simulations do not reach.

It needs ports, registers and submodule instances to keep their names, and it
does not look inside submodules; their files are checked on their own.
