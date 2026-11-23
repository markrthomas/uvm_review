"""Shared reference model and scoreboard base for the APB and AXI envs.

The APB and AXI environments score reads against the same thing: a byte-memory
reference model (last write to an address wins; never-written locations read as
0). This module factors that model and the analysis-fifo scoreboard plumbing
out of the two near-identical component files, and the cross-bus tests reuse the
same `RefMemModel` so every environment checks reads the same way.
"""

from pyuvm import uvm_component, uvm_get_port, uvm_tlm_analysis_fifo


class RefMemModel:
    """Byte-memory reference: last write wins; un-written reads as 0.

    Shared by the APB and AXI scoreboards and the cross-bus tests so there is a
    single definition of "what a read should return". Tracks reads checked and
    mismatches seen so a scoreboard can assert on them at end of test.
    """

    def __init__(self):
        self.mem = {}
        self.reads = 0
        self.errors = 0

    def write(self, addr, data):
        self.mem[addr] = data

    def expected(self, addr):
        return self.mem.get(addr, 0)

    def check(self, addr, rdata):
        """Score one read; return True on match, False (and count) on mismatch."""
        self.reads += 1
        if rdata != self.expected(addr):
            self.errors += 1
            return False
        return True


class BusScoreboard(uvm_component):
    """Analysis-fifo scoreboard that scores every read against a RefMemModel.

    Writes update the model; reads are compared to it. Subclasses set `tag`
    for the end-of-test summary line.
    """

    tag = "Scoreboard"

    def build_phase(self):
        self.fifo = uvm_tlm_analysis_fifo("fifo", self)
        self.port = uvm_get_port("port", self)
        self.model = RefMemModel()

    def connect_phase(self):
        self.port.connect(self.fifo.get_export)

    @property
    def analysis_export(self):
        return self.fifo.analysis_export

    def _process(self, tr):
        if tr.write:
            self.model.write(tr.addr, tr.data)
        elif self.model.check(tr.addr, tr.rdata):
            self.logger.info(f"MATCH {tr}")
        else:
            self.logger.error(
                f"MISMATCH @0x{tr.addr:04X}: "
                f"got 0x{tr.rdata:02X} exp 0x{self.model.expected(tr.addr):02X}")

    async def run_phase(self):
        # Score transactions live during the run (for in-order logging).
        while True:
            tr = await self.port.get()
            self._process(tr)

    def check_phase(self):
        # Drain anything the run_phase coroutine had not consumed before the
        # objection dropped and the phase was torn down. The analysis fifo is
        # unbounded, so this tail drain is what guarantees no read goes
        # unscored; run_phase above is only for live, in-order logging.
        while self.port.can_get():
            _, tr = self.port.try_get()
            self._process(tr)
        self.logger.info(
            f"{self.tag}: {self.model.reads} reads checked, {self.model.errors} errors")
        assert self.model.errors == 0, f"{self.model.errors} scoreboard mismatch(es)"
