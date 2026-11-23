"""pyuvm structural components for the AXI4-Lite memory environment."""

import cocotb
from pyuvm import (
    ConfigDB,
    uvm_agent,
    uvm_analysis_port,
    uvm_driver,
    uvm_env,
    uvm_monitor,
    uvm_sequencer,
)

from axi_bfm import AxiBfm
from axi_seq_item import AxiSeqItem
from bus_scoreboard import BusScoreboard


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
            # The BFM associates each response with the most recently handshaked
            # address/data on its channel (last_awaddr/last_araddr). That is
            # exact only because this slave is single-outstanding (one request
            # and response in flight at a time); it would mis-pair transfers if
            # the design were ever made to pipeline multiple outstanding ops.
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


class AxiScoreboard(BusScoreboard):
    """Reference byte memory; checks every AXI read against the last write."""

    tag = "AxiScoreboard"


class AxiEnv(uvm_env):
    def build_phase(self):
        self.agent = AxiAgent("agent", self)
        self.scoreboard = AxiScoreboard("scoreboard", self)

    def connect_phase(self):
        self.agent.monitor.ap.connect(self.scoreboard.analysis_export)
