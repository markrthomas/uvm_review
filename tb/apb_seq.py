"""Stimulus sequences for the APB memory."""

import random

from pyuvm import uvm_sequence

from apb_seq_item import ApbSeqItem, ADDR_MASK, DATA_MASK


class ApbWriteReadSeq(uvm_sequence):
    """Write a value, then read it back from the same address."""

    def __init__(self, name="ApbWriteReadSeq", num=32):
        super().__init__(name)
        self.num = num

    async def body(self):
        for _ in range(self.num):
            addr = random.randint(0, ADDR_MASK)
            data = random.randint(0, DATA_MASK)

            wr = ApbSeqItem("wr", addr=addr, data=data, write=True)
            await self.start_item(wr)
            await self.finish_item(wr)

            rd = ApbSeqItem("rd", addr=addr, write=False)
            await self.start_item(rd)
            await self.finish_item(rd)


class ApbRandomSeq(uvm_sequence):
    """Fully random mix of reads and writes."""

    def __init__(self, name="ApbRandomSeq", num=64):
        super().__init__(name)
        self.num = num

    async def body(self):
        for _ in range(self.num):
            item = ApbSeqItem()
            item.randomize()
            await self.start_item(item)
            await self.finish_item(item)


class ApbWalkingSeq(uvm_sequence):
    """Directed edge cases: first/last address and all-0 / all-1 payloads."""

    async def body(self):
        edge_addrs = [0x0000, 0x0001, 0x7FFE, 0x7FFF]
        edge_data = [0x00, 0x01, 0x55, 0xAA, 0xFF]
        for addr in edge_addrs:
            for data in edge_data:
                wr = ApbSeqItem("wr", addr=addr, data=data, write=True)
                await self.start_item(wr)
                await self.finish_item(wr)
                rd = ApbSeqItem("rd", addr=addr, write=False)
                await self.start_item(rd)
                await self.finish_item(rd)
