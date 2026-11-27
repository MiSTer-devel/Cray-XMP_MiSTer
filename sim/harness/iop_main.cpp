// The I/O Processor (rtl/ios/iop_cpu.v) against a record of the reference
// model's steps.
//
//   Viop_cpu RECORD [--quiet]
//
// RECORD is what tools/crates/ios/src/replay.rs writes (the format is
// described there): Local Memory, then for every step what the channels
// answered, what the registers held afterwards and how many clocks behind
// the step before it issued.  The processor is given the same memory and the
// same answers and must take the same interrupts, send the same functions,
// issue every step in the same clock and have the same registers behind it;
// at the end its memory, operand registers and exit stack must be the
// model's.
//
// A step is looked at in the clock after its issue.  The word an operand in
// Local Memory, a function that reads or a flag test brings is in the
// accumulator a clock later than that, and is looked at then: the next step
// may have issued meanwhile, but none that touches the accumulator can.
// What a device stored by itself is put into memory between two steps; if
// the model's instruction stack held the parcel, the processor is told of
// the store in the first clock behind the step, as a channel would tell it.
// Before the end, and before a Master Clear, the processor is held for a few
// clocks so that what is under way lands.
// Exit status: 0 if it did, 1 at the first difference, 2 for a bad record.
#include "Viop_cpu.h"
#include "Viop_cpu___024root.h"
#include "verilated.h"

#include <cstdint>
#include <cstdio>
#include <cstring>
#include <string>
#include <vector>

enum { INSTRUCTION, INTERRUPT, SET_MEMORY, MASTER_CLEAR, CHECK_MEMORY, CHECK_OPERAND, CHECK_EXIT_STACK, END, SET_OPERAND, SET_REGISTERS, IDLE };

struct Record {
    uint8_t kind, request;
    uint16_t p, parcel, channel, a_before, value, p_after, a_after, b_after;
    uint8_t e_after, flags_after;
    uint16_t clocks, stored_at;
    bool stored;
};

static bool read_record(FILE *f, Record &r) {
    uint8_t b[24];
    if (fread(b, 1, sizeof b, f) != sizeof b) return false;
    auto w = [&](int n) { return (uint16_t)(b[n] | b[n + 1] << 8); };
    r = {b[0], b[1], w(2), w(4), w(6), w(8), w(10), w(12), w(14), w(16), (uint8_t)(b[18] & 15), b[19], w(20), w(22), (bool)(b[18] >> 7)};
    return true;
}

int main(int argc, char **argv) {
    Verilated::commandArgs(argc, argv);
    std::string path;
    bool quiet = false;
    for (int i = 1; i < argc; i++) {
        std::string a = argv[i];
        if (a == "--quiet") quiet = true;
        else path = a;
    }
    FILE *f = path.empty() ? nullptr : fopen(path.c_str(), "rb");
    if (!f) { fprintf(stderr, "cannot read record '%s'\n", path.c_str()); return 2; }

    std::vector<uint16_t> mem(1 << 16, 0);
    Viop_cpu *top = new Viop_cpu;
    auto *in = top->rootp;
    top->clk = 0; top->rst = 1;
    top->i_mem_rdata = 0; top->i_data = 0; top->i_busy = 0; top->i_done = 0; top->i_request = 0;
    top->eval();

    long clocks = 0, steps = 0, interrupts = 0, functions = 0, checked = 0;
    Record now{};                   // the step under way, or the last one
    bool ended = false, settled = true;
    // the accumulator and the carry of a step whose word came a clock late
    bool late = false; unsigned late_a = 0, late_c = 0;

    top->i_store = 0; top->i_store_addr = 0; top->i_hold = 0;
    auto clock = [&]() {
        uint16_t addr = top->o_mem_addr, wdata = top->o_mem_wdata; bool we = top->o_mem_we;
        top->clk = 1; top->eval();
        if (we) mem[addr] = wdata;
        top->i_mem_rdata = mem[addr];
        top->eval();
        top->clk = 0; top->eval();
        clocks++;
        // (a check in the hardware description itself has spoken)
        if (Verilated::gotFinish()) { printf("after %ld steps the processor's own check stops it\n", steps); exit(1); }
    };
    auto fail = [&](const char *what, unsigned got, unsigned want) {
        printf("step %ld (P %04x, parcel %06o%s): %s is %x, the model has %x\n", steps + 1, now.p, now.parcel,
               now.kind == INTERRUPT ? ", an interrupt" : "", what, got, want);
        return 1;
    };
    auto came_late = [&]() {
        if (!late) return 0;
        late = false;
        steps--;        // (the message names the step before)
        if (top->o_a != late_a) return fail("A, a clock after", top->o_a, late_a);
        if ((top->o_flags & 1u) != late_c) return fail("the carry, a clock after", top->o_flags & 1, late_c);
        steps++;
        return 0;
    };
    // hold the processor until what is under way has landed
    auto settle = [&]() {
        if (settled) return 0;
        settled = true;
        top->i_hold = 1; top->eval();
        for (int n = 0; n < 4; n++) {
            clock();
            if (int bad = came_late()) return bad;
            if (top->o_step || top->o_strobe) { printf("after %ld steps the processor goes on while it is held\n", steps); return 1; }
        }
        return 0;
    };

    // registers that keep their value over Master Clear start as the model's: zero
    in->iop_cpu__DOT__a = 0; in->iop_cpu__DOT__b = 0; in->iop_cpu__DOT__c = 0;
    for (int i = 0; i < 512; i++) in->iop_cpu__DOT__or_mem[i] = 0;
    for (int i = 0; i < 4; i++) clock();

    while (!ended) {
        Record r;
        if (!read_record(f, r)) { printf("the record ends without its end\n"); return 2; }
        switch (r.kind) {
        // A device stored this by itself, in the model at once.
        case SET_MEMORY: mem[r.p] = r.parcel; break;
        case SET_OPERAND: in->iop_cpu__DOT__or_mem[r.p & 511] = r.parcel; break;
        case SET_REGISTERS: in->iop_cpu__DOT__a = r.p; in->iop_cpu__DOT__b = r.parcel & 0777; in->iop_cpu__DOT__c = r.parcel >> 15; break;
        case MASTER_CLEAR:
            if (int bad = settle()) return bad;
            top->rst = 1; clock(); clock();
            break;
        case IDLE:
            // held by Master Clear with no channel asking: nothing may happen
            top->rst = 0; top->i_hold = 0; top->i_request = 0; top->eval();
            for (int n = 0; n < r.p; n++) {
                clock();
                if (top->o_step || top->o_strobe || top->o_mem_we) { printf("after %ld steps the processor does something while Master Clear holds it\n", steps); return 1; }
            }
            break;
        case CHECK_MEMORY:
            if (int bad = settle()) return bad;
            checked++;
            if (mem[r.p] != r.parcel) { printf("at the end Local Memory %04x is %04x, the model has %04x\n", r.p, mem[r.p], r.parcel); return 1; }
            break;
        case CHECK_OPERAND:
            if (int bad = settle()) return bad;
            checked++;
            if (in->iop_cpu__DOT__or_mem[r.p & 511] != r.parcel) { printf("at the end operand register %o is %04x, the model has %04x\n", r.p, in->iop_cpu__DOT__or_mem[r.p & 511], r.parcel); return 1; }
            break;
        case CHECK_EXIT_STACK:
            if (int bad = settle()) return bad;
            checked++;
            {
                // a location that has not been written since Master Clear reads zero
                unsigned at = r.p & 15;
                unsigned holds = ((in->iop_cpu__DOT__xs_set >> at) & 1) ? in->iop_cpu__DOT__xs[at] : 0;
                if (holds != r.parcel) { printf("at the end exit stack location %o is %04x, the model has %04x\n", r.p, holds, r.parcel); return 1; }
            }
            break;
        case END:
            if (int bad = settle()) return bad;
            ended = true;
            break;
        case INSTRUCTION: case INTERRUPT: {
            now = r; settled = false;
            unsigned fn = r.parcel >> 9;
            top->rst = 0; top->i_hold = 0;
            top->i_request = r.request;
            // a device stored into a parcel the instruction stack holds
            top->i_store = r.stored; top->i_store_addr = r.stored_at;
            bool strobed = false;
            int waited = 0;
            for (;;) {
                top->eval();
                // a function goes out in the clock of its issue
                bool strobe = top->o_strobe;
                unsigned s_channel = top->o_channel, s_function = top->o_function, s_a = top->o_a;
                clock();
                waited++;
                top->i_store = 0;
                if (int bad = came_late()) return bad;
                if (strobe) {
                    functions++;
                    strobed = true;
                    if (!top->o_step || r.kind != INSTRUCTION) return fail("a function sent, on channel", s_channel, 0);
                    if (s_channel != r.channel) return fail("the channel of the function", s_channel, r.channel);
                    if (s_function != (fn & 017)) return fail("the function", s_function, fn & 017);
                    if (s_a != r.a_before) return fail("the accumulator sent", s_a, r.a_before);
                }
                if (top->o_step) break;
                if (waited > 200) return fail("clocks without the issue of the step", waited, r.clocks);
            }
            // the step issued in the clock that has just ended
            if ((bool)top->o_step_interrupt != (r.kind == INTERRUPT)) return fail("interrupt taken", top->o_step_interrupt, r.kind == INTERRUPT);
            bool outside = r.kind == INSTRUCTION && r.channel >= 4 && r.channel < 050;
            bool sends = outside && fn >= 0140;
            if (sends != strobed) return fail("function sent", strobed, sends);
            if (waited != r.clocks) return fail("the clocks from the issue before to its own", waited, r.clocks);
            if (top->o_p != r.p_after) return fail("P", top->o_p, r.p_after);
            if (top->o_b != r.b_after) return fail("B", top->o_b, r.b_after);
            if (top->o_e != r.e_after) return fail("E", top->o_e, r.e_after);
            if ((top->o_flags >> 1) != (r.flags_after >> 1)) return fail("the flags (held, boundary, fetch request, I delayed, I)", top->o_flags >> 1, r.flags_after >> 1);
            // the accumulator and the carry: now, or a clock later when the
            // word is one from Local Memory or from a channel outside
            bool from_memory = r.kind == INSTRUCTION && fn >= 030 && fn <= 037;
            bool from_channel = outside && ((fn >= 040 && fn <= 043) || (sends && (fn & 014) == 010));
            if (from_memory || from_channel) { late = true; late_a = r.a_after; late_c = r.flags_after & 1; }
            else {
                if (top->o_a != r.a_after) return fail("A", top->o_a, r.a_after);
                if ((top->o_flags & 1u) != (r.flags_after & 1u)) return fail("the carry", top->o_flags & 1, r.flags_after & 1);
            }
            // what the channels answer, in the clock after the issue.  A flag
            // test is given the flag it found and the opposite on the other line.
            bool busy_test = fn & 1;
            top->i_data = r.value;
            top->i_busy = busy_test ? (r.value & 1) : !(r.value & 1);
            top->i_done = busy_test ? !(r.value & 1) : (r.value & 1);
            steps++;
            if (r.kind == INTERRUPT) interrupts++;
            break;
        }
        default: printf("record kind %d\n", r.kind); return 2;
        }
    }
    if (!quiet || steps == 0)
        printf("%ld steps (%ld interrupts, %ld functions) in %ld clocks, %ld values checked at the end: as the model\n",
               steps, interrupts, functions, clocks, checked);
    top->final();
    delete top;
    return steps > 0 ? 0 : 2;
}
