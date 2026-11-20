// -----------------------------------------------------------------------------
// axi_apb_mem : Shared AXI4-Lite + APB3 byte-memory subsystem.
//
// The native APB3 interface is clocked by PCLK; AXI4-Lite is clocked by ACLK.
// The clocks may be unrelated. A single-outstanding request/response CDC
// handshake carries AXI transactions to the PCLK-side arbiter. Its payload is
// held stable around the synchronized valid controls. The arbiter gives an
// active external APB transaction priority, then locks the memory to an AXI
// transfer through its SETUP and ACCESS phases.
//
// Both PRESETn and ARESETn must be asserted together for a whole-subsystem
// reset. They may be deasserted independently in their own clock domains.
// -----------------------------------------------------------------------------
`ifndef AXI_APB_MEM_SV
`define AXI_APB_MEM_SV

module axi_apb_mem #(
    parameter int ADDR_WIDTH = 15,
    parameter int DATA_WIDTH = 8,
    localparam int STRB_WIDTH = (DATA_WIDTH + 7) / 8
) (
    input  logic                  PCLK,
    input  logic                  PRESETn,
    input  logic                  ACLK,
    input  logic                  ARESETn,

    // Native APB3 slave interface
    input  logic                  PSEL,
    input  logic                  PENABLE,
    input  logic                  PWRITE,
    input  logic [ADDR_WIDTH-1:0] PADDR,
    input  logic [DATA_WIDTH-1:0] PWDATA,
    output logic [DATA_WIDTH-1:0] PRDATA,
    output logic                  PREADY,
    output logic                  PSLVERR,

    // AXI4-Lite slave interface
    input  logic [ADDR_WIDTH-1:0] AWADDR,
    input  logic [2:0]            AWPROT,
    input  logic                  AWVALID,
    output logic                  AWREADY,
    input  logic [DATA_WIDTH-1:0] WDATA,
    input  logic [STRB_WIDTH-1:0] WSTRB,
    input  logic                  WVALID,
    output logic                  WREADY,
    output logic [1:0]            BRESP,
    output logic                  BVALID,
    input  logic                  BREADY,
    input  logic [ADDR_WIDTH-1:0] ARADDR,
    input  logic [2:0]            ARPROT,
    input  logic                  ARVALID,
    output logic                  ARREADY,
    output logic [DATA_WIDTH-1:0] RDATA,
    output logic [1:0]            RRESP,
    output logic                  RVALID,
    input  logic                  RREADY
);

    // AXI-domain request and PCLK-domain response handshake signals.
    logic                  axi_req_valid;
    logic                  axi_req_write;
    logic [ADDR_WIDTH-1:0] axi_req_addr;
    logic [DATA_WIDTH-1:0] axi_req_wdata;
    logic                  axi_req_ready;
    logic                  axi_rsp_valid;
    logic [DATA_WIDTH-1:0] axi_rsp_rdata;
    logic                  axi_rsp_error;
    logic                  axi_rsp_ready;

    axi_lite_to_apb #(
        .ADDR_WIDTH (ADDR_WIDTH),
        .DATA_WIDTH (DATA_WIDTH)
    ) u_axi_bridge (
        .clk           (ACLK),
        .rst_n         (ARESETn),
        .s_axi_awaddr  (AWADDR),
        .s_axi_awprot  (AWPROT),
        .s_axi_awvalid (AWVALID),
        .s_axi_awready (AWREADY),
        .s_axi_wdata   (WDATA),
        .s_axi_wstrb   (WSTRB),
        .s_axi_wvalid  (WVALID),
        .s_axi_wready  (WREADY),
        .s_axi_bresp   (BRESP),
        .s_axi_bvalid  (BVALID),
        .s_axi_bready  (BREADY),
        .s_axi_araddr  (ARADDR),
        .s_axi_arprot  (ARPROT),
        .s_axi_arvalid (ARVALID),
        .s_axi_arready (ARREADY),
        .s_axi_rdata   (RDATA),
        .s_axi_rresp   (RRESP),
        .s_axi_rvalid  (RVALID),
        .s_axi_rready  (RREADY),
        .m_req_valid   (axi_req_valid),
        .m_req_write   (axi_req_write),
        .m_req_addr    (axi_req_addr),
        .m_req_wdata   (axi_req_wdata),
        .m_req_ready   (axi_req_ready),
        .m_rsp_valid   (axi_rsp_valid),
        .m_rsp_rdata   (axi_rsp_rdata),
        .m_rsp_error   (axi_rsp_error),
        .m_rsp_ready   (axi_rsp_ready)
    );

    // Synchronize the two AXI-domain handshake controls into PCLK. Request
    // and response payloads are sampled only after their stable valid has
    // passed these two-flop synchronizers.
    logic req_valid_meta, req_valid_sync;
    logic rsp_ready_meta, rsp_ready_sync;

    typedef enum logic [1:0] {
        AXI_IDLE   = 2'b00,
        AXI_SETUP  = 2'b01,
        AXI_ACCESS = 2'b10
    } axi_state_t;

    axi_state_t axi_state;
    logic       axi_req_seen;
    logic [ADDR_WIDTH-1:0] axi_addr_reg;
    logic [DATA_WIDTH-1:0] axi_wdata_reg;
    logic                  axi_write_reg;
    logic [DATA_WIDTH-1:0] axi_rsp_rdata_reg;
    logic                  axi_rsp_error_reg;
    logic                  axi_rsp_valid_reg;

    // Multiplexed memory-side APB signals.
    logic                  mem_psel;
    logic                  mem_penable;
    logic                  mem_pwrite;
    logic [ADDR_WIDTH-1:0] mem_paddr;
    logic [DATA_WIDTH-1:0] mem_pwdata;
    logic [DATA_WIDTH-1:0] mem_prdata;
    logic                  mem_pready;
    logic                  mem_pslverr;

    wire axi_transfer_active = (axi_state != AXI_IDLE);
    wire accept_axi_request = req_valid_sync && !axi_req_seen &&
                              !axi_transfer_active && !axi_rsp_valid_reg &&
                              !PSEL;

    always_ff @(posedge PCLK) begin
        if (!PRESETn) begin
            req_valid_meta <= 1'b0;
            req_valid_sync <= 1'b0;
            rsp_ready_meta <= 1'b0;
            rsp_ready_sync <= 1'b0;
        end else begin
            req_valid_meta <= axi_req_valid;
            req_valid_sync <= req_valid_meta;
            rsp_ready_meta <= axi_rsp_ready;
            rsp_ready_sync <= rsp_ready_meta;
        end
    end

    always_ff @(posedge PCLK) begin
        if (!PRESETn) begin
            axi_state         <= AXI_IDLE;
            axi_req_seen      <= 1'b0;
            axi_addr_reg      <= '0;
            axi_wdata_reg     <= '0;
            axi_write_reg     <= 1'b0;
            axi_rsp_rdata_reg <= '0;
            axi_rsp_error_reg <= 1'b0;
            axi_rsp_valid_reg <= 1'b0;
        end else begin
            // Acknowledge one source request until its synchronized valid has
            // dropped. The bridge will not issue a second request before that
            // acknowledgement is observed low again.
            if (!req_valid_sync)
                axi_req_seen <= 1'b0;

            if (accept_axi_request) begin
                axi_req_seen  <= 1'b1;
                axi_addr_reg  <= axi_req_addr;
                axi_wdata_reg <= axi_req_wdata;
                axi_write_reg <= axi_req_write;
                axi_state     <= AXI_SETUP;
            end else if (axi_state == AXI_SETUP) begin
                axi_state <= AXI_ACCESS;
            end else if (axi_state == AXI_ACCESS && mem_pready) begin
                axi_rsp_rdata_reg <= mem_prdata;
                axi_rsp_error_reg <= mem_pslverr;
                axi_rsp_valid_reg <= 1'b1;
                axi_state         <= AXI_IDLE;
            end

            if (axi_rsp_valid_reg && rsp_ready_sync)
                axi_rsp_valid_reg <= 1'b0;
        end
    end

    assign axi_req_ready = axi_req_seen;
    assign axi_rsp_valid = axi_rsp_valid_reg;
    assign axi_rsp_rdata = axi_rsp_rdata_reg;
    assign axi_rsp_error = axi_rsp_error_reg;

    always_comb begin
        if (axi_transfer_active) begin
            mem_psel    = 1'b1;
            mem_penable = (axi_state == AXI_ACCESS);
            mem_pwrite  = axi_write_reg;
            mem_paddr   = axi_addr_reg;
            mem_pwdata  = axi_wdata_reg;

            PRDATA      = '0;
            PREADY      = 1'b0;
            PSLVERR     = 1'b0;
        end else begin
            mem_psel    = PSEL;
            mem_penable = PENABLE;
            mem_pwrite  = PWRITE;
            mem_paddr   = PADDR;
            mem_pwdata  = PWDATA;

            PRDATA      = mem_prdata;
            PREADY      = mem_pready;
            PSLVERR     = mem_pslverr;
        end
    end

    apb_mem #(
        .ADDR_WIDTH (ADDR_WIDTH),
        .DATA_WIDTH (DATA_WIDTH)
    ) u_mem (
        .PCLK    (PCLK),
        .PRESETn (PRESETn),
        .PSEL    (mem_psel),
        .PENABLE (mem_penable),
        .PWRITE  (mem_pwrite),
        .PADDR   (mem_paddr),
        .PWDATA  (mem_pwdata),
        .PRDATA  (mem_prdata),
        .PREADY  (mem_pready),
        .PSLVERR (mem_pslverr)
    );

endmodule

`endif // AXI_APB_MEM_SV
