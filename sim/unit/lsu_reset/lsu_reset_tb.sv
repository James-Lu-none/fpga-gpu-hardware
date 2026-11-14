`timescale 1ns/1ps
`include "gpu_defines.vh"

module lsu_reset_tb;
    reg clk = 0;
    always #5 clk = ~clk;

    reg rst_n = 0;
    operand_if op();
    wb_if wb();
    ctx_wb_if ctx();

    wire ready;
    wire req_valid;
    wire req_is_load;
    wire [$clog2(`MAX_WARPS)-1:0] req_warp_id;
    wire [4:0] req_rd;
    wire [11:0] req_pc;
    wire [`NUM_LANES-1:0] req_mask;
    wire [`WARP_DATA_W-1:0] req_addr;
    wire [`WARP_DATA_W-1:0] req_wdata;
    reg  req_ready = 1'b1;

    reg  rsp_valid = 0;
    reg  [$clog2(`MAX_WARPS)-1:0] rsp_warp_id = 0;
    reg  [4:0] rsp_rd = 0;
    reg  [11:0] rsp_pc = 0;
    reg  [`NUM_LANES-1:0] rsp_mask = 0;
    reg  rsp_is_load = 1;
    reg  [`WARP_DATA_W-1:0] rsp_rdata = '0;

    lsu dut (
        .clk(clk),
        .rst_n(rst_n),
        .op(op),
        .lsu_ready(ready),

        .mem_req_valid(req_valid),
        .mem_req_is_load(req_is_load),
        .mem_req_warp_id(req_warp_id),
        .mem_req_rd(req_rd),
        .mem_req_pc(req_pc),
        .mem_req_mask(req_mask),
        .mem_req_addr(req_addr),
        .mem_req_wdata(req_wdata),
        .mem_req_ready(req_ready),

        .mem_rsp_valid(rsp_valid),
        .mem_rsp_warp_id(rsp_warp_id),
        .mem_rsp_rd(rsp_rd),
        .mem_rsp_pc(rsp_pc),
        .mem_rsp_mask(rsp_mask),
        .mem_rsp_is_load(rsp_is_load),
        .mem_rsp_rdata(rsp_rdata),

        .wb(wb),
        .ctx_wb(ctx)
    );

    task automatic reset_lsu;
        @(negedge clk);
        rst_n = 0;
        op.valid = 0;
        rsp_valid = 0;
        repeat (3) @(negedge clk);
        if (req_valid || wb.valid || ctx.valid || dut.fifo_count != 0)
            $fatal(1, "Reset did not clear LSU control state");
        rst_n = 1;
    endtask

    task automatic enqueue;
        @(negedge clk);
        op.valid = 1;
        @(negedge clk);
        op.valid = 0;
    endtask

    initial begin
        op.valid = 0;
        op.opcode = 8'hA0; // LDR
        op.warp_id = 0;
        op.rd = 1;
        op.pc = 12'd7;
        op.active_mask = 32'h3;
        op.rs1_data = '0;
        op.rs1_data[31:0] = 32'h1000;
        op.rs1_data[63:32] = 32'h1008;
        op.rs2_data = '0;

        reset_lsu();

        // Enqueue load instruction
        req_ready = 0; // Hold back handshake to verify FIFO buffering
        enqueue();
        if (!req_valid || dut.fifo_count != 1 || req_rd != 1 || req_warp_id != 0)
            $fatal(1, "Enqueued request mismatch");

        // Allow request handshake
        @(negedge clk);
        req_ready = 1;
        @(negedge clk);
        req_ready = 0;
        if (dut.fifo_count != 0)
            $fatal(1, "FIFO did not pop on ready handshake");

        // Reset during pending execution
        reset_lsu();

        // New transaction after reset
        enqueue();
        @(negedge clk);
        req_ready = 1;
        @(negedge clk);
        req_ready = 0;

        // Response from Dynamic Coalescing Engine
        @(negedge clk);
        rsp_valid = 1;
        rsp_warp_id = 0;
        rsp_rd = 1;
        rsp_pc = 12'd7;
        rsp_mask = 16'h3;
        rsp_is_load = 1;
        rsp_rdata = '0;
        rsp_rdata[31:0] = 32'h12345678;
        rsp_rdata[63:32] = 32'habcdef01;
        @(negedge clk);
        rsp_valid = 0;

        if (!wb.valid || !ctx.valid || wb.data[63:0] !== 64'habcdef0112345678 ||
            wb.rd != 1 || wb.mask != 3 || ctx.next_pc != 8)
            $fatal(1, "Post-reset load writeback mismatch: wb.valid=%0d wb.data=%h", wb.valid, wb.data[63:0]);

        @(negedge clk);
        if (wb.valid || ctx.valid)
            $fatal(1, "Completion repeated");

        $display("PASS LSU reset abort and payload writeback");
        $finish;
    end

    initial begin
        #10000;
        $fatal(1, "LSU reset test timeout");
    end
endmodule
