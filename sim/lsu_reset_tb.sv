`timescale 1ns/1ps
import gpu_pkg::*;
module lsu_reset_tb;
    reg clk = 0;
    always #5 clk = ~clk;
    reg rst_n = 0;
    operand_if op();
    wb_if wb();
    ctx_wb_if ctx();
    wire ready, req_valid;
    wire [31:0] req_addr;
    wire [DATA_W-1:0] req_data;
    wire req_we;
    wire [7:0] req_strb;
    reg rsp_valid = 0;
    reg [DATA_W-1:0] rsp_data = 0;
    lsu dut(.clk(clk), .rst_n(rst_n), .op(op), .lsu_ready(ready),
        .l1_req_valid(req_valid), .l1_req_addr(req_addr), .l1_req_wdata(req_data),
        .l1_req_we(req_we), .l1_req_wstrb(req_strb), .l1_req_ready(1'b1),
        .l1_rsp_valid(rsp_valid), .l1_rsp_rdata(rsp_data), .wb(wb), .ctx_wb(ctx));
    task automatic reset_lsu;
        @(negedge clk); rst_n = 0; op.valid = 0; rsp_valid = 0;
        repeat (3) @(negedge clk);
        if (req_valid || wb.valid || ctx.valid || dut.fifo_count != 0)
            $fatal(1, "Reset did not clear LSU control state");
        rst_n = 1;
    endtask
    task automatic enqueue;
        @(negedge clk); op.valid = 1;
        @(negedge clk); op.valid = 0;
    endtask
    task automatic respond(input [31:0] value);
        wait (dut.state == 2'd2);
        @(negedge clk); rsp_valid = 1; rsp_data = {value, value};
        @(negedge clk); rsp_valid = 0;
    endtask
    initial begin
        op.valid = 0; op.opcode = 8'hA0; op.warp_id = 0;
        op.rd = 1; op.pc = 12'd7; op.active_mask = 3;
        op.rs1_data = {32'h1008, 32'h1000}; op.rs2_data = 0;
        reset_lsu();
        // Abort a divergent load after its first lane response.
        enqueue(); respond(32'hdeadbeef);
        wait (dut.state == 2'd2);
        reset_lsu();
        // Both lane values must come from the new transaction, not old payload.
        enqueue(); respond(32'h12345678); respond(32'habcdef01);
        if (!wb.valid || !ctx.valid || wb.data !== 64'habcdef0112345678 ||
            wb.rd != 1 || wb.mask != 3 || ctx.next_pc != 8)
            $fatal(1, "Post-reset divergent load returned stale or misaligned data");
        @(negedge clk);
        if (wb.valid || ctx.valid) $fatal(1, "Completion repeated");
        $display("PASS LSU reset abort and payload overwrite");
        $finish;
    end
    initial begin #10000; $fatal(1, "LSU reset test timeout"); end
endmodule
