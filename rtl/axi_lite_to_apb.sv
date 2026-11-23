// -----------------------------------------------------------------------------
// axi_lite_to_apb : AXI4-Lite slave front end for an APB3 bridge.
//
// The APB transfer itself is owned by axi_apb_mem's PCLK-domain arbiter.  This
// module runs entirely in the AXI clock domain and exchanges one request and
// one response with that arbiter through level handshakes.  The request/data
// payloads remain stable while their corresponding valid is asserted, which
// allows the wrapper to synchronize the control signals before sampling them.
//
// Only one AXI4-Lite transaction may be outstanding.  AW and W are accepted
// independently, as AXI4-Lite requires; AR is held off after either part of a
// write has arrived so a partially received write cannot be overtaken.
// -----------------------------------------------------------------------------
`ifndef AXI_LITE_TO_APB_SV
`define AXI_LITE_TO_APB_SV

module axi_lite_to_apb #(
    parameter int ADDR_WIDTH = 15,
    parameter int DATA_WIDTH = 8,
    localparam int STRB_WIDTH = (DATA_WIDTH + 7) / 8
) (
    input  logic                  clk,
    input  logic                  rst_n,

    // AXI4-Lite slave -- write address channel
    input  logic [ADDR_WIDTH-1:0] s_axi_awaddr,
    input  logic [2:0]            s_axi_awprot,
    input  logic                  s_axi_awvalid,
    output logic                  s_axi_awready,

    // AXI4-Lite slave -- write data channel
    input  logic [DATA_WIDTH-1:0] s_axi_wdata,
    input  logic [STRB_WIDTH-1:0] s_axi_wstrb,
    input  logic                  s_axi_wvalid,
    output logic                  s_axi_wready,

    // AXI4-Lite slave -- write response channel
    output logic [1:0]            s_axi_bresp,
    output logic                  s_axi_bvalid,
    input  logic                  s_axi_bready,

    // AXI4-Lite slave -- read address channel
    input  logic [ADDR_WIDTH-1:0] s_axi_araddr,
    input  logic [2:0]            s_axi_arprot,
    input  logic                  s_axi_arvalid,
    output logic                  s_axi_arready,

    // AXI4-Lite slave -- read data channel
    output logic [DATA_WIDTH-1:0] s_axi_rdata,
    output logic [1:0]            s_axi_rresp,
    output logic                  s_axi_rvalid,
    input  logic                  s_axi_rready,

    // Request to the PCLK-domain APB arbiter. Request fields are valid and
    // stable while m_req_valid is high, until m_req_ready is observed here.
    output logic                  m_req_valid,
    output logic                  m_req_write,
    output logic [ADDR_WIDTH-1:0] m_req_addr,
    output logic [DATA_WIDTH-1:0] m_req_wdata,
    input  logic                  m_req_ready,

    // Response from the PCLK-domain APB arbiter. Response fields are stable
    // while m_rsp_valid is high, until m_rsp_ready is observed there.
    input  logic                  m_rsp_valid,
    input  logic [DATA_WIDTH-1:0] m_rsp_rdata,
    input  logic                  m_rsp_error,
    output logic                  m_rsp_ready
);

    localparam logic [1:0] RESP_OKAY   = 2'b00;
    localparam logic [1:0] RESP_SLVERR = 2'b10;

    // AXI protection attributes do not alter this simple memory's access
    // policy. DATA_WIDTH is byte-wide by default, so WSTRB[0] controls the
    // sole byte lane rather than being ignored.
    // verilator lint_off UNUSEDSIGNAL
    wire _unused_ok = &{1'b0, s_axi_awprot, s_axi_arprot};
    // verilator lint_on UNUSEDSIGNAL

    typedef enum logic [2:0] {
        ST_IDLE      = 3'b000,
        ST_REQ       = 3'b001,
        ST_WAIT_RSP  = 3'b010,
        ST_WR_RESP   = 3'b011,
        ST_RD_RESP   = 3'b100
    } state_t;

    state_t state, next_state;

    logic [ADDR_WIDTH-1:0] addr_reg;
    logic [DATA_WIDTH-1:0] wdata_reg;
    logic                  write_enable_reg;
    logic                  is_write_reg;
    logic                  resp_err_reg;
    logic [DATA_WIDTH-1:0] rdata_reg;
    logic                  aw_captured;
    logic                  w_captured;

    // m_req_ready and m_rsp_valid originate in PCLK. Synchronize their level
    // controls before using them in the AXI domain. Their payloads are held
    // stable by the four-phase handshakes around these synchronizers.
    logic req_ready_meta, req_ready_sync;
    logic rsp_valid_meta, rsp_valid_sync;

    wire accept_aw = s_axi_awvalid && s_axi_awready;
    wire accept_w  = s_axi_wvalid  && s_axi_wready;
    wire write_complete = (aw_captured || accept_aw) &&
                          (w_captured  || accept_w);
    wire accept_ar = s_axi_arvalid && s_axi_arready;

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            req_ready_meta <= 1'b0;
            req_ready_sync <= 1'b0;
            rsp_valid_meta <= 1'b0;
            rsp_valid_sync <= 1'b0;
        end else begin
            req_ready_meta <= m_req_ready;
            req_ready_sync <= req_ready_meta;
            rsp_valid_meta <= m_rsp_valid;
            rsp_valid_sync <= rsp_valid_meta;
        end
    end

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            state            <= ST_IDLE;
            addr_reg         <= '0;
            wdata_reg        <= '0;
            write_enable_reg <= 1'b0;
            is_write_reg     <= 1'b0;
            resp_err_reg     <= 1'b0;
            rdata_reg        <= '0;
            aw_captured      <= 1'b0;
            w_captured       <= 1'b0;
        end else begin
            state <= next_state;

            if (state == ST_IDLE && accept_aw) begin
                addr_reg    <= s_axi_awaddr;
                aw_captured <= 1'b1;
            end

            if (state == ST_IDLE && accept_w) begin
                wdata_reg        <= s_axi_wdata;
                write_enable_reg <= |s_axi_wstrb;
                w_captured       <= 1'b1;
            end

            if (state == ST_IDLE && write_complete) begin
                is_write_reg <= 1'b1;
            end else if (state == ST_IDLE && accept_ar) begin
                addr_reg     <= s_axi_araddr;
                is_write_reg <= 1'b0;
            end

            if (state == ST_IDLE && next_state == ST_REQ) begin
                aw_captured <= 1'b0;
                w_captured  <= 1'b0;
            end

            if (state == ST_WAIT_RSP && rsp_valid_sync) begin
                resp_err_reg <= m_rsp_error;
                if (!is_write_reg)
                    rdata_reg <= m_rsp_rdata;
            end
        end
    end

    always_comb begin
        next_state = state;
        case (state)
            ST_IDLE: begin
                if (write_complete || accept_ar)
                    next_state = ST_REQ;
            end
            ST_REQ: begin
                if (req_ready_sync)
                    next_state = ST_WAIT_RSP;
            end
            ST_WAIT_RSP: begin
                if (rsp_valid_sync) begin
                    if (is_write_reg)
                        next_state = ST_WR_RESP;
                    else
                        next_state = ST_RD_RESP;
                end
            end
            ST_WR_RESP: begin
                if (s_axi_bready)
                    next_state = ST_IDLE;
            end
            ST_RD_RESP: begin
                if (s_axi_rready)
                    next_state = ST_IDLE;
            end
            // All five states are enumerated above; this default is defensive
            // and unreachable, so waive it rather than hold line coverage below
            // 100% on dead code (cf. the PSLVERR tie-off waiver in apb_mem.sv).
            // verilator coverage_off
            default: next_state = ST_IDLE;
            // verilator coverage_on
        endcase
    end

    // Hold off new channel handshakes until the PCLK side has dropped its
    // acknowledgement from the previous request. This closes the four-phase
    // request handshake even when ACLK is much faster than PCLK.
    assign s_axi_awready = (state == ST_IDLE) && !aw_captured && !req_ready_sync;
    assign s_axi_wready  = (state == ST_IDLE) && !w_captured  && !req_ready_sync;
    assign s_axi_arready = (state == ST_IDLE) && !aw_captured && !w_captured &&
                           !s_axi_awvalid && !s_axi_wvalid && !req_ready_sync;

    assign s_axi_bvalid = (state == ST_WR_RESP);
    assign s_axi_bresp  = resp_err_reg ? RESP_SLVERR : RESP_OKAY;
    assign s_axi_rvalid = (state == ST_RD_RESP);
    assign s_axi_rdata  = rdata_reg;
    assign s_axi_rresp  = resp_err_reg ? RESP_SLVERR : RESP_OKAY;

    assign m_req_valid = (state == ST_REQ);
    assign m_req_write = is_write_reg && write_enable_reg;
    assign m_req_addr  = addr_reg;
    assign m_req_wdata = wdata_reg;
    assign m_rsp_ready = (state == ST_WAIT_RSP);

endmodule

`endif // AXI_LITE_TO_APB_SV
