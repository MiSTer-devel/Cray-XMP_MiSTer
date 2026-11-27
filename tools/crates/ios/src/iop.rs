//! The I/O Processor: registers, Local Memory, the instruction set, the
//! program exit stack, interrupts, Master Clear and the channels that are
//! part of the processor (0 IOR, 1 PFR, 2 PXS, 3 LME, 4 RTC).
//!
//! Page numbers `[HW n-m]` are printed pages of HR-0030 rev B, the I/O
//! Subsystem Model B Hardware Reference Manual.  "Spec" is
//! `docs/spec/iop-cpu-spec.md` in the core's repository; its part 11
//! lists the questions the manual leaves open, cited here as "spec Q1" and
//! so on.

/// Parcels of Local Memory: a 16-bit address selects one 16-bit parcel
/// [HW 2-1].
pub const MEMORY_PARCELS: usize = 1 << 16;
/// Operand registers, selected by the 9-bit d field or by B [HW 4-1].
pub const OPERAND_REGISTERS: usize = 512;
/// Locations of the program exit stack [HW 3-7].
pub const EXIT_STACK: usize = 16;
/// Clock periods from one setting of the real-time clock's Done flag to the
/// next: the counter runs from 0 to 234177 octal, 1 ms at 12.5 ns [HW 5-12].
pub const RTC_PERIOD: u32 = 80_000;
/// One more than the highest channel number: the Model B has 40 channels,
/// 0 to 47 octal [HW 5-1].
pub const CHANNELS: u16 = 0o50;

/// The channels inside the processor [HW 5-9 to 5-13].
pub mod channel {
    /// Interrupt request: reads the number of the requesting channel.
    pub const IOR: u16 = 0;
    /// Program fetch request.
    pub const PFR: u16 = 1;
    /// Program exit stack.
    pub const PXS: u16 = 2;
    /// Local Memory error.
    pub const LME: u16 = 3;
    /// Real-time clock.
    pub const RTC: u16 = 4;
    /// The first channel outside the processor (Buffer Memory).
    pub const FIRST_EXTERNAL: u16 = 5;
}

const D_MASK: u16 = 0o777;
const E_MASK: u8 = 0o17;

/// The channels outside the processor: 5 to 47 octal.
///
/// Each has a Busy flag, a Done flag and an Interrupt Enable flag, and
/// requests an interrupt while Done and Interrupt Enable are both set
/// [HW 5-2, 5-4, 7-2].  All three flags belong to the device side: functions
/// 6 and 7 clear and set Interrupt Enable on every channel but the
/// Peripheral Expander's [HW 7-1], so the processor passes them on like any
/// other function.
pub trait Channels {
    /// A function strobe with the accumulator [HW 5-3].  `mem` is the
    /// processor's Local Memory, for channels that move data by themselves.
    /// Returns the value for the accumulator when the function is one that
    /// reads (10 to 13 octal), else `None`.  `None` from a function that
    /// reads loads zero.
    fn function(&mut self, mem: &mut [u16], channel: u8, function: u8, a: u16) -> Option<u16>;
    /// The Busy flag of a channel, for 041 and 043.
    fn busy(&mut self, channel: u8) -> bool;
    /// The Done flag of a channel, for 040 and 042.
    fn done(&mut self, channel: u8) -> bool;
    /// The lowest numbered channel (5 to 47 octal) with Done and its
    /// Interrupt Enable both set.
    fn interrupt(&mut self) -> Option<u8>;
    /// Clock periods pass before the processor issues what it does next: a
    /// step begins with the wait for its issue, and the channels are asked
    /// and told in the clock period of the issue.
    fn pass(&mut self, _clock_periods: u32) {}
}

/// No devices: every channel from 5 up is empty.
#[derive(Clone, Copy, Debug, Default)]
pub struct NoChannels;

impl Channels for NoChannels {
    fn function(&mut self, _: &mut [u16], _: u8, _: u8, _: u16) -> Option<u16> {
        None
    }
    fn busy(&mut self, _: u8) -> bool {
        false
    }
    fn done(&mut self, _: u8) -> bool {
        false
    }
    fn interrupt(&mut self) -> Option<u8> {
        None
    }
}

/// Counts of events since the processor was made, for traces and for the
/// things the specification wants counted during a boot (spec Q4, Q16).
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct Counters {
    /// Instructions executed.
    pub instructions: u64,
    /// Interrupts taken, dead start interrupts included.
    pub interrupts: u64,
    /// Functions and flag tests addressed to channel 1 (PFR).
    pub pfr_channel: u64,
    /// Shifts with a count (d or B) above 17, where the manual and cray-sim
    /// part ways.
    pub long_shifts: u64,
    /// Times the Exit Stack Boundary flag was set.
    pub boundary_flags: u64,
    /// Stores of the processor (034 to 037) into a parcel the instruction
    /// stack held or had asked for.
    pub stack_stores: u64,
    /// Times a channel had changed a parcel the instruction stack held.
    pub stack_device_stores: u64,
    /// Branches that were taken to an instruction in the stack, and those
    /// that filled it again (EXIT and interrupts among them).
    pub in_stack: u64,
    pub out_of_stack: u64,
}

// ---- when an instruction issues (spec part 8)
//
// An instruction does all it does in the clock period it issues in; what
// the real machine spreads over the clock periods behind that only decides
// when the instructions behind it may issue.  The rules are those of the
// spec, part 8.2: R1 to R13 there.

/// Parcels of the instruction stack [HW 3-3].
pub const STACK: usize = 32;
/// The stack is filled while the last parcel loaded is fewer than this many
/// ahead of the instruction that issues next (HR-0808 Part 3 3-5).
const STACK_AHEAD: i32 = 8;
/// Clock periods from the read of a parcel in Local Memory to the first one
/// it can issue in: a fetch request in clock period q has its first parcel
/// read in q + 1 and issuing in q + 5 [HW 6-59].
const CP_FETCH: usize = 4;
/// A branch to an instruction in the stack: "can issue at CP 5" [HW 6-59].
const CP_IN_STACK: u64 = 5;
/// The fetch request of a branch that leaves the stack is in its clock
/// period 4 [HW 6-59, 6-63], that of an EXIT in 2, where P is loaded
/// [HW 6-4], and the first instruction of the new sequence issues 5 clock
/// periods after the request.
const CP_REQUEST: u64 = 4;
const CP_REQUEST_EXIT: u64 = 2;
const CP_REQUEST_TO_ISSUE: u64 = 5;
/// A store of the processor into a parcel the stack holds makes the stack
/// fill again behind it: the request is in the clock period of the store.
const CP_REQUEST_STORE: u64 = 2;
/// The interrupt sequence.  The manual gives no time; it is taken to cost
/// what a return jump out of the instruction stack costs: 9 clock periods.
const CP_INTERRUPT: u64 = CP_REQUEST + CP_REQUEST_TO_ISSUE;
/// "No other instruction can issue until CP 5" behind 040 to 043 [HW 6-35].
const CP_FLAG_TEST: u64 = 5;

/// Two parcels: 014 to 017, and the branches by an operand register and k.
fn two_parcels(f: u16) -> bool {
    matches!(f, 0o014..=0o017 | 0o075 | 0o077 | 0o124..=0o127 | 0o134..=0o137)
}
/// Branches by P and d (070 to 073, 100 to 117).
fn relative(f: u16) -> bool {
    matches!(f, 0o070..=0o073 | 0o100..=0o117)
}
/// Branches by an operand register (074 to 077, 120 to 137).
fn absolute(f: u16) -> bool {
    matches!(f, 0o074..=0o077 | 0o120..=0o137)
}
/// In how many clock periods from its issue an instruction wants the
/// accumulator free: at issue, in 1 or in 2 (CSM-1009 page 7-2; 014 to 017
/// one more than that table, which has their issue behind the read of k).
/// `None` for those that do not use it.
fn accumulator_in(f: u16) -> Option<u64> {
    match f {
        0o010 | 0o050 | 0o054 | 0o056 | 0o057 => Some(0),
        0o004..=0o007
        | 0o011..=0o014
        | 0o020
        | 0o021
        | 0o024
        | 0o026
        | 0o027
        | 0o044..=0o047
        | 0o051..=0o053
        | 0o055
        | 0o060
        | 0o061
        | 0o064
        | 0o066
        | 0o067
        | 0o140..=0o177 => Some(1),
        0o015..=0o017 | 0o022 | 0o023 | 0o025 | 0o030..=0o043 | 0o062 | 0o063 | 0o065 => Some(2),
        _ => None,
    }
}
/// The clock period, counted from the issue, in which an instruction
/// delivers to the accumulator ("the accumulator is free for subsequent
/// instructions").  054 has it at 2 on the Model B [HW 6-47]; 024 and 064
/// reserve nothing.
fn accumulator_free(f: u16) -> Option<u64> {
    match f {
        0o010 | 0o011 | 0o050 | 0o051 => Some(1),
        0o014 | 0o015 | 0o020 | 0o021 | 0o054 | 0o060 | 0o061 => Some(2),
        0o004..=0o007 | 0o012 | 0o013 | 0o044..=0o047 | 0o052 | 0o053 | 0o055..=0o057 => Some(3),
        0o016 | 0o017 | 0o022 | 0o023 | 0o025..=0o027 | 0o034 | 0o062 | 0o063 | 0o065..=0o067 => {
            Some(4)
        }
        0o040..=0o043 => Some(5),
        0o150..=0o153 | 0o170..=0o173 => Some(6),
        0o030 | 0o031 => Some(7),
        0o032 | 0o033 => Some(9),
        0o035..=0o037 => Some(11),
        _ => None,
    }
}
/// The clock period in which an instruction has the adder.
fn adder_in(f: u16) -> Option<u64> {
    match f {
        0o012 | 0o013 | 0o052 | 0o053 | 0o055..=0o057 => Some(2),
        0o016 | 0o017 | 0o022 | 0o023 | 0o025..=0o027 | 0o062 | 0o063 | 0o065..=0o067 => Some(3),
        0o032 | 0o033 | 0o035..=0o037 => Some(8),
        _ => None,
    }
}
/// Instructions that write an operand register through the DP register and
/// cannot issue while it is full (CSM-1009 page 7-3).
fn wants_dp(f: u16) -> bool {
    matches!(f, 0o011 | 0o015 | 0o024..=0o027 | 0o051 | 0o064..=0o067)
}
/// Instructions that read an operand register.
fn reads_register(f: u16) -> bool {
    matches!(f, 0o020..=0o037 | 0o060..=0o067) || absolute(f)
}
/// Of those, the ones whose read is in their clock period 2 and waits there
/// for a store into the same register that is still on its way.
fn reads_late(f: u16) -> bool {
    matches!(f, 0o022 | 0o023 | 0o030..=0o037 | 0o062 | 0o063) || absolute(f)
}
/// Instructions that cannot issue while B is reserved.
fn wants_b(f: u16) -> bool {
    matches!(f, 0o011 | 0o015 | 0o042..=0o067 | 0o160..=0o177)
}
/// Functions that read into the accumulator.
fn input(f: u16) -> bool {
    matches!(f, 0o150..=0o153 | 0o170..=0o173)
}

/// What the stream of instructions does in a clock period, for the
/// instruction stack.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Flow {
    /// Nothing issues.
    Wait,
    /// An instruction of so many parcels issues and the one behind it is
    /// next.
    Next(i32),
    /// A branch to an instruction in the stack, so many parcels forward.
    InStack(i32),
    /// The stack is filled again from P, with the fetch request in this
    /// clock period.
    Refill(u64),
}

/// What an instruction did, as far as its clock periods go.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Did {
    Plain,
    Exit,
    NotTaken,
    /// A branch by P and d that was taken: the parcels forward.
    Relative(i32),
    /// A branch by an operand register that was taken.
    Absolute,
}

/// The clock periods things are free in, and the instruction stack.  Times
/// are clock periods since the processor was made.
#[derive(Clone, Debug)]
struct Issue {
    /// The clock period that is next.
    now: u64,
    /// The earliest issue the order of the program allows.
    seq: u64,
    /// One clock period behind the one in which the criterion of a
    /// conditional branch exists: two behind the last delivery to the
    /// accumulator.
    criterion: u64,
    /// The DP register is empty from here on; the register it has the
    /// pointer of.
    dp_empty: u64,
    dp_register: u16,
    /// B is not reserved from here on.
    b_free: u64,
    /// The last acceptance of a reference by Local Memory.
    accepted: u64,
    /// The clock period in which an instruction that has issued has the
    /// adder.
    adder: u64,
    /// The issue of the last function that reads, and of the last
    /// instruction whose word for the accumulator comes a clock period
    /// behind its issue.
    input: Option<u64>,
    late: Option<u64>,
    /// Clock periods in which an instruction has the port into Local Memory.
    port: [Option<u64>; 2],
    /// The stack is being filled; or will be again from P, with the fetch
    /// request in this clock period.
    filling: bool,
    refill: Option<u64>,
    /// The address of the parcel that is read next.
    load: u16,
    /// Parcels the stack holds or has asked for, 32 at most: the window is
    /// the `count` addresses below `load`.
    count: u32,
    /// Parcels asked for from P on, and those of them that can issue.
    asked: i32,
    ahead: i32,
    /// Parcels read one, two and three clock periods ago.
    coming: [bool; CP_FETCH - 1],
    /// What the stack holds, by the low five bits of the address.
    copy: [u16; STACK],
}

impl Issue {
    fn new() -> Issue {
        Issue {
            now: 0,
            seq: 0,
            criterion: 0,
            dp_empty: 0,
            dp_register: 0,
            b_free: 0,
            accepted: 0,
            adder: 0,
            input: None,
            late: None,
            port: [None; 2],
            filling: false,
            refill: None,
            load: 0,
            count: 0,
            asked: 0,
            ahead: 0,
            coming: [false; CP_FETCH - 1],
            copy: [0; STACK],
        }
    }

    /// Master Clear: nothing is reserved and the stack is empty.
    fn clear(&mut self) {
        *self = Issue {
            now: self.now,
            ..Issue::new()
        };
    }

    /// The parcels the stack would still read if the instruction that
    /// issues now, of so many parcels, were followed by the one behind it:
    /// the rest of the burst under way, and the bursts that keep the last
    /// parcel asked for 8 ahead.  The manual's "predetermined internal
    /// fetches" (HR-0808 Part 3 page 3-5).
    fn to_come(&self, parcels: i32) -> i32 {
        if !self.filling {
            return 0;
        }
        // the rest of the burst, then one or two bursts more (a branch has
        // the parcel behind it in the stack or on its way: never three)
        let rest = (4 - (self.load & 3) as i32) & 3;
        let ahead = self.asked - parcels + rest;
        rest + if ahead <= STACK_AHEAD - 4 {
            8
        } else if ahead <= STACK_AHEAD {
            4
        } else {
            0
        }
    }

    /// Nothing happens in the stack by itself in the clock periods to come.
    fn at_rest(&self) -> bool {
        self.refill.is_none()
            && self.coming == [false; CP_FETCH - 1]
            && self
                .port
                .iter()
                .all(|at| at.map_or(true, |at| at < self.now))
            && !(self.filling && (self.load & 3 != 0 || self.asked <= STACK_AHEAD))
    }
}

/// One I/O Processor.  See the crate documentation.
pub struct Iop {
    /// The accumulator.
    a: u16,
    /// The carry bit: bit 2**16 of the accumulator in add, subtract and
    /// shift [HW 4-4].
    c: bool,
    /// The B register, 9 bits.
    b: u16,
    p: u16,
    /// The exit stack pointer, 4 bits: it points at the newest entry.
    e: u8,
    xs: [u16; EXIT_STACK],
    or: [u16; OPERAND_REGISTERS],
    mem: Vec<u16>,
    /// The System Interrupt Enable flag.
    i: bool,
    /// 003 has been executed and the flag is not set yet.
    i_delayed: bool,
    /// Master Clear has been applied and no interrupt has been taken since.
    held: bool,
    /// Channel 1: the Program Fetch Request flag (its Done flag), the
    /// register with the d of the instruction that set it, Interrupt Enable.
    pfr: bool,
    pfr_register: u16,
    pfr_enable: bool,
    /// Channel 2: the Exit Stack Boundary flag (its Done flag) and
    /// Interrupt Enable.
    boundary: bool,
    pxs_enable: bool,
    /// Channel 3: Interrupt Enable.  The parity error flag never sets.
    lme_enable: bool,
    /// Channel 4: the counter (0 to `RTC_PERIOD` - 1), Done, Interrupt
    /// Enable.
    rtc: u32,
    rtc_done: bool,
    rtc_enable: bool,
    counters: Counters,
    /// When things are free, and the instruction stack.
    t: Issue,
    /// A channel may have stored in Local Memory since the stack was last
    /// held against it.
    stored: bool,
    /// The parcel of the stack a channel was found to have changed, in the
    /// step that found it.
    device_store: Option<u16>,
    /// The channel outside the processor (the real-time clock, 4, among
    /// them) that asked for an interrupt in the clock period the last step
    /// issued in.
    asked_by: Option<u8>,
}

impl Default for Iop {
    fn default() -> Self {
        Iop::new()
    }
}

impl Iop {
    /// A processor at power-up: every register and all of Local Memory
    /// zero, and Master Clear applied.
    pub fn new() -> Iop {
        let mut iop = Iop {
            a: 0,
            c: false,
            b: 0,
            p: 0,
            e: 0,
            xs: [0; EXIT_STACK],
            or: [0; OPERAND_REGISTERS],
            mem: vec![0; MEMORY_PARCELS],
            i: false,
            i_delayed: false,
            held: false,
            pfr: false,
            pfr_register: 0,
            pfr_enable: false,
            boundary: false,
            pxs_enable: false,
            lme_enable: false,
            rtc: 0,
            rtc_done: false,
            rtc_enable: false,
            counters: Counters::default(),
            t: Issue::new(),
            stored: false,
            device_store: None,
            asked_by: None,
        };
        iop.master_clear();
        iop
    }

    /// Master Clear.  The processor then executes nothing until it takes an
    /// interrupt; `step` only lets time pass.
    ///
    /// The manual says only that exit stack location 0 is cleared and that
    /// the dead start interrupt starts the program at 0 with E advanced by
    /// one [HW 5-11].  The rest is the choice of the spec, part 2.3 (Q11,
    /// Q12): P and E are 0, the whole exit stack is cleared, System
    /// Interrupt Enable is set so that the dead start interrupt is
    /// accepted, and the flags and Interrupt Enables of channels 1 to 4 are
    /// cleared.  A, the carry, B, the operand registers and Local Memory
    /// keep what they held: the kernel reads operand register 511 before it
    /// clears the registers.  The real-time clock cannot be set [HW 5-12]
    /// and goes on counting.
    pub fn master_clear(&mut self) {
        self.p = 0;
        self.e = 0;
        self.xs = [0; EXIT_STACK];
        self.i = true;
        self.i_delayed = false;
        self.held = true;
        self.pfr = false;
        self.pfr_register = 0;
        self.pfr_enable = false;
        self.boundary = false;
        self.pxs_enable = false;
        self.lme_enable = false;
        self.rtc_done = false;
        self.rtc_enable = false;
        self.t.clear();
    }

    /// Leave the Master Clear state without a dead start and go on at `p`
    /// with System Interrupt Enable clear, the instruction stack filling
    /// from there.  For tests; the real machine starts by the dead start
    /// interrupt (see `step`).
    pub fn start_at(&mut self, p: u16) {
        self.i = false;
        self.i_delayed = false;
        self.held = false;
        self.set_p(p);
    }

    // ---- state

    /// P: the address of the next instruction.
    pub fn p(&self) -> u16 {
        self.p
    }
    /// The accumulator.
    pub fn a(&self) -> u16 {
        self.a
    }
    /// The carry bit.
    pub fn c(&self) -> bool {
        self.c
    }
    /// The B register (9 bits).
    pub fn b(&self) -> u16 {
        self.b
    }
    /// E, the exit stack pointer (4 bits).
    pub fn e(&self) -> u8 {
        self.e
    }
    /// The program exit stack.
    pub fn exit_stack(&self) -> &[u16; EXIT_STACK] {
        &self.xs
    }
    /// Operand register `d`.
    pub fn operand(&self, d: usize) -> u16 {
        self.or[d]
    }
    /// The operand registers.
    pub fn operands(&self) -> &[u16; OPERAND_REGISTERS] {
        &self.or
    }
    /// The System Interrupt Enable flag.
    pub fn interrupt_enable(&self) -> bool {
        self.i
    }
    /// 003 has been executed and System Interrupt Enable is not set yet.
    pub fn interrupt_enable_delayed(&self) -> bool {
        self.i_delayed
    }
    /// Master Clear has been applied and no interrupt has been taken since.
    pub fn held(&self) -> bool {
        self.held
    }
    /// Local Memory.
    pub fn memory(&self) -> &[u16] {
        &self.mem
    }
    /// Local Memory, for the dead start load and for devices that move data
    /// outside a function strobe.
    pub fn memory_mut(&mut self) -> &mut [u16] {
        self.stored = true;
        &mut self.mem
    }
    /// The parcel of the instruction stack a channel was found to have
    /// changed at the beginning of the last step, if it found one.
    pub fn device_store(&self) -> Option<u16> {
        self.device_store
    }
    /// The channel from 4 up that asked for an interrupt in the clock period
    /// the last step issued in, whether or not the interrupt was taken.
    pub fn asked_by(&self) -> Option<u8> {
        self.asked_by
    }
    /// The real-time clock's counter: 0 to `RTC_PERIOD` - 1.
    pub fn rtc(&self) -> u32 {
        self.rtc
    }
    /// The register of channel 1: the d of the instruction that last set
    /// the Program Fetch Request flag.
    pub fn pfr_register(&self) -> u16 {
        self.pfr_register
    }
    /// The Done flag of a channel inside the processor (0 to 4): always set
    /// on channel 0, the Program Fetch Request flag on 1, the Exit Stack
    /// Boundary flag on 2, never set on 3, the real-time clock's on 4.
    pub fn done(&self, channel: u16) -> bool {
        match channel {
            channel::IOR => true,
            channel::PFR => self.pfr,
            channel::PXS => self.boundary,
            channel::RTC => self.rtc_done,
            _ => false,
        }
    }
    /// The Interrupt Enable flag of a channel inside the processor (1 to
    /// 4).  Channel 0 has none.
    pub fn enabled(&self, channel: u16) -> bool {
        match channel {
            channel::PFR => self.pfr_enable,
            channel::PXS => self.pxs_enable,
            channel::LME => self.lme_enable,
            channel::RTC => self.rtc_enable,
            _ => false,
        }
    }
    /// Event counts since the processor was made.
    pub fn counters(&self) -> Counters {
        self.counters
    }

    /// Set P.  The instruction stack fills from there, as from the address
    /// of a branch, with the first parcel read in the clock period that is
    /// next.
    pub fn set_p(&mut self, p: u16) {
        self.p = p;
        if !self.held {
            let t = &mut self.t;
            t.refill = None;
            t.filling = true;
            t.load = p;
            (t.count, t.asked, t.ahead) = (0, 0, 0);
            t.coming = [false; CP_FETCH - 1];
        }
    }
    /// Set the accumulator.
    pub fn set_a(&mut self, a: u16) {
        self.a = a;
    }
    /// Set the carry bit.
    pub fn set_c(&mut self, c: bool) {
        self.c = c;
    }
    /// Set the B register from the low 9 bits of `b`.
    pub fn set_b(&mut self, b: u16) {
        self.b = b & D_MASK;
    }
    /// Set operand register `d`.
    pub fn set_operand(&mut self, d: usize, value: u16) {
        self.or[d] = value;
    }

    // ---- time and interrupts

    /// Let `clock_periods` pass without executing anything.  The real-time
    /// clock counts them: on reaching 234177 octal it sets its Done flag
    /// and starts again at 0 [HW 5-12].  The instruction stack goes on
    /// filling as far as it does by itself.
    pub fn advance(&mut self, clock_periods: u32) {
        let mut left = clock_periods;
        while left > 0 && !self.t.at_rest() {
            self.tick(Flow::Wait);
            left -= 1;
        }
        self.pass(left);
    }

    /// Clock periods in which nothing moves in the instruction stack.
    fn pass(&mut self, clock_periods: u32) {
        let count = self.rtc as u64 + clock_periods as u64;
        if count >= RTC_PERIOD as u64 {
            self.rtc_done = true;
        }
        self.rtc = (count % RTC_PERIOD as u64) as u32;
        self.t.now += clock_periods as u64;
    }

    /// One clock period passes: the next parcel of the instruction stack is
    /// read from Local Memory if the stack is being filled, wants one and an
    /// instruction does not have the port; a parcel read three clock periods
    /// ago can issue from the next one on; and the stream of instructions
    /// moves on as `flow` says.
    fn tick(&mut self, flow: Flow) {
        // (most clock periods of waiting: nothing but the time moves)
        if flow == Flow::Wait && self.t.at_rest() {
            self.t.now += 1;
            self.count_clock();
            return;
        }
        let read = self.read();
        self.tock(read, flow);
    }

    /// The real-time clock counts a clock period.
    fn count_clock(&mut self) {
        self.rtc += 1;
        if self.rtc == RTC_PERIOD {
            self.rtc = 0;
            self.rtc_done = true;
        }
    }

    /// The first half of a clock period: the parcel the instruction stack
    /// reads in it, if it reads one.  It is read as Local Memory holds it
    /// before an instruction that issues in this clock period, or the
    /// channel it sends a function to, has stored anything.
    fn read(&self) -> Option<u16> {
        let t = &self.t;
        let port_taken = t.port.contains(&Some(t.now));
        let read = t.filling && !port_taken && (t.load & 3 != 0 || t.asked <= STACK_AHEAD);
        read.then(|| self.mem[t.load as usize])
    }

    /// The rest of the clock period.
    fn tock(&mut self, read: Option<u16>, flow: Flow) {
        let t = &mut self.t;
        let now = t.now;
        if let Some(parcel) = read {
            t.copy[t.load as usize % STACK] = parcel;
            t.load = t.load.wrapping_add(1);
            t.count = (t.count + 1).min(STACK as u32);
            t.asked += 1;
        }
        let read = read.is_some();
        if t.coming[CP_FETCH - 2] {
            t.ahead += 1;
        }
        t.coming.rotate_right(1);
        t.coming[0] = read;
        match flow {
            Flow::Wait => {}
            Flow::Next(parcels) | Flow::InStack(parcels) => {
                t.asked -= parcels;
                t.ahead -= parcels;
            }
            Flow::Refill(request) => {
                t.filling = false;
                t.count = 0;
                t.coming = [false; CP_FETCH - 1];
                t.refill = Some(request);
            }
        }
        if t.refill == Some(now) {
            t.refill = None;
            t.filling = true;
            t.load = self.p;
            (t.count, t.asked, t.ahead) = (0, 0, 0);
            t.coming = [false; CP_FETCH - 1];
        }
        t.now = now + 1;
        self.count_clock();
    }

    /// The first clock period in which the order of the program and what is
    /// held let the instruction `f` issue (R1, R3, R4, R6 and R7 of the
    /// spec, part 8.2).
    fn earliest(&self, f: u16) -> u64 {
        let t = &self.t;
        let mut at = t.seq;
        // R3: the accumulator, free in the k clock periods the instruction gives it
        if let Some(k) = accumulator_in(f) {
            at = at.max(t.criterion.saturating_sub(k + 2));
        }
        // R4: the DP register; R6: B; R7: the memory address register
        if wants_dp(f) {
            at = at.max(t.dp_empty);
        }
        if wants_b(f) {
            at = at.max(t.b_free);
        }
        if (0o030..=0o037).contains(&f) {
            at = at.max(t.accepted.saturating_sub(1));
        }
        at
    }

    /// The instruction `parcel` at P can issue in the clock period that is
    /// next (spec part 8.2, R1 to R13).
    fn can_issue(&self, parcel: u16) -> bool {
        let t = &self.t;
        let now = t.now;
        let f = parcel >> 9;
        let parcels = if two_parcels(f) { 2 } else { 1 };
        // parcels from P on that can issue now, and in the next clock period
        let next = t.ahead + t.coming[CP_FETCH - 2] as i32;
        // R1, R3, R4, R6, R7: its turn, and what it wants free
        if now < self.earliest(f) {
            return false;
        }
        // R2: its parcels in the stack; R5: the way of DP into RP
        if t.ahead < 1 || next < parcels || (reads_register(f) && now + 1 == t.dp_empty) {
            return false;
        }
        if (0o070..=0o137).contains(&f) {
            // R10: the parcel behind the branch
            if next < parcels + 1 {
                return false;
            }
            // R8: the adder, for a branch by P; R9: a function that reads,
            // for one by an operand register
            if (relative(f) && now + 2 == t.adder) || (absolute(f) && t.input == now.checked_sub(1))
            {
                return false;
            }
            // R13: the accumulator's word of the instruction before, for a
            // branch on a condition
            if f >= 0o100 && t.late == now.checked_sub(1) {
                return false;
            }
        }
        true
    }

    /// A channel has stored in Local Memory.  If it changed a parcel the
    /// instruction stack holds, the stack is filled again from P, with the
    /// fetch request in this clock period.
    fn device_stores(&mut self) {
        if !self.t.filling {
            return;
        }
        for back in 1..=self.t.count {
            let address = self.t.load.wrapping_sub(back as u16);
            if self.mem[address as usize] != self.t.copy[address as usize % STACK] {
                self.device_store = Some(address);
                self.counters.stack_device_stores += 1;
                let now = self.t.now;
                self.tick(Flow::Refill(now));
                return;
            }
        }
    }

    /// The number `IOR : 10` reads: the highest priority (lowest numbered)
    /// channel whose Done and Interrupt Enable flags are both set
    /// [HW 5-1, 5-9].  Channel 0 has no Interrupt Enable and never
    /// requests.
    pub fn interrupt_request(&self, channels: &mut dyn Channels) -> Option<u8> {
        if self.pfr && self.pfr_enable {
            Some(channel::PFR as u8)
        } else if self.boundary && self.pxs_enable {
            Some(channel::PXS as u8)
        } else if self.rtc_done && self.rtc_enable {
            Some(channel::RTC as u8)
        } else {
            channels.interrupt()
        }
    }

    /// Execute one instruction, or take one interrupt, and return the
    /// number of clock periods (12.5 ns) from where the step began to the
    /// clock period of its issue, that one included: after a step that
    /// follows another, from the issue before to this one.  The real-time
    /// clock has counted them when `step` returns.
    ///
    /// An instruction issues when what it needs is free (spec part 8.2);
    /// until then clock periods pass.  It then does all it does at once.
    ///
    /// An interrupt is taken instead of the next instruction, in the clock
    /// period that one would issue in, when a channel requests one and
    /// System Interrupt Enable is set [HW 5-19].  After
    /// Master Clear that is the only thing that happens: the dead start is
    /// the interrupt of channel 5 at the end of the load of Local Memory
    /// [HW 5-15], which starts the program at the address in exit stack
    /// location 0, and Master Clear made that 0.  Until then a step is one
    /// idle clock period.
    pub fn step(&mut self, channels: &mut dyn Channels) -> u32 {
        let start = self.t.now;
        self.device_store = None;
        if self.stored {
            self.stored = false;
            self.device_stores();
        }
        if !self.held {
            let parcel = self.mem[self.p as usize];
            while !self.can_issue(parcel) {
                // (while nothing moves in the stack, straight to the clock
                // period the instruction waits for)
                let earliest = self.earliest(parcel >> 9);
                if earliest > self.t.now && self.t.at_rest() {
                    self.pass((earliest - self.t.now) as u32);
                } else {
                    self.tick(Flow::Wait);
                }
            }
        }
        let waited = (self.t.now - start) as u32;
        if waited != 0 {
            channels.pass(waited);
        }
        // the instruction stack reads its parcel of this clock period first
        // (unless an instruction that issues has the port for its operand)
        let now = self.t.now;
        self.asked_by = if self.rtc_done && self.rtc_enable {
            Some(channel::RTC as u8)
        } else {
            channels.interrupt()
        };
        let inside = (self.pfr && self.pfr_enable) || (self.boundary && self.pxs_enable);
        let interrupts = self.i && (inside || self.asked_by.is_some());
        let operand = (0o030..=0o037).contains(&(self.mem[self.p as usize] >> 9));
        if !interrupts && !self.held && operand {
            self.t.port[0] = Some(now);
        }
        let read = self.read();
        let flow = self.execute(channels, interrupts);
        self.tock(read, flow);
        (self.t.now - start) as u32
    }

    fn execute(&mut self, channels: &mut dyn Channels, interrupts: bool) -> Flow {
        let now = self.t.now;
        if interrupts {
            self.interrupt();
            self.t.seq = now + CP_INTERRUPT;
            self.counters.out_of_stack += 1;
            return Flow::Refill(now + CP_REQUEST);
        }
        if self.held {
            return Flow::Wait;
        }
        let parcel = self.mem[self.p as usize];
        let (f, d) = (parcel >> 9, parcel & D_MASK);
        let delayed = self.i_delayed;
        // what the clock periods of the instruction go by, as it finds it
        let register = if (0o060..=0o067).contains(&f) {
            self.b
        } else {
            d
        };
        let address = self.or[d as usize];
        let did = self.instruction(channels, f, d);
        self.counters.instructions += 1;
        // 003 takes effect late: "the System Interrupt Enable flag is
        // delayed until the next nonbranch or non-I/O instruction is
        // issued.  Instructions 40 through 43 and 70 through 137 do not
        // enable interrupts" [HW 5-20], and "a jump or exit instruction
        // must be completed before interrupts are actually set" [HW 5-19].
        // Spec part 7.3 and Q6: the flag sets at the completion of the
        // first instruction after the 003 that is not 001, 003, 040 to 043,
        // 070 to 137 or 140 to 177; 002 cancels it.
        let holds_off = matches!(f, 0o001 | 0o003 | 0o040..=0o043 | 0o070..=0o177);
        if delayed && self.i_delayed && !holds_off {
            self.i = true;
            self.i_delayed = false;
        }
        self.issued(f, register, address, did)
    }

    /// The instruction `f` has issued in the clock period that is next: what
    /// it holds from now on, when the instruction behind it may issue at the
    /// earliest, and what becomes of the instruction stack.  `register` is
    /// the operand register it names and `address` what that register held.
    fn issued(&mut self, f: u16, register: u16, address: u16, did: Did) -> Flow {
        let now = self.t.now;
        let parcels: u64 = if two_parcels(f) { 2 } else { 1 };
        let t = &mut self.t;
        // A read of an operand register in clock period 2 waits for a store
        // into the same register that is on its way through DP (it is there
        // in the clock period behind the one DP empties in), and all that
        // follows in the instruction waits with it.
        let waits = match t.dp_empty.checked_sub(now + 1) {
            Some(wait) if wait >= 1 && reads_late(f) && t.dp_register == register => wait,
            _ => 0,
        };
        // a branch by an operand register has the adder a clock period
        // later if an instruction before it has it in its clock period 3
        let adder_waits = (absolute(f) && t.adder == now + 3 + waits) as u64;
        let criterion = t.criterion;
        if let Some(free) = accumulator_free(f) {
            t.criterion = now + free + waits + 2;
        }
        if let Some(at) = adder_in(f) {
            t.adder = now + at + waits;
        }
        match f {
            0o025..=0o027 | 0o065..=0o067 => {
                t.dp_empty = now + 4;
                t.dp_register = register;
            }
            0o030..=0o034 => t.accepted = now + 4 + waits,
            0o035..=0o037 => t.accepted = now + 11 + waits,
            0o054 => t.b_free = now + 3,
            0o055..=0o057 => t.b_free = now + 4,
            _ => {}
        }
        if input(f) {
            t.input = Some(now);
        }
        if matches!(f, 0o030..=0o033 | 0o035..=0o037) || input(f) {
            t.late = Some(now);
        }
        // the port into Local Memory: the operand is read in the clock
        // period of the issue, a result is stored two behind it
        let stores = (0o034..=0o037).contains(&f);
        if (0o030..=0o037).contains(&f) {
            t.port[1] = stores.then_some(now + 2);
        }
        // a conditional branch: what follows it waits for the criterion
        let behind = |at: u64| if f >= 0o100 { at.max(criterion) } else { at };
        let (seq, flow) = match did {
            // a store into a parcel the stack holds or is about to read
            Did::Plain
                if stores && t.filling && (t.load.wrapping_sub(address) as u32) <= t.count =>
            {
                self.counters.stack_stores += 1;
                let request = now + CP_REQUEST_STORE;
                (request + CP_REQUEST_TO_ISSUE, Flow::Refill(request))
            }
            Did::Plain if (0o040..=0o043).contains(&f) => (now + CP_FLAG_TEST, Flow::Next(1)),
            Did::Plain => (now + parcels, Flow::Next(parcels as i32)),
            Did::NotTaken => (behind(now + parcels), Flow::Next(parcels as i32)),
            Did::Exit => {
                self.counters.out_of_stack += 1;
                let request = now + CP_REQUEST_EXIT;
                (request + CP_REQUEST_TO_ISSUE, Flow::Refill(request))
            }
            // In the stack: no farther forward than the last parcel that is
            // asked for or will be, no farther back than the stack will
            // reach then: the parcels to come take the places of the oldest.
            Did::Relative(forward)
                if t.filling
                    && forward < t.asked + t.to_come(parcels as i32)
                    && -forward
                        <= (t.count as i32).min(STACK as i32 - t.to_come(parcels as i32))
                            - t.asked =>
            {
                self.counters.in_stack += 1;
                (behind(now + CP_IN_STACK), Flow::InStack(forward))
            }
            Did::Relative(_) | Did::Absolute => {
                self.counters.out_of_stack += 1;
                let request = now
                    + CP_REQUEST
                    + if did == Did::Absolute {
                        waits + adder_waits
                    } else {
                        0
                    };
                (behind(request + CP_REQUEST_TO_ISSUE), Flow::Refill(request))
            }
        };
        t.seq = seq;
        flow
    }

    /// The interrupt sequence [HW 5-19]: clear System Interrupt Enable,
    /// advance E, store the address of the next instruction of the
    /// interrupted program there, and go on at the address in exit stack
    /// location 0, which is read without E.  An interrupt that takes E to
    /// 14 does not set the Exit Stack Boundary flag [HW 3-10].  A delayed
    /// 003 stays pending and enables interrupts inside the handler, which
    /// is why a handler begins with 002 [HW 5-19].
    fn interrupt(&mut self) {
        self.i = false;
        self.e = (self.e + 1) & E_MASK;
        self.xs[self.e as usize] = self.p;
        self.p = self.xs[0];
        self.held = false;
        self.counters.interrupts += 1;
    }

    // ---- arithmetic

    /// The 17-bit value of carry and accumulator.
    fn ca(&self) -> u32 {
        (self.c as u32) << 16 | self.a as u32
    }
    fn set_ca(&mut self, ca: u32) {
        self.a = ca as u16;
        self.c = ca & 1 << 16 != 0;
    }
    /// A load clears the carry.
    fn load(&mut self, x: u16) {
        self.a = x;
        self.c = false;
    }
    /// A logical product clears the carry.
    fn and(&mut self, x: u16) {
        self.a &= x;
        self.c = false;
    }
    /// Add: the carry is complemented, not set, if a carry is propagated
    /// from the accumulator [HW 6-13].
    fn add(&mut self, x: u16) {
        self.set_ca(self.ca() + x as u32);
    }
    /// Subtract: add the complement, then add 1; the carry is complemented
    /// if either addition carries [HW 6-14], that is whenever the
    /// accumulator is not below the operand [HW 4-2].
    fn sub(&mut self, x: u16) {
        self.set_ca(self.ca() + !x as u32 + 1);
    }

    /// 004 to 007 and 044 to 047: shift carry and accumulator as one 17-bit
    /// register.  The low 5 bits of d or B are the count [HW 6-7]; cray-sim
    /// uses the whole value for end-off shifts (spec Q5).  An end-off shift
    /// of more than 16 places clears both.  A circular shift of 18 to 31
    /// places turns the 17 bits by the count modulo 17 (spec Q4; the manual
    /// does not say).
    fn shift(&mut self, f: u16, count: u16) {
        if count > 17 {
            self.counters.long_shifts += 1;
        }
        let n = (count & 0o37) as u32;
        let ca = self.ca();
        let r = n % 17;
        let ca = match f & 3 {
            0 if n > 16 => 0,
            0 => ca >> n,
            1 if n > 16 => 0,
            1 => ca << n,
            2 => ca >> r | ca << (17 - r),
            _ => ca << r | ca >> (17 - r),
        };
        self.set_ca(ca & 0x1_FFFF);
    }

    /// The eight operations that the groups 020, 030, 050 and 060 perform
    /// with their operand, selected by the low three bits of f: load,
    /// logical product, add, subtract, store, add and store, increment,
    /// decrement.  Returns the value that goes back to the operand, if any.
    ///
    /// Increment and decrement clear the carry, enter 1 or all ones in the
    /// accumulator and add the operand, so the result is also left in the
    /// accumulator, and after a decrement the carry is set whenever the
    /// operand was not zero [HW 6-25, 6-26].
    fn operate(&mut self, f: u16, x: u16) -> Option<u16> {
        match f & 7 {
            0 => self.load(x),
            1 => self.and(x),
            2 => self.add(x),
            3 => self.sub(x),
            4 => {}
            5 => self.add(x),
            6 => {
                self.load(1);
                self.add(x);
            }
            _ => {
                self.load(0xFFFF);
                self.add(x);
            }
        }
        (f & 4 != 0).then_some(self.a)
    }

    // ---- the program exit stack

    /// A return jump advances E and stores the return address at the new
    /// location.  The Exit Stack Boundary flag sets if the advanced E is 14
    /// [HW 6-65]; the manual says so for 076 and 077 only, and it is done
    /// for every return jump (spec Q3).  From 15, E wraps to 0 and the
    /// address of the interrupt handler is lost [HW 3-9].
    fn push_return(&mut self, address: u16) {
        self.e = (self.e + 1) & E_MASK;
        self.xs[self.e as usize] = address;
        if self.e == 14 {
            self.set_boundary();
        }
    }

    fn set_boundary(&mut self) {
        self.boundary = true;
        self.counters.boundary_flags += 1;
    }

    /// 001: P comes from the exit stack location E points at, then E is
    /// decremented.  If E was 0 the decrement is blocked and the Exit Stack
    /// Boundary flag sets [HW 6-4]; cray-sim lets E wrap to 15.  The
    /// program then goes on at the address in location 0, the interrupt
    /// handler, with E still 0 [HW 3-9, 3-10].  Nothing is pushed and
    /// System Interrupt Enable is left alone (spec Q1, Q2), so if the flag
    /// may interrupt, the ordinary interrupt sequence follows.
    fn exit(&mut self) {
        self.p = self.xs[self.e as usize];
        if self.e == 0 {
            self.set_boundary();
        } else {
            self.e -= 1;
        }
    }

    // ---- instructions

    /// Execute the instruction with operation code `f` and field `d` at P;
    /// returns what it did to the order of the program.
    fn instruction(&mut self, channels: &mut dyn Channels, f: u16, d: u16) -> Did {
        let p = self.p;
        // the second parcel of a 2-parcel instruction
        let k = self.mem[p.wrapping_add(1) as usize];
        let mut next = p.wrapping_add(1);
        match f {
            // PASS; d is ignored (the kernel keeps halt codes there)
            0o000 => {}
            // EXIT
            0o001 => {
                self.exit();
                return Did::Exit;
            }
            // I = 0; it also cancels a 003 that has not taken effect
            // [HW 6-6]
            0o002 => {
                self.i = false;
                self.i_delayed = false;
            }
            // I = 1, delayed: see `execute`
            0o003 => self.i_delayed = true,
            0o004..=0o007 => self.shift(f, d),
            // A with d
            0o010..=0o013 => {
                self.operate(f & 3, d);
            }
            // A with k
            0o014..=0o017 => {
                self.operate(f & 3, k);
                next = p.wrapping_add(2);
            }
            // A with operand register d
            0o020..=0o027 => {
                let r = d as usize;
                if let Some(result) = self.operate(f, self.or[r]) {
                    self.or[r] = result;
                }
            }
            // A with the parcel of memory that operand register d addresses
            0o030..=0o037 => {
                let m = self.or[d as usize] as usize;
                if let Some(result) = self.operate(f, self.mem[m]) {
                    self.mem[m] = result;
                }
            }
            // C = Done or Busy of channel d (040, 041) or channel B (042,
            // 043)
            0o040..=0o043 => {
                let n = if f < 0o042 { d } else { self.b };
                self.c = self.flag(channels, n, f & 1 != 0);
            }
            0o044..=0o047 => self.shift(f, self.b),
            // A with B; B takes the low 9 bits of a result
            0o050..=0o057 => {
                if let Some(result) = self.operate(f, self.b) {
                    self.b = result & D_MASK;
                }
            }
            // A with operand register B
            0o060..=0o067 => {
                let r = self.b as usize;
                if let Some(result) = self.operate(f, self.or[r]) {
                    self.or[r] = result;
                }
            }
            0o070..=0o137 => return self.branch(f, d, k),
            // 140 to 157: function f bits 3 to 0 on channel d; 160 to 177:
            // on channel B
            _ => {
                let n = if f < 0o160 { d } else { self.b };
                self.function(channels, n, f & 0o17);
            }
        }
        self.p = next;
        Did::Plain
    }

    /// 070 to 137.  The branch mode is f bits 2 to 0 of 070 to 077 and
    /// f bits 4 to 2 of 100 to 137: P + d, P - d, return jump to P + d,
    /// return jump to P - d, operand register d, operand register d + k,
    /// and the return jumps to the last two.  The condition of 100 to 137
    /// is f bits 1 to 0: C = 0, C # 0, A = 0, A # 0 [HW 6-67].  P in these
    /// sums is the address of the branch itself, d is a 9-bit positive
    /// number and all sums are modulo 2**16 [HW 6-59].  A and the carry do
    /// not change.
    fn branch(&mut self, f: u16, d: u16, k: u16) -> Did {
        let p = self.p;
        let mode = if f < 0o100 { f & 7 } else { f >> 2 & 7 };
        let taken = f < 0o100
            || match f & 3 {
                0 => !self.c,
                1 => self.c,
                2 => self.a == 0,
                _ => self.a != 0,
            };
        let two_parcels = mode & 5 == 5;
        debug_assert_eq!(two_parcels, self::two_parcels(f));
        let next = p.wrapping_add(if two_parcels { 2 } else { 1 });
        if !taken {
            // "the next instruction in the current program sequence can
            // issue in the next CP" [HW 6-67]; k has to pass as well
            self.p = next;
            return Did::NotTaken;
        }
        let (target, did) = match mode {
            0 | 2 => (p.wrapping_add(d), Did::Relative(d as i32)),
            1 | 3 => (p.wrapping_sub(d), Did::Relative(-(d as i32))),
            _ => {
                // The Program Fetch Request flag sets when operand register
                // d holds zero, and the register of channel 1 takes d
                // [HW 3-11, 5-9].  Not when a conditional branch is not
                // taken (spec Q7).  The branch still completes; the
                // interrupt, if channel 1 may interrupt, comes after it
                // (spec Q8).
                let base = self.or[d as usize];
                if base == 0 {
                    self.pfr = true;
                    self.pfr_register = d;
                }
                (
                    base.wrapping_add(if two_parcels { k } else { 0 }),
                    Did::Absolute,
                )
            }
        };
        if mode & 2 != 0 {
            self.push_return(next);
        }
        self.p = target;
        did
    }

    // ---- channels

    /// The Busy (`busy`) or Done flag of channel `n` for 040 to 043.  A
    /// number above 47 octal has no channel and reads as an empty one: both
    /// flags clear (spec Q9).
    fn flag(&mut self, channels: &mut dyn Channels, n: u16, busy: bool) -> bool {
        if n == channel::PFR {
            self.counters.pfr_channel += 1;
        }
        match n {
            // channels 0 to 4 have no Busy flag; channel 0 is always Done
            // [HW 5-9]
            0..=4 => !busy && self.done(n),
            5..CHANNELS if busy => channels.busy(n as u8),
            5..CHANNELS => channels.done(n as u8),
            _ => false,
        }
    }

    /// 140 to 177: send a function and the accumulator to channel `n`.
    /// Functions 10 to 13 replace the accumulator with what the channel
    /// returns [HW 6-69] and clear the carry (spec Q10); the others leave
    /// both alone.  The processor never waits for a channel.  A function
    /// that a channel does not have does nothing and reads zero, and so
    /// does every function of a channel number above 47 octal (spec Q9).
    fn function(&mut self, channels: &mut dyn Channels, n: u16, function: u16) {
        let value = match n {
            channel::IOR => self.ior(channels, function),
            channel::PFR => self.pfr_function(function),
            channel::PXS => self.pxs(function),
            channel::LME => self.lme(function),
            channel::RTC => self.rtc_function(function),
            5..CHANNELS => {
                // the channel may move data by itself
                self.stored = true;
                channels
                    .function(&mut self.mem, n as u8, function as u8, self.a)
                    .unwrap_or(0)
            }
            _ => 0,
        };
        if (0o10..=0o13).contains(&function) {
            self.load(value);
        }
    }

    /// Channel 0, interrupt request.  `IOR : 10` reads the number of the
    /// highest priority channel that requests an interrupt, zero if there
    /// is none, whether or not System Interrupt Enable is set [HW 5-9].
    fn ior(&mut self, channels: &mut dyn Channels, function: u16) -> u16 {
        match function {
            0o10 => self.interrupt_request(channels).map_or(0, u16::from),
            _ => 0,
        }
    }

    /// Channel 1, program fetch request [HW 5-9, 5-10].
    fn pfr_function(&mut self, function: u16) -> u16 {
        self.counters.pfr_channel += 1;
        match function {
            0 => self.pfr = false,
            6 => self.pfr_enable = false,
            7 => self.pfr_enable = true,
            // reading the register clears the flag as well [HW 5-10]; in
            // cray-sim it does not
            0o10 => {
                self.pfr = false;
                return self.pfr_register;
            }
            _ => {}
        }
        0
    }

    /// Channel 2, program exit stack [HW 5-10].  The functions act at once;
    /// the real machine needs 5 clock periods before the stack is used
    /// again, which programs spend in three circular shifts of 17 places
    /// [HW 5-11].
    fn pxs(&mut self, function: u16) -> u16 {
        match function {
            0 => self.boundary = false,
            6 => self.pxs_enable = false,
            7 => self.pxs_enable = true,
            0o10 => return self.e as u16,
            0o11 => return self.xs[self.e as usize],
            0o14 => self.e = self.a as u8 & E_MASK,
            0o15 => self.xs[self.e as usize] = self.a,
            _ => {}
        }
        0
    }

    /// Channel 3, Local Memory error [HW 5-12].  The memory of the model
    /// has no errors: the flag never sets and `LME : 10` reads zero.
    fn lme(&mut self, function: u16) -> u16 {
        match function {
            6 => self.lme_enable = false,
            7 => self.lme_enable = true,
            _ => {}
        }
        0
    }

    /// Channel 4, real-time clock [HW 5-12, 5-13].  `RTC : 10` reads the
    /// upper 16 of the counter's 17 bits: 0 to 116077 octal, in units of
    /// two clock periods.
    fn rtc_function(&mut self, function: u16) -> u16 {
        match function {
            0 => self.rtc_done = false,
            6 => self.rtc_enable = false,
            7 => self.rtc_enable = true,
            0o10 => return (self.rtc >> 1) as u16,
            _ => {}
        }
        0
    }
}
