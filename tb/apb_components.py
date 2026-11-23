"""pyuvm structural components for the APB memory environment."""

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

from apb_bfm import ApbBfm
from apb_seq_item import ApbSeqItem
from bus_scoreboard import BusScoreboard


class ApbDriver(uvm_driver):
    def build_phase(self):
        self.bfm = ApbBfm()

    def start_of_simulation_phase(self):
        self.bfm.start_bfms()

    async def run_phase(self):
        while True:
            item = await self.seq_item_port.get_next_item()
            await self.bfm.send_command(item.addr, item.write, item.data)
            rdata = await self.bfm.get_result()
            if not item.write:
                item.rdata = rdata
            self.seq_item_port.item_done()


class ApbMonitor(uvm_monitor):
    def build_phase(self):
        self.bfm = ApbBfm()
        self.ap = uvm_analysis_port("ap", self)

    async def run_phase(self):
        while True:
            addr, write, wdata, rdata = await self.bfm.get_monitored()
            tr = ApbSeqItem("mon", addr=addr, data=wdata, write=write)
            tr.rdata = rdata
            self.logger.info(f"observed {tr}")
            self.ap.write(tr)


class ApbAgent(uvm_agent):
    def build_phase(self):
        self.seqr = uvm_sequencer("seqr", self)
        self.driver = ApbDriver("driver", self)
        self.monitor = ApbMonitor("monitor", self)
        ConfigDB().set(None, "*", "SEQR", self.seqr)

    def connect_phase(self):
        self.driver.seq_item_port.connect(self.seqr.seq_item_export)


class ApbScoreboard(BusScoreboard):
    """Reference byte memory; checks every APB read against the last write."""

    tag = "ApbScoreboard"


class ApbEnv(uvm_env):
    def build_phase(self):
        self.agent = ApbAgent("agent", self)
        self.scoreboard = ApbScoreboard("scoreboard", self)

    def connect_phase(self):
        self.agent.monitor.ap.connect(self.scoreboard.analysis_export)
