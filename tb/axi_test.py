"""AXI tests and cocotb entry points for pyuvm."""

import cocotb
from cocotb.triggers import ClockCycles, FallingEdge, RisingEdge
from pyuvm import ConfigDB, uvm_root, uvm_test

from axi_bfm import AxiBfm
from axi_components import AxiEnv
from axi_seq import AxiRandomSeq, AxiWalkingSeq, AxiWriteReadSeq


class AxiBaseTest(uvm_test):
    seq_cls = AxiRandomSeq

    def build_phase(self):
        self.env = AxiEnv("env", self)

    async def run_phase(self):
        self.raise_objection()
        bfm = AxiBfm()
        await bfm.start_clock()
        await bfm.reset()

        seqr = ConfigDB().get(self, "", "AXI_SEQR")
        seq = self.seq_cls()
        await seq.start(seqr)
        self.drop_objection()


class AxiWriteReadTest(AxiBaseTest):
    seq_cls = AxiWriteReadSeq


class AxiRandomTest(AxiBaseTest):
    seq_cls = AxiRandomSeq


class AxiWalkingTest(AxiBaseTest):
    seq_cls = AxiWalkingSeq


class DualBusTest(uvm_test):
    """Exercises both APB and AXI buses against axi_apb_mem."""

    async def run_phase(self):
        from apb_bfm import ApbBfm
        self.raise_objection()
        axi_bfm = AxiBfm()
        apb_bfm = ApbBfm()
        await axi_bfm.start_clock()
        await axi_bfm.reset()
        axi_bfm.start_bfms()
        apb_bfm.start_bfms()

        # Step 1: Write via APB, Read via AXI
        self.logger.info("=== Phase 1: Write via APB, Read via AXI ===")
        test_pairs_1 = [(0x0100, 0x42), (0x0200, 0x55), (0x0300, 0xAA), (0x0400, 0x12)]
        for addr, data in test_pairs_1:
            await apb_bfm.send_command(addr, True, data)
            await apb_bfm.get_result()
            await axi_bfm.send_command(addr, False, 0)
            rdata = await axi_bfm.get_result()
            assert rdata == data, f"DualBus APB->AXI mismatch at 0x{addr:04X}: wrote 0x{data:02X}, read 0x{rdata:02X}"
            self.logger.info(f"APB WR -> AXI RD matched @0x{addr:04X} = 0x{data:02X}")

        # Step 2: Write via AXI, Read via APB
        self.logger.info("=== Phase 2: Write via AXI, Read via APB ===")
        test_pairs_2 = [(0x0500, 0xBE), (0x0600, 0xEF), (0x0700, 0x77), (0x0800, 0x99)]
        for addr, data in test_pairs_2:
            await axi_bfm.send_command(addr, True, data)
            await axi_bfm.get_result()
            await apb_bfm.send_command(addr, False, 0)
            rdata = await apb_bfm.get_result()
            assert rdata == data, f"DualBus AXI->APB mismatch at 0x{addr:04X}: wrote 0x{data:02X}, read 0x{rdata:02X}"
            self.logger.info(f"AXI WR -> APB RD matched @0x{addr:04X} = 0x{data:02X}")

        # Step 3: issue independent writes together.  The AXI BFM owns both
        # clocks in this test (ACLK=10 ns, PCLK=7 ns), so this also exercises
        # the async request/response crossing while the arbiter serializes the
        # competing memory accesses.
        self.logger.info("=== Phase 3: Concurrent independent writes ===")
        apb_addr, apb_data = 0x0900, 0x3C
        axi_addr, axi_data = 0x0A00, 0xC3
        await apb_bfm.send_command(apb_addr, True, apb_data)
        await axi_bfm.send_command(axi_addr, True, axi_data)
        await apb_bfm.get_result()
        axi_resp = await axi_bfm.get_result()
        assert axi_resp == 0, f"Concurrent AXI write returned BRESP={axi_resp}"

        await axi_bfm.send_command(apb_addr, False, 0)
        assert await axi_bfm.get_result() == apb_data, (
            "Concurrent APB write was not visible through AXI")
        await apb_bfm.send_command(axi_addr, False, 0)
        assert await apb_bfm.get_result() == axi_data, (
            "Concurrent AXI write was not visible through APB")

        self.logger.info("DualBusTest: ALL cross-bus checks passed!")
        self.drop_objection()


@cocotb.test()
async def axi_write_read_test(_dut):
    await uvm_root().run_test("AxiWriteReadTest")


@cocotb.test()
async def axi_random_test(_dut):
    await uvm_root().run_test("AxiRandomTest")


@cocotb.test()
async def axi_walking_test(_dut):
    await uvm_root().run_test("AxiWalkingTest")


@cocotb.test()
async def dual_bus_test(_dut):
    await uvm_root().run_test("DualBusTest")


async def _wait_for_high(clk, signal, channel, cycles=32):
    for _ in range(cycles):
        await RisingEdge(clk)
        if signal.value == 1:
            return
    raise AssertionError(f"AXI {channel} did not handshake within {cycles} ACLK cycles")


async def _direct_axi_write(dut, addr, data, wstrb=1, address_first=True):
    """Write with deliberately independent AW and W channel timing."""
    clk = dut.ACLK
    dut.BREADY.value = 1

    if address_first:
        await FallingEdge(clk)
        dut.AWADDR.value = addr
        dut.AWPROT.value = 0
        dut.AWVALID.value = 1
        await _wait_for_high(clk, dut.AWREADY, "AW")
        await FallingEdge(clk)
        dut.AWVALID.value = 0
        await ClockCycles(clk, 2)

        await FallingEdge(clk)
        dut.WDATA.value = data
        dut.WSTRB.value = wstrb
        dut.WVALID.value = 1
        await _wait_for_high(clk, dut.WREADY, "W")
        await FallingEdge(clk)
        dut.WVALID.value = 0
    else:
        await FallingEdge(clk)
        dut.WDATA.value = data
        dut.WSTRB.value = wstrb
        dut.WVALID.value = 1
        await _wait_for_high(clk, dut.WREADY, "W")
        await FallingEdge(clk)
        dut.WVALID.value = 0
        await ClockCycles(clk, 2)

        await FallingEdge(clk)
        dut.AWADDR.value = addr
        dut.AWPROT.value = 0
        dut.AWVALID.value = 1
        await _wait_for_high(clk, dut.AWREADY, "AW")
        await FallingEdge(clk)
        dut.AWVALID.value = 0

    await _wait_for_high(clk, dut.BVALID, "B")
    assert int(dut.BRESP.value) == 0, f"write BRESP={int(dut.BRESP.value)}"
    await FallingEdge(clk)
    dut.BREADY.value = 0


async def _direct_axi_read(dut, addr):
    clk = dut.ACLK
    await FallingEdge(clk)
    dut.ARADDR.value = addr
    dut.ARPROT.value = 0
    dut.ARVALID.value = 1
    dut.RREADY.value = 1
    await _wait_for_high(clk, dut.ARREADY, "AR")
    await FallingEdge(clk)
    dut.ARVALID.value = 0
    await _wait_for_high(clk, dut.RVALID, "R")
    data = int(dut.RDATA.value)
    assert int(dut.RRESP.value) == 0, f"read RRESP={int(dut.RRESP.value)}"
    await FallingEdge(clk)
    dut.RREADY.value = 0
    return data


@cocotb.test()
async def axi_channel_skew_and_strobe_test(dut):
    """Exercise legal AW/W skew and the single byte lane's WSTRB behavior."""
    bfm = AxiBfm()
    await bfm.start_clock()
    await bfm.reset()

    # AXI4-Lite permits either write channel to arrive first.
    await _direct_axi_write(dut, 0x1200, 0xA5, address_first=True)
    assert await _direct_axi_read(dut, 0x1200) == 0xA5
    await _direct_axi_write(dut, 0x1201, 0x5A, address_first=False)
    assert await _direct_axi_read(dut, 0x1201) == 0x5A

    # This is an 8-bit memory, so WSTRB[0]=0 is a response-producing no-op.
    await _direct_axi_write(dut, 0x1200, 0x3C, wstrb=0, address_first=True)
    assert await _direct_axi_read(dut, 0x1200) == 0xA5
