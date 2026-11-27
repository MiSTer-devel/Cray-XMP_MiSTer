// The port to DDR3 (rtl/mister/ddr3_ports.sv) against what it promises.
//
//   Vddr3_ports_tb [CASES] [--seed N]
//
// Five users ask for words to be read and written, as the core's do: user 0
// one request behind the other, each presented until it is taken, reads of 1
// to 16 words and now and then more, many of them of a whole 16-word line
// marked as code, as the instruction buffers read; the others one request at a time, held
// until its last acknowledge.  Most addresses lie in a small window, so that
// reads meet words that were written a moment ago and lines that were read
// before are read again and written into.  The bridge is the
// stand-in of the core's simulation (ddram_model.h), with its times drawn for
// each case.
//
// A request is carried out when it is taken.  So every word read must be
// what the requests taken before it left in memory, the words must come to
// the user that asked, in the order it asked, one an acknowledge; a write is
// acknowledged once, in the clock after it is taken; and when all is quiet
// the DDR3 holds what the writes left.  User 0 is reset now and then: what
// it was still to be given must not come, and what it wrote stays written.
#include "Vddr3_ports_tb.h"
#include "verilated.h"

#include "ddram_model.h"

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <deque>
#include <random>
#include <vector>

static const int N = 5;

template <class T> static void put(T &wide, int at, int bits, uint64_t v) {
    for (int i = 0; i < bits; i++) {
        int b = at + i;
        uint32_t m = 1u << (b & 31);
        if ((v >> i) & 1) wide[b >> 5] |= m; else wide[b >> 5] &= ~m;
    }
}

struct User {
    bool asking = false, taken = false;   // a request is presented; (a holder's) it has been taken
    bool we = false, code = false; uint32_t addr = 0; int len = 1; uint64_t wdata = 0;
    int to_come = 0;                      // acknowledges a holder still waits for
    std::deque<uint64_t> expect;          // the words of reads taken, in order
    long since = 0;                       // clocks the request has been presented
    int pause = 0;
};

int main(int argc, char **argv) {
    Verilated::commandArgs(argc, argv);
    int cases = 200; unsigned seed = 1;
    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "--seed") && i + 1 < argc) seed = atoi(argv[++i]);
        else cases = atoi(argv[i]);
    }
    std::mt19937_64 rng(seed);
    auto pick = [&](long a, long b) { return a + (long)(rng() % (uint64_t)(b - a + 1)); };
    long n_reads = 0, n_words = 0, n_writes = 0, n_resets = 0, failures = 0;

    for (int c = 0; c < cases; c++) {
        auto *top = new Vddr3_ports_tb;
        const uint32_t WORDS = 1u << 14;
        DdramModel ddr((size_t)WORDS * 8, (uint32_t)rng());
        int kind = (int)pick(0, 5);
        ddr.prof.lat_min = (int)pick(1, 20); ddr.prof.lat_max = ddr.prof.lat_min + (int)pick(0, 6);
        ddr.prof.busy_pct = kind == 0 ? 0 : (int)pick(0, 60);
        ddr.prof.gap_pct = (int)pick(0, 2) ? 0 : (int)pick(1, 30);
        ddr.prof.stall_pct_x1000 = (int)pick(0, 3) ? 0 : (int)pick(100, 3000);
        // where the requests go: a window that is small, and how often outside it
        uint32_t win = (uint32_t)pick(8, 600), base = (uint32_t)pick(0, WORDS - 700), far_pct = (uint32_t)pick(0, 20);
        int write_pct = (int)pick(5, 80), idle_pct = (int)pick(0, 70), long_pct = (int)pick(0, 4);
        int line_pct = (int)pick(0, 3) ? (int)pick(10, 90) : 0;     // of user 0's reads: whole lines
        long clocks = pick(2000, 12000);

        std::vector<uint64_t> ref(WORDS);
        for (uint32_t w = 0; w < WORDS; w++) ref[w] = ddr.word(w);

        bool failed = false;
        long now = 0;
        auto fail = [&](const char *what, int user) {
            if (!failed) printf("case %d (seed %u) at clock %ld, user %d: %s\n", c, seed, now, user, what);
            failed = true;
        };

        User u[N];
        bool held = false; int held_left = 0;    // user 0 is being reset
        top->clk = 0; top->reset = 1;
        top->req = 0; top->we = 0; top->code = 0; top->len = 0; top->user_rst = 0;
        for (int i = 0; i < 4; i++) top->addr[i] = 0;
        for (int i = 0; i < 10; i++) top->wdata[i] = 0;
        top->DDRAM_BUSY = 0; top->DDRAM_DOUT_READY = 0; top->DDRAM_DOUT = 0;
        top->eval();

        auto new_request = [&](int n) {
            User &x = u[n];
            x.we = pick(0, 99) < write_pct;
            x.len = 1;
            if (!x.we) {
                if (n == 0) x.len = pick(0, 99) < long_pct ? (int)pick(17, 64) : (int)pick(0, 2) ? 1 : (int)pick(1, 16);
                else x.len = (int)pick(0, 5) ? 1 : (int)pick(1, 3);
            }
            x.addr = (uint32_t)pick(0, 99) < far_pct ? (uint32_t)pick(0, WORDS - 65) : base + (uint32_t)pick(0, win);
            // (of the whole lines most are marked as code, and so is a read now and then that is none)
            x.code = false;
            if (n == 0 && !x.we && pick(0, 99) < line_pct) { x.addr &= ~15u; x.len = 16; x.code = pick(0, 9) != 0; }
            else if (!x.we && pick(0, 19) == 0) x.code = true;
            x.wdata = rng();
            x.asking = true; x.taken = false; x.since = 0;
        };
        auto drive = [&]() {
            uint32_t req = 0, we = 0, code = 0; uint64_t len = 0;
            for (int n = 0; n < N; n++) {
                User &x = u[n];
                if (!x.asking) continue;
                req |= 1u << n;
                if (x.we) we |= 1u << n;
                if (x.code) code |= 1u << n;
                len |= (uint64_t)x.len << (7 * n);
                put(top->addr, 25 * n, 25, x.addr);
                put(top->wdata, 64 * n, 64, x.wdata);
            }
            top->req = req; top->we = we; top->code = code; top->len = len; top->user_rst = held ? 1 : 0;
        };

        long reset_left = 5, quiet = 0;
        bool stopping = false;
        long limit = clocks + 60000;
        while (!failed) {
            const bool edge_u = true, edge_m = true;
            if (edge_m) {
                // the bridge: what the port drove in the clock that ends
                ddr.step(top->DDRAM_RD, top->DDRAM_WE, top->DDRAM_ADDR, top->DDRAM_BURSTCNT, top->DDRAM_DIN, top->DDRAM_BE);
                if (ddr.bad_access) fail("an address outside the memory", -1);
            }
            if (edge_u) {
                // the users: what the port said in the clock that ends
                uint32_t take = top->take, ack = top->ack; uint64_t rdata = top->rdata;
                if (take & (take - 1)) fail("two requests taken in one clock", -1);
                if ((take & 1) != ((top->req & 1) && top->free0)) fail("user 0 is not told rightly whether its request is taken", 0);
                for (int n = 0; n < N; n++) {
                    User &x = u[n];
                    if ((ack >> n) & 1) {
                        if (n == 0 && held) { /* on its way when the reset came */ }
                        else if (n != 0 && x.we && x.taken && x.to_come == 1) x.to_come = 0;
                        else if (x.expect.empty()) fail("a word nobody asked for", n);
                        else {
                            if (x.expect.front() != rdata) {
                                if (!failed) printf("  read %016llx, should be %016llx\n", (unsigned long long)rdata, (unsigned long long)x.expect.front());
                                fail("a word read is not what was written", n);
                            }
                            x.expect.pop_front();
                            if (n != 0) x.to_come--;
                        }
                        if (n != 0 && x.taken && x.to_come == 0) { x.asking = false; x.taken = false; x.pause = pick(0, 99) < idle_pct ? (int)pick(1, 40) : 0; }
                    }
                    if ((take >> n) & 1) {
                        if (!x.asking || (n != 0 && x.taken)) fail("a request taken that was not presented", n);
                        if (n == 0 && held) fail("a request of a user under reset taken", n);
                        if (x.we) { ref[x.addr] = x.wdata; n_writes++; }
                        else {
                            for (int i = 0; i < x.len; i++) x.expect.push_back(ref[x.addr + i]);
                            n_reads++; n_words += x.len;
                        }
                        if (n == 0) { x.asking = false; x.pause = pick(0, 99) < idle_pct ? (int)pick(1, 12) : 0; }
                        else { x.taken = true; x.to_come = x.we ? 1 : x.len; }
                    }
                    if (x.asking && ++x.since > 40000) fail("a request waits and waits", n);
                }
            }
            top->clk = 1;
            top->eval();
            top->clk = 0;
            top->eval();
            if (edge_m) {
                top->DDRAM_BUSY = ddr.busy; top->DDRAM_DOUT_READY = ddr.dout_ready; top->DDRAM_DOUT = ddr.dout;
            }
            if (edge_u) {
                now++;
                if (reset_left && --reset_left == 0) top->reset = 0;
                if (!top->reset) {
                    stopping = now > clocks;
                    // user 0's reset: it asks for nothing, and what was to come is forgotten
                    if (held) { if (--held_left == 0) held = false; }
                    else if (!stopping && pick(0, 2999) == 0) {
                        held = true; held_left = (int)pick(3, 30); n_resets++;
                        u[0].asking = false; u[0].expect.clear();
                    }
                    bool busy = false;
                    for (int n = 0; n < N; n++) {
                        User &x = u[n];
                        if (!x.asking && !(n == 0 && held)) {
                            if (x.pause) x.pause--;
                            else if (!stopping) new_request(n);
                        }
                        if (x.asking || !x.expect.empty()) busy = true;
                    }
                    quiet = busy ? 0 : quiet + 1;
                }
                drive();
            }
            top->eval();
            // all is quiet for long enough that the writes that waited have gone
            if (stopping && quiet > 3000) break;
            if (now > limit) fail("the port does not come to rest", -1);
        }
        if (!failed)
            for (uint32_t w = 0; w < WORDS; w++)
                if (ddr.word(w) != ref[w]) {
                    printf("  word %u holds %016llx, should hold %016llx\n", w, (unsigned long long)ddr.word(w), (unsigned long long)ref[w]);
                    fail("the DDR3 does not hold what was written", -1);
                    break;
                }
        if (failed) failures++;
        top->final();
        delete top;
    }
    printf("%d cases: %ld reads of %ld words, %ld writes, %ld resets of a user, %ld failed\n", cases, n_reads, n_words, n_writes, n_resets, failures);
    return failures ? 1 : 0;
}
