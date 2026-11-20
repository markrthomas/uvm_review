"""AXI transaction object shared by sequences, driver, monitor and scoreboard."""

import random
from pyuvm import uvm_sequence_item

ADDR_MASK = 0x7FFF  # 15-bit address -> 32K byte space
DATA_MASK = 0xFF    # byte-wide data


class AxiSeqItem(uvm_sequence_item):
    """A single AXI4-Lite read or write transfer."""

    def __init__(self, name="AxiSeqItem", addr=0, data=0, write=True):
        super().__init__(name)
        self.addr = addr & ADDR_MASK
        self.data = data & DATA_MASK
        self.write = write
        self.rdata = 0
        self.resp = 0

    def randomize(self):
        self.addr = random.randint(0, ADDR_MASK)
        self.data = random.randint(0, DATA_MASK)
        self.write = bool(random.getrandbits(1))

    def __eq__(self, other):
        if not isinstance(other, AxiSeqItem):
            return NotImplemented
        payload = self.data if self.write else self.rdata
        other_payload = other.data if other.write else other.rdata
        return (self.write, self.addr, payload) == (other.write, other.addr, other_payload)

    def __str__(self):
        kind = "AXI-WR" if self.write else "AXI-RD"
        payload = self.data if self.write else self.rdata
        return f"{kind} @0x{self.addr:04X} = 0x{payload:02X}"
