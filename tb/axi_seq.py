"""Stimulus sequences for the AXI4-Lite memory interface."""

import random
from pyuvm import uvm_sequence
from axi_seq_item import AxiSeqItem, ADDR_MASK, DATA_MASK


class AxiWriteReadSeq(uvm_sequence):
    def __init__(self, name="AxiWriteReadSeq", num=32):
        super().__init__(name)
        self.num = num

    async def body(self):
        for _ in range(self.num):
            addr = random.randint(0, ADDR_MASK)
            data = random.randint(0, DATA_MASK)

            wr = AxiSeqItem("wr", addr=addr, data=data, write=True)
            await self.start_item(wr)
            await self.finish_item(wr)

            rd = AxiSeqItem("rd", addr=addr, write=False)
            await self.start_item(rd)
            await self.finish_item(rd)


class AxiRandomSeq(uvm_sequence):
    def __init__(self, name="AxiRandomSeq", num=64):
        super().__init__(name)
        self.num = num

    async def body(self):
        written = []
        for _ in range(self.num):
            write = bool(random.getrandbits(1))
            if write:
                item = AxiSeqItem("wr",
                                  addr=random.randint(0, ADDR_MASK),
                                  data=random.randint(0, DATA_MASK),
                                  write=True)
            else:
                if written and random.random() < 4 / 5:
                    addr = random.choice(written)
                else:
                    addr = random.randint(0, ADDR_MASK)
                item = AxiSeqItem("rd", addr=addr, write=False)
            await self.start_item(item)
            await self.finish_item(item)
            if write:
                written.append(item.addr)


class AxiWalkingSeq(uvm_sequence):
    def __init__(self, name="AxiWalkingSeq"):
        super().__init__(name)

    async def body(self):
        edge_addrs = [0x0000, 0x0001, 0x7FFE, 0x7FFF]
        patterns = [0x00, 0x01, 0x55, 0xAA, 0xFF]

        for addr in edge_addrs:
            for pat in patterns:
                wr = AxiSeqItem("wr", addr=addr, data=pat, write=True)
                await self.start_item(wr)
                await self.finish_item(wr)

                rd = AxiSeqItem("rd", addr=addr, write=False)
                await self.start_item(rd)
                await self.finish_item(rd)
