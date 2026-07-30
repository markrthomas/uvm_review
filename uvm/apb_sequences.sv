// -----------------------------------------------------------------------------
// Stimulus sequences — one-for-one with tb/apb_seq.py.
//
//   apb_write_read_seq : write a value, then read it back (32 pairs)
//   apb_random_seq     : fully random mix of reads and writes (64 items)
//   apb_walking_seq    : directed first/last address and all-0/all-1 payloads
// -----------------------------------------------------------------------------

// Write a value, then read it back from the same address.
class apb_write_read_seq extends uvm_sequence #(apb_seq_item);
    `uvm_object_utils(apb_write_read_seq)

    int unsigned num = 32;

    function new(string name = "apb_write_read_seq");
        super.new(name);
    endfunction

    task body();
        apb_seq_item wr, rd;
        for (int unsigned i = 0; i < num; i++) begin
            bit [14:0] a = $urandom_range(0, 15'h7FFF);
            bit [7:0]  d = $urandom_range(0, 8'hFF);

            wr = apb_seq_item::type_id::create("wr");
            start_item(wr);
            wr.addr = a; wr.data = d; wr.write = 1'b1;
            finish_item(wr);

            rd = apb_seq_item::type_id::create("rd");
            start_item(rd);
            rd.addr = a; rd.write = 1'b0;
            finish_item(rd);
        end
    endtask
endclass


// Fully random mix of reads and writes.
class apb_random_seq extends uvm_sequence #(apb_seq_item);
    `uvm_object_utils(apb_random_seq)

    int unsigned num = 64;

    function new(string name = "apb_random_seq");
        super.new(name);
    endfunction

    task body();
        apb_seq_item item;
        for (int unsigned i = 0; i < num; i++) begin
            item = apb_seq_item::type_id::create("item");
            start_item(item);
            if (!item.randomize())
                `uvm_error("RAND", "apb_seq_item randomize failed")
            finish_item(item);
        end
    endtask
endclass


// Directed edge cases: first/last address and all-0 / all-1 payloads.
class apb_walking_seq extends uvm_sequence #(apb_seq_item);
    `uvm_object_utils(apb_walking_seq)

    function new(string name = "apb_walking_seq");
        super.new(name);
    endfunction

    task body();
        apb_seq_item wr, rd;
        bit [14:0] edge_addrs[] = '{15'h0000, 15'h0001, 15'h7FFE, 15'h7FFF};
        bit [7:0]  edge_data[]  = '{8'h00, 8'h01, 8'h55, 8'hAA, 8'hFF};
        foreach (edge_addrs[ai]) begin
            foreach (edge_data[di]) begin
                wr = apb_seq_item::type_id::create("wr");
                start_item(wr);
                wr.addr = edge_addrs[ai]; wr.data = edge_data[di];
                wr.write = 1'b1;
                finish_item(wr);

                rd = apb_seq_item::type_id::create("rd");
                start_item(rd);
                rd.addr = edge_addrs[ai]; rd.write = 1'b0;
                finish_item(rd);
            end
        end
    endtask
endclass
