"""pyuvm structural components for the AXI4-Lite memory environment."""

import cocotb
from pyuvm import (
    ConfigDB,
    uvm_agent,
    uvm_analysis_port,
    uvm_component,
    uvm_driver,
    uvm_env,
    uvm_get_port,
    uvm_monitor,
    uvm_sequencer,
    uvm_tlm_analysis_fifo,
)

from axi_bfm import AxiBfm
from axi_seq_item import AxiSeqItem


class AxiDriver(uvm_driver):
    def build_phase(self):
        self.bfm = AxiBfm()

    def start_of_simulation_phase(self):
        self.bfm.start_bfms()

    async def run_phase(self):
        while True:
            item = await self.seq_item_port.get_next_item()
            await self.bfm.send_command(item.addr, item.write, item.data)
            result = await self.bfm.get_result()
            if not item.write:
                item.rdata = result
            else:
                item.resp = result
            self.seq_item_port.item_done()


class AxiMonitor(uvm_monitor):
    def build_phase(self):
        self.bfm = AxiBfm()
        self.ap = uvm_analysis_port("ap", self)

    async def run_phase(self):
        while True:
            addr, write, wdata, rdata, resp = await self.bfm.get_monitored()
            tr = AxiSeqItem("mon", addr=addr, data=wdata, write=write)
            tr.rdata = rdata
            tr.resp = resp
            self.logger.info(f"observed {tr}")
            self.ap.write(tr)


class AxiAgent(uvm_agent):
    def build_phase(self):
        self.seqr = uvm_sequencer("seqr", self)
        self.driver = AxiDriver("driver", self)
        self.monitor = AxiMonitor("monitor", self)
        ConfigDB().set(None, "*", "AXI_SEQR", self.seqr)

    def connect_phase(self):
        self.driver.seq_item_port.connect(self.seqr.seq_item_export)


class AxiScoreboard(uvm_component):
    """Reference byte memory; checks every AXI read against the last write."""

    def build_phase(self):
        self.fifo = uvm_tlm_analysis_fifo("fifo", self)
        self.port = uvm_get_port("port", self)
        self.model = {}
        self.reads = 0
        self.errors = 0

    def connect_phase(self):
        self.port.connect(self.fifo.get_export)

    @property
    def analysis_export(self):
        return self.fifo.analysis_export

    def process_transaction(self, tr):
        if tr.write:
            self.model[tr.addr] = tr.data
        else:
            self.reads += 1
            expected = self.model.get(tr.addr, 0)
            if tr.rdata != expected:
                self.errors += 1
                self.logger.error(
                    f"MISMATCH @0x{tr.addr:04X}: "
                    f"got 0x{tr.rdata:02X} exp 0x{expected:02X}")
            else:
                self.logger.info(f"MATCH {tr}")

    async def run_phase(self):
        while True:
            tr = await self.port.get()
            self.process_transaction(tr)

    def check_phase(self):
        while self.port.can_get():
            _, tr = self.port.try_get()
            self.process_transaction(tr)
        self.logger.info(
            f"AxiScoreboard: {self.reads} reads checked, {self.errors} errors")
        assert self.errors == 0, f"{self.errors} scoreboard mismatch(es)"


class AxiEnv(uvm_env):
    def build_phase(self):
        self.agent = AxiAgent("agent", self)
        self.scoreboard = AxiScoreboard("scoreboard", self)

    def connect_phase(self):
        self.agent.monitor.ap.connect(self.scoreboard.analysis_export)
