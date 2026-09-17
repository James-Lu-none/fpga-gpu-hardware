`timescale 1ns / 1ps

module unified_cache #(
    parameter ADDR_W = 32,
    parameter DATA_W = 256,
    parameter NUM_LINES = 64,
    parameter INDEX_BITS = 6,
    parameter TAG_BITS = ADDR_W - 5 - INDEX_BITS
) (
    input wire clk,
    input wire rst_n,
    input wire flush,
    cache_line_if.cache core,
    cache_line_if.client memory
);
    localparam STRB_W = DATA_W / 8;
    localparam [2:0] ST_IDLE = 3'd0;
    localparam [2:0] ST_LOOKUP = 3'd1;
    localparam [2:0] ST_READ_MEM = 3'd2;
    localparam [2:0] ST_WAIT_MEM = 3'd3;
    localparam [2:0] ST_WRITE_MEM = 3'd4;

    (* ram_style = "block" *) reg [DATA_W-1:0] data_ram [0:NUM_LINES-1];
    (* ram_style = "block" *) reg [TAG_BITS-1:0] tag_ram [0:NUM_LINES-1];
    reg valid_ram [0:NUM_LINES-1];

    reg [DATA_W-1:0] data_dout;
    reg [TAG_BITS-1:0] tag_dout;
    reg valid_dout;
    reg [2:0] state;

    reg [ADDR_W-1:0] req_addr_q;
    reg [DATA_W-1:0] req_wdata_q;
    reg [STRB_W-1:0] req_wstrb_q;
    reg req_we_q;
    reg [INDEX_BITS-1:0] req_index_q;
    reg [TAG_BITS-1:0] req_tag_q;

    wire [INDEX_BITS-1:0] core_index = core.req_addr[5 +: INDEX_BITS];
    wire [TAG_BITS-1:0] core_tag = core.req_addr[5 + INDEX_BITS +: TAG_BITS];
    wire [ADDR_W-1:0] req_line_addr = {req_addr_q[ADDR_W-1:5], 5'd0};

    assign core.req_ready = (state == ST_IDLE);
    assign memory.req_valid = (state == ST_READ_MEM) || (state == ST_WRITE_MEM);
    assign memory.req_addr = req_line_addr;
    assign memory.req_wdata = req_wdata_q;
    assign memory.req_wstrb = req_wstrb_q;
    assign memory.req_we = req_we_q;
    assign memory.rsp_ready = (state == ST_WAIT_MEM);

    integer i;
    initial begin
        for (i = 0; i < NUM_LINES; i = i + 1) begin
            valid_ram[i] = 1'b0;
            tag_ram[i] = '0;
            data_ram[i] = '0;
        end
    end

    always @(posedge clk) begin
        if (state == ST_IDLE && core.req_valid && core.req_ready) begin
            data_dout <= data_ram[core_index];
            tag_dout <= tag_ram[core_index];
            valid_dout <= valid_ram[core_index];
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= ST_IDLE;
            core.rsp_valid <= 1'b0;
            core.rsp_rdata <= '0;
            req_addr_q <= '0;
            req_wdata_q <= '0;
            req_wstrb_q <= '0;
            req_we_q <= 1'b0;
            req_index_q <= '0;
            req_tag_q <= '0;
            for (i = 0; i < NUM_LINES; i = i + 1) begin
                valid_ram[i] = 1'b0;
            end
        end else if (flush) begin
            state <= ST_IDLE;
            core.rsp_valid <= 1'b0;
            for (i = 0; i < NUM_LINES; i = i + 1) begin
                valid_ram[i] = 1'b0;
            end
        end else begin
            core.rsp_valid <= 1'b0;

            case (state)
                ST_IDLE: begin
                    if (core.req_valid && core.req_ready) begin
                        req_addr_q <= core.req_addr;
                        req_wdata_q <= core.req_wdata;
                        req_wstrb_q <= core.req_wstrb;
                        req_we_q <= core.req_we;
                        req_index_q <= core_index;
                        req_tag_q <= core_tag;
                        state <= ST_LOOKUP;
                    end
                end

                ST_LOOKUP: begin
                    if (valid_dout && tag_dout == req_tag_q && !req_we_q) begin
                        core.rsp_valid <= 1'b1;
                        core.rsp_rdata <= data_dout;
                        state <= ST_IDLE;
                    end else begin
                        if (req_we_q) begin
                            valid_ram[req_index_q] <= 1'b0;
                            state <= ST_WRITE_MEM;
                        end else begin
                            state <= ST_READ_MEM;
                        end
                    end
                end

                ST_READ_MEM: begin
                    if (memory.req_valid && memory.req_ready) begin
                        state <= ST_WAIT_MEM;
                    end
                end

                ST_WAIT_MEM: begin
                    if (memory.rsp_valid && memory.rsp_ready) begin
                        data_ram[req_index_q] <= memory.rsp_rdata;
                        tag_ram[req_index_q] <= req_tag_q;
                        valid_ram[req_index_q] <= 1'b1;
                        core.rsp_valid <= 1'b1;
                        core.rsp_rdata <= memory.rsp_rdata;
                        state <= ST_IDLE;
                    end
                end

                ST_WRITE_MEM: begin
                    if (memory.req_valid && memory.req_ready) begin
                        state <= ST_WAIT_MEM;
                    end
                end

                default: state <= ST_IDLE;
            endcase
        end
    end
endmodule