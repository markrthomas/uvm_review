// Verilator coverage harness for the full axi_apb_mem subsystem.
//
// Drives the integrated dual-bus top (native APB3 + AXI4-Lite front end + the
// PCLK-domain arbiter and the request/response CDC) so `make coverage` reports
// meaningful line coverage for ALL of the RTL, not just the memory core. This
// driver does not self-check — the pyuvm testbench in ../tb owns correctness;
// its only job is to walk every reachable line:
//   * native APB writes/reads + idle (the arbiter's APB-passthrough path)
//   * AXI writes with AW+W together, AW-first, and W-first channel skew
//   * an AXI write with WSTRB=0 (the no-op / write-enable-low path)
//   * AXI reads (the read-response path)
//   * a write attempted while both resets are low (reset-gated: no commit)
//
// Both clocks are toggled together here; realistic unrelated-clock CDC timing
// is exercised by the cocotb TB. The two-flop synchronizers still resolve in
// two ticks, so the full handshake and every arbiter state are reached.
//
// Run from the Verilator --Mdir (cwd holds coverage.dat); the root Makefile
// then feeds coverage.dat to verilator_coverage --write-info.

#include "Vaxi_apb_mem.h"
#include "verilated.h"
#include "verilated_cov.h"

#include <cstdint>
#include <cstdio>

static Vaxi_apb_mem* dut = nullptr;
static long cycles = 0;

// One tick of both clocks: settle with the clocks low, then a rising edge.
static void tick() {
    dut->PCLK = 0;
    dut->ACLK = 0;
    dut->eval();
    dut->PCLK = 1;
    dut->ACLK = 1;
    dut->eval();
    ++cycles;
}

// -- native APB3 (drives the wrapper's APB slave port directly) ---------------
static void apb_idle() {
    dut->PSEL = 0;
    dut->PENABLE = 0;
    dut->PWRITE = 0;
    tick();
}

static void apb_write(uint32_t addr, uint8_t data) {
    dut->PSEL = 1; dut->PENABLE = 0; dut->PWRITE = 1;
    dut->PADDR = addr; dut->PWDATA = data;
    tick();                         // SETUP
    dut->PENABLE = 1;
    tick();                         // ACCESS — commit on this edge
    apb_idle();
}

static uint8_t apb_read(uint32_t addr) {
    dut->PSEL = 1; dut->PENABLE = 0; dut->PWRITE = 0;
    dut->PADDR = addr;
    tick();                         // SETUP
    dut->PENABLE = 1;
    tick();                         // ACCESS
    uint8_t d = dut->PRDATA;
    apb_idle();
    return d;
}

// -- AXI4-Lite ----------------------------------------------------------------
// aw_first/w_first request deliberate AW/W channel skew; both low drives them
// together. Readies depend only on FSM state (updated at posedge), so they are
// sampled after the clocks-low eval and the handshaked valids dropped after the
// rising edge.
static void axi_write(uint32_t addr, uint8_t data, uint8_t wstrb,
                      bool aw_first, bool w_first) {
    dut->AWADDR = addr; dut->AWPROT = 0;
    dut->WDATA = data;  dut->WSTRB = wstrb;
    dut->BREADY = 1;
    dut->AWVALID = !w_first;        // if W must go first, hold AW off initially
    dut->WVALID  = !aw_first;       // if AW must go first, hold W off initially

    for (int guard = 0; guard < 200; ++guard) {
        dut->PCLK = 0; dut->ACLK = 0; dut->eval();
        bool aw_hs = dut->AWVALID && dut->AWREADY;
        bool w_hs  = dut->WVALID  && dut->WREADY;
        dut->PCLK = 1; dut->ACLK = 1; dut->eval();
        ++cycles;
        if (aw_hs) dut->AWVALID = 0;
        if (w_hs)  dut->WVALID  = 0;
        // Release the deferred channel once the first one has been accepted.
        if (w_first && aw_hs == false && w_hs) dut->AWVALID = 1;
        if (aw_first && w_hs == false && aw_hs) dut->WVALID = 1;
        if (!dut->AWVALID && !dut->WVALID) break;
    }

    for (int guard = 0; guard < 200; ++guard) {
        dut->PCLK = 0; dut->ACLK = 0; dut->eval();
        bool b = dut->BVALID;
        dut->PCLK = 1; dut->ACLK = 1; dut->eval();
        ++cycles;
        if (b) break;
    }
    dut->BREADY = 0;
    tick();
}

static uint8_t axi_read(uint32_t addr) {
    dut->ARADDR = addr; dut->ARPROT = 0;
    dut->ARVALID = 1; dut->RREADY = 1;

    for (int guard = 0; guard < 200; ++guard) {
        dut->PCLK = 0; dut->ACLK = 0; dut->eval();
        bool ar_hs = dut->ARVALID && dut->ARREADY;
        dut->PCLK = 1; dut->ACLK = 1; dut->eval();
        ++cycles;
        if (ar_hs) { dut->ARVALID = 0; break; }
    }

    uint8_t d = 0;
    for (int guard = 0; guard < 200; ++guard) {
        dut->PCLK = 0; dut->ACLK = 0; dut->eval();
        bool r = dut->RVALID;
        if (r) d = dut->RDATA;
        dut->PCLK = 1; dut->ACLK = 1; dut->eval();
        ++cycles;
        if (r) break;
    }
    dut->RREADY = 0;
    tick();
    return d;
}

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    dut = new Vaxi_apb_mem;

    const uint32_t LAST = 0x7FFF;   // top of the 32K byte space

    // --- reset: hold both resets low and attempt an APB write (no commit) -----
    dut->PRESETn = 0; dut->ARESETn = 0;
    dut->PSEL = 0; dut->PENABLE = 0; dut->PWRITE = 0; dut->PADDR = 0; dut->PWDATA = 0;
    dut->AWVALID = 0; dut->WVALID = 0; dut->BREADY = 0;
    dut->ARVALID = 0; dut->RREADY = 0; dut->WSTRB = 0;
    dut->eval();
    dut->PSEL = 1; dut->PENABLE = 1; dut->PWRITE = 1; dut->PADDR = 0x1234; dut->PWDATA = 0xEE;
    tick(); tick();                 // reset-gated write window
    apb_idle();
    dut->PRESETn = 1; dut->ARESETn = 1;
    tick(); tick();                 // let the synchronizers settle out of reset

    // --- native APB: edge + interior addrs, all-0/all-1/patterned payloads ----
    const uint32_t addrs[] = {0x0000, 0x0001, 0x0002, 0x4000, LAST - 1, LAST};
    const uint8_t  data[]  = {0x00, 0xFF, 0x55, 0xAA, 0x5A, 0xA5};
    const int N = sizeof(addrs) / sizeof(addrs[0]);
    for (int i = 0; i < N; ++i) apb_write(addrs[i], data[i]);
    for (int i = 0; i < N; ++i) (void)apb_read(addrs[i]);
    (void)apb_read(0x1234);         // un-written location (reset-gated write absent)

    // --- AXI writes with all three channel-arrival orders, then read-back -----
    axi_write(0x0100, 0x3C, 0x1, /*aw_first=*/false, /*w_first=*/false); // together
    (void)axi_read(0x0100);
    axi_write(0x0200, 0x5A, 0x1, /*aw_first=*/true,  /*w_first=*/false); // AW first
    (void)axi_read(0x0200);
    axi_write(0x0300, 0xC3, 0x1, /*aw_first=*/false, /*w_first=*/true);  // W first
    (void)axi_read(0x0300);

    // --- AXI write with WSTRB=0: a response-producing no-op (no commit) --------
    axi_write(0x0100, 0xFF, 0x0, false, false);
    (void)axi_read(0x0100);         // still 0x3C

    // --- AXI read of an un-written location -----------------------------------
    (void)axi_read(0x7000);

    // --- a stretch of idle (PRDATA='0 default branch + idle arbiter) ----------
    for (int i = 0; i < 8; ++i) apb_idle();

    dut->final();
    VerilatedCov::write("coverage.dat");
    printf("[sim_cov] done: %ld cycles\n", cycles);
    delete dut;
    return 0;
}
