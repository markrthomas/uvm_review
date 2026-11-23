// -----------------------------------------------------------------------------
// axi_sva : SystemVerilog assertion checker for the AXI4-Lite slave protocol.
//
// A standalone module `bind`-ed to every axi_lite_to_apb instance (see the bind
// at the bottom), so it needs no changes to the DUT or the testbench. It
// captures the AXI4-Lite handshake rules this slave must obey and the master
// obligations the stimulus must obey, plus this slave's response-code policy
// (OKAY or SLVERR only). Failures fire $error; cover properties record that the
// key transactions were exercised.
//
// Under a 2-state engine the $isunknown X-checks are vacuous and do real work
// only in a 4-state simulator; the handshake/stability/response properties run
// in both. It is compiled with --assert in the Verilator coverage sim
// (`make coverage`); the Icarus/cocotb simulator's SVA support is too weak to
// carry it. The whole module is coverage_off so its own lines do not count
// toward the RTL line-coverage floor.
// -----------------------------------------------------------------------------
// verilator coverage_off
module axi_sva #(
    parameter int ADDR_WIDTH = 15,
    parameter int DATA_WIDTH = 8,
    localparam int STRB_WIDTH = (DATA_WIDTH + 7) / 8
) (
    input logic                  clk,
    input logic                  rst_n,

    input logic [ADDR_WIDTH-1:0] s_axi_awaddr,
    input logic [2:0]            s_axi_awprot,
    input logic                  s_axi_awvalid,
    input logic                  s_axi_awready,

    input logic [DATA_WIDTH-1:0] s_axi_wdata,
    input logic [STRB_WIDTH-1:0] s_axi_wstrb,
    input logic                  s_axi_wvalid,
    input logic                  s_axi_wready,

    input logic [1:0]            s_axi_bresp,
    input logic                  s_axi_bvalid,
    input logic                  s_axi_bready,

    input logic [ADDR_WIDTH-1:0] s_axi_araddr,
    input logic [2:0]            s_axi_arprot,
    input logic                  s_axi_arvalid,
    input logic                  s_axi_arready,

    input logic [DATA_WIDTH-1:0] s_axi_rdata,
    input logic [1:0]            s_axi_rresp,
    input logic                  s_axi_rvalid,
    input logic                  s_axi_rready
);

    localparam logic [1:0] RESP_OKAY   = 2'b00;
    localparam logic [1:0] RESP_SLVERR = 2'b10;

    default clocking cb @(posedge clk); endclocking
    default disable iff (!rst_n);

    // ---- master obligations: VALID held with stable payload until READY ------
    a_aw_stable: assert property (
        (s_axi_awvalid && !s_axi_awready) |=>
            (s_axi_awvalid && $stable(s_axi_awaddr) && $stable(s_axi_awprot)))
        else $error("AXI-SVA: AW channel changed while stalled (VALID high, READY low)");

    a_w_stable: assert property (
        (s_axi_wvalid && !s_axi_wready) |=>
            (s_axi_wvalid && $stable(s_axi_wdata) && $stable(s_axi_wstrb)))
        else $error("AXI-SVA: W channel changed while stalled");

    a_ar_stable: assert property (
        (s_axi_arvalid && !s_axi_arready) |=>
            (s_axi_arvalid && $stable(s_axi_araddr) && $stable(s_axi_arprot)))
        else $error("AXI-SVA: AR channel changed while stalled");

    // ---- slave obligations: response VALID held with stable payload ----------
    a_b_stable: assert property (
        (s_axi_bvalid && !s_axi_bready) |=> (s_axi_bvalid && $stable(s_axi_bresp)))
        else $error("AXI-SVA: B channel changed while stalled (BVALID high, BREADY low)");

    a_r_stable: assert property (
        (s_axi_rvalid && !s_axi_rready) |=>
            (s_axi_rvalid && $stable(s_axi_rdata) && $stable(s_axi_rresp)))
        else $error("AXI-SVA: R channel changed while stalled");

    // ---- single outstanding: write and read responses never overlap ---------
    a_b_r_exclusive: assert property (!(s_axi_bvalid && s_axi_rvalid))
        else $error("AXI-SVA: BVALID and RVALID asserted together (single-outstanding slave)");

    // ---- this slave's response policy: OKAY or SLVERR only -------------------
    a_bresp_legal: assert property (
        s_axi_bvalid |-> ((s_axi_bresp == RESP_OKAY) || (s_axi_bresp == RESP_SLVERR)))
        else $error("AXI-SVA: illegal BRESP");

    a_rresp_legal: assert property (
        s_axi_rvalid |-> ((s_axi_rresp == RESP_OKAY) || (s_axi_rresp == RESP_SLVERR)))
        else $error("AXI-SVA: illegal RRESP");

    // ---- no unknowns on response outputs while valid -------------------------
    a_b_known: assert property (s_axi_bvalid |-> !$isunknown(s_axi_bresp))
        else $error("AXI-SVA: X/Z on BRESP while BVALID");

    a_r_known: assert property (
        s_axi_rvalid |-> !$isunknown({s_axi_rdata, s_axi_rresp}))
        else $error("AXI-SVA: X/Z on RDATA/RRESP while RVALID");

    // ---- reset: no response outstanding while reset is asserted --------------
    a_reset_resp_idle: assert property (
        disable iff (1'b0) ((!rst_n) |-> (!s_axi_bvalid && !s_axi_rvalid)))
        else $error("AXI-SVA: a response was valid during reset");

    // ---- functional cover ----------------------------------------------------
    c_write:  cover property (s_axi_bvalid && s_axi_bready);
    c_read:   cover property (s_axi_rvalid && s_axi_rready);
    c_wstrb0: cover property (s_axi_wvalid && s_axi_wready && (s_axi_wstrb == '0));

endmodule

// Attach the checker to every axi_lite_to_apb instance, matching its parameters
// and connecting the identically-named ports (.*).
bind axi_lite_to_apb axi_sva #(
    .ADDR_WIDTH(ADDR_WIDTH),
    .DATA_WIDTH(DATA_WIDTH)
) u_axi_sva (.*);
// verilator coverage_on
