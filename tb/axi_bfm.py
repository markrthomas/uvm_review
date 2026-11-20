"""AXI4-Lite Bus Functional Model: drives and monitors AXI4-Lite channels.

Handles write address (AW), write data (W), write response (B),
read address (AR), and read data (R) channels.
"""

import cocotb
from cocotb.clock import Clock
from cocotb.queue import Queue
from cocotb.triggers import ClockCycles, FallingEdge, RisingEdge

from pyuvm import utility_classes


class AxiBfm(metaclass=utility_classes.Singleton):
    def __init__(self):
        self.dut = cocotb.top
        self.driver_queue = Queue()        # (addr, write, wdata)
        self.result_queue = Queue()        # rdata returned to driver
        self.monitor_queue = Queue()       # (addr, write, wdata, rdata, resp)

    # -- clock / reset --------------------------------------------------------
    async def start_clock(self, aclk_period_ns=10, pclk_period_ns=7):
        """Start both clocks for an AXI run with intentionally unrelated periods.

        The wrapper owns a PCLK-domain APB memory, so an AXI-only test still
        needs PCLK.  Keeping the periods different exercises the CDC handshake
        rather than accidentally relying on coincident edges.
        """
        if hasattr(self.dut, "ACLK"):
            cocotb.start_soon(Clock(self.dut.ACLK, aclk_period_ns, units="ns").start())
        if hasattr(self.dut, "PCLK"):
            cocotb.start_soon(Clock(self.dut.PCLK, pclk_period_ns, units="ns").start())

    async def reset(self):
        clk = self.dut.ACLK if hasattr(self.dut, "ACLK") else self.dut.PCLK
        if hasattr(self.dut, "ARESETn"):
            self.dut.ARESETn.value = 0
        if hasattr(self.dut, "PRESETn"):
            self.dut.PRESETn.value = 0

        # Idle AXI channels
        self.dut.AWADDR.value = 0
        self.dut.AWPROT.value = 0
        self.dut.AWVALID.value = 0
        self.dut.WDATA.value = 0
        self.dut.WSTRB.value = 0
        self.dut.WVALID.value = 0
        self.dut.BREADY.value = 0
        self.dut.ARADDR.value = 0
        self.dut.ARPROT.value = 0
        self.dut.ARVALID.value = 0
        self.dut.RREADY.value = 0

        # Idle APB channels if present
        if hasattr(self.dut, "PSEL"):
            self.dut.PSEL.value = 0
            self.dut.PENABLE.value = 0
            self.dut.PWRITE.value = 0
            self.dut.PADDR.value = 0
            self.dut.PWDATA.value = 0

        await ClockCycles(clk, 3)
        await FallingEdge(clk)
        if hasattr(self.dut, "ARESETn"):
            self.dut.ARESETn.value = 1
        if hasattr(self.dut, "PRESETn"):
            self.dut.PRESETn.value = 1
        await RisingEdge(clk)

    # -- primitive AXI transfers ----------------------------------------------
    async def _write(self, addr, wdata):
        clk = self.dut.ACLK if hasattr(self.dut, "ACLK") else self.dut.PCLK
        await FallingEdge(clk)
        self.dut.AWADDR.value = addr
        self.dut.AWPROT.value = 0
        self.dut.AWVALID.value = 1
        self.dut.WDATA.value = wdata
        self.dut.WSTRB.value = 1
        self.dut.WVALID.value = 1
        self.dut.BREADY.value = 1

        aw_done = False
        w_done = False
        while not (aw_done and w_done):
            await RisingEdge(clk)
            aw_hs = not aw_done and (self.dut.AWREADY.value == 1)
            w_hs = not w_done and (self.dut.WREADY.value == 1)
            if aw_hs:
                aw_done = True
            if w_hs:
                w_done = True
            if aw_hs or w_hs:
                await FallingEdge(clk)
                if aw_hs:
                    self.dut.AWVALID.value = 0
                if w_hs:
                    self.dut.WVALID.value = 0

        while True:
            await RisingEdge(clk)
            if self.dut.BVALID.value == 1:
                bresp = int(self.dut.BRESP.value) if self.dut.BRESP.value.is_resolvable else 0
                await FallingEdge(clk)
                self.dut.BREADY.value = 0
                return bresp

    async def _read(self, addr):
        clk = self.dut.ACLK if hasattr(self.dut, "ACLK") else self.dut.PCLK
        await FallingEdge(clk)
        self.dut.ARADDR.value = addr
        self.dut.ARPROT.value = 0
        self.dut.ARVALID.value = 1
        self.dut.RREADY.value = 1

        ar_done = False
        while not ar_done:
            await RisingEdge(clk)
            if self.dut.ARREADY.value == 1:
                ar_done = True
                await FallingEdge(clk)
                self.dut.ARVALID.value = 0

        while True:
            await RisingEdge(clk)
            if self.dut.RVALID.value == 1:
                rdata = int(self.dut.RDATA.value) if self.dut.RDATA.value.is_resolvable else 0
                await FallingEdge(clk)
                self.dut.RREADY.value = 0
                return rdata

    async def driver_bfm(self):
        while True:
            addr, write, wdata = await self.driver_queue.get()
            if write:
                resp = await self._write(addr, wdata)
                await self.result_queue.put(resp)
            else:
                rdata = await self._read(addr)
                await self.result_queue.put(rdata)

    async def monitor_bfm(self):
        clk = self.dut.ACLK if hasattr(self.dut, "ACLK") else self.dut.PCLK
        last_awaddr = 0
        last_wdata = 0
        last_araddr = 0
        while True:
            await RisingEdge(clk)
            if self.dut.AWVALID.value == 1 and self.dut.AWREADY.value == 1:
                last_awaddr = int(self.dut.AWADDR.value)
            if self.dut.WVALID.value == 1 and self.dut.WREADY.value == 1:
                last_wdata = int(self.dut.WDATA.value)
            if self.dut.BVALID.value == 1 and self.dut.BREADY.value == 1:
                resp = int(self.dut.BRESP.value) if self.dut.BRESP.value.is_resolvable else 0
                await self.monitor_queue.put((last_awaddr, True, last_wdata, 0, resp))

            if self.dut.ARVALID.value == 1 and self.dut.ARREADY.value == 1:
                last_araddr = int(self.dut.ARADDR.value)
            if self.dut.RVALID.value == 1 and self.dut.RREADY.value == 1:
                rdata = int(self.dut.RDATA.value) if self.dut.RDATA.value.is_resolvable else 0
                rresp = int(self.dut.RRESP.value) if self.dut.RRESP.value.is_resolvable else 0
                await self.monitor_queue.put((last_araddr, False, 0, rdata, rresp))

    async def send_command(self, addr, write, wdata):
        await self.driver_queue.put((addr, write, wdata))

    async def get_result(self):
        return await self.result_queue.get()

    async def get_monitored(self):
        return await self.monitor_queue.get()

    def start_bfms(self):
        cocotb.start_soon(self.driver_bfm())
        cocotb.start_soon(self.monitor_bfm())
