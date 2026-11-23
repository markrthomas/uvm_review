"""Error-path (SLVERR) test — error-injection build only.

Loaded only when the RTL is compiled with -DAPB_ERR_INJECT (see tb/Makefile
ERR_INJECT=1 / `make test-axi-slverr`), where apb_mem asserts PSLVERR for the
top address. It exercises the otherwise-dead PSLVERR -> AXI SLVERR response
mapping end to end:

  * a normal AXI write/read returns OKAY (BRESP/RRESP = 2'b00);
  * a write/read to the error address returns SLVERR (2'b10) on B and R;
  * the native APB port reports PSLVERR for the error address.

The shipped slave never errors, so this path is unreachable without the define.
"""

import cocotb
from cocotb.triggers import FallingEdge, RisingEdge

from axi_bfm import AxiBfm

ERR_ADDR = 0x7FFF
RESP_OKAY = 0b00
RESP_SLVERR = 0b10


async def _axi_read_resp(dut, addr):
    """Direct AXI read returning (rdata, rresp) — the BFM read drops rresp."""
    clk = dut.ACLK
    await FallingEdge(clk)
    dut.ARADDR.value = addr
    dut.ARPROT.value = 0
    dut.ARVALID.value = 1
    dut.RREADY.value = 1
    while True:
        await RisingEdge(clk)
        if dut.ARREADY.value == 1:
            await FallingEdge(clk)
            dut.ARVALID.value = 0
            break
    while True:
        await RisingEdge(clk)
        if dut.RVALID.value == 1:
            rdata = int(dut.RDATA.value)
            rresp = int(dut.RRESP.value)
            await FallingEdge(clk)
            dut.RREADY.value = 0
            return rdata, rresp


async def _apb_pslverr(dut, addr):
    """Direct APB read of the given address; return (prdata, pslverr)."""
    clk = dut.PCLK
    await FallingEdge(clk)
    dut.PSEL.value = 1
    dut.PENABLE.value = 0
    dut.PWRITE.value = 0
    dut.PADDR.value = addr
    await FallingEdge(clk)
    dut.PENABLE.value = 1
    await RisingEdge(clk)
    while dut.PREADY.value != 1:
        await RisingEdge(clk)
    prdata = int(dut.PRDATA.value)
    pslverr = int(dut.PSLVERR.value)
    await FallingEdge(clk)
    dut.PSEL.value = 0
    dut.PENABLE.value = 0
    return prdata, pslverr


@cocotb.test()
async def axi_slverr_test(dut):
    bfm = AxiBfm()
    await bfm.start_clock()
    await bfm.reset()

    # Normal address: write/read return OKAY.
    assert await bfm._write(0x0010, 0x5A) == RESP_OKAY, "normal write not OKAY"
    rdata, rresp = await _axi_read_resp(dut, 0x0010)
    assert rresp == RESP_OKAY, f"normal read RRESP={rresp:#04b}, expected OKAY"
    assert rdata == 0x5A, f"normal read data 0x{rdata:02X}, expected 0x5A"

    # Error address: the write commits (PREADY stays high) but the response is
    # SLVERR, and a read of it returns the stored data with RRESP=SLVERR.
    assert await bfm._write(ERR_ADDR, 0xA5) == RESP_SLVERR, \
        "error-address write BRESP was not SLVERR"
    rdata, rresp = await _axi_read_resp(dut, ERR_ADDR)
    assert rresp == RESP_SLVERR, f"error-address read RRESP={rresp:#04b}, expected SLVERR"
    assert rdata == 0xA5, f"error-address read data 0x{rdata:02X}, expected 0xA5"

    # Native APB port reports PSLVERR for the error address, not for a normal one.
    _, pslverr = await _apb_pslverr(dut, ERR_ADDR)
    assert pslverr == 1, "APB PSLVERR not asserted at the error address"
    _, pslverr = await _apb_pslverr(dut, 0x0010)
    assert pslverr == 0, "APB PSLVERR asserted at a normal address"

    dut._log.info("axi_slverr_test: OKAY and SLVERR response paths verified")
