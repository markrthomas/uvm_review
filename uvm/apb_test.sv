// -----------------------------------------------------------------------------
// Tests — one-for-one with tb/apb_test.py.
//
//   apb_base_test    : builds the env, drives reset, runs a sequence
//   apb_write_read_test / apb_random_test / apb_walking_test : pick the sequence
//
// The clock runs in the top module; the base test owns reset (PRESETn pulse)
// via the virtual interface, exactly as the pyuvm BFM.reset() did.
// -----------------------------------------------------------------------------
class apb_base_test extends uvm_test;
    `uvm_component_utils(apb_base_test)

    apb_env        env;
    virtual apb_if vif;

    // Sequence type run by this test; overridden by the derived tests.
    protected uvm_object_wrapper seq_wrapper;

    function new(string name, uvm_component parent);
        super.new(name, parent);
    endfunction

    function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        env = apb_env::type_id::create("env", this);
        if (!uvm_config_db#(virtual apb_if)::get(this, "", "vif", vif))
            `uvm_fatal("NOVIF", "no virtual interface set for apb_base_test")
        seq_wrapper = apb_write_read_seq::get_type();
    endfunction

    task reset();
        vif.PRESETn <= 1'b0;
        vif.PSEL    <= 1'b0;
        vif.PENABLE <= 1'b0;
        vif.PWRITE  <= 1'b0;
        vif.PADDR   <= '0;
        vif.PWDATA  <= '0;
        repeat (3) @(posedge vif.PCLK);
        @(negedge vif.PCLK);
        vif.PRESETn <= 1'b1;
        @(posedge vif.PCLK);
    endtask

    task run_phase(uvm_phase phase);
        uvm_sequence #(apb_seq_item) seq;
        phase.raise_objection(this);

        reset();

        if (!$cast(seq, seq_wrapper.create_object("seq")))
            `uvm_fatal("SEQCAST", "could not create the configured sequence")
        seq.start(env.agent.seqr);

        phase.drop_objection(this);
    endtask

endclass


class apb_write_read_test extends apb_base_test;
    `uvm_component_utils(apb_write_read_test)
    function new(string name, uvm_component parent);
        super.new(name, parent);
    endfunction
    function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        seq_wrapper = apb_write_read_seq::get_type();
    endfunction
endclass


class apb_random_test extends apb_base_test;
    `uvm_component_utils(apb_random_test)
    function new(string name, uvm_component parent);
        super.new(name, parent);
    endfunction
    function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        seq_wrapper = apb_random_seq::get_type();
    endfunction
endclass


class apb_walking_test extends apb_base_test;
    `uvm_component_utils(apb_walking_test)
    function new(string name, uvm_component parent);
        super.new(name, parent);
    endfunction
    function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        seq_wrapper = apb_walking_seq::get_type();
    endfunction
endclass
