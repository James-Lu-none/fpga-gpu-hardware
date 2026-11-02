`timescale 1ns / 1ps
module vector_regfile_tb;
    import gpu_pkg::*;
    reg clk = 0, rst_n = 0;
    always #4 clk = !clk;
    decode_if decode();
    operand_if op();
    wb_if wb();
    vector_regfile dut(.clk(clk), .rst_n(rst_n), .decode(decode), .op(op), .wb(wb));
    reg [63:0] golden [0:MAX_WARPS-1][0:NUM_REGS-1];
    typedef struct packed {
        logic [63:0] rs1, rs2;
        logic [31:0] tag, mask;
        logic [7:0] opcode;
        logic [$clog2(MAX_WARPS)-1:0] warp;
        logic [11:0] pc;
        logic [31:0] cycle;
    } expected_t;
    expected_t pending[$];
    integer cycle = 0, checks = 0, issued = 0, cancelled = 0;
    always @(posedge clk) begin
        expected_t e;
        cycle = cycle + 1;
        if (!rst_n) begin
            cancelled += pending.size();
            pending.delete();
        end
        else begin
            if (op.valid) begin
                if (pending.size() == 0) $fatal(1, "Unexpected operand valid");
                e = pending.pop_front();
                if (cycle - e.cycle != 2 || op.rs1_data !== e.rs1 || op.rs2_data !== e.rs2 ||
                    op.warp_id != e.warp || op.pc != e.pc || op.imm != e.tag ||
                    op.active_mask != e.mask || op.opcode != e.opcode)
                    $fatal(1, "VRF pipeline mismatch warp=%0d pc=%h rs1=%h expected=%h rs2=%h expected=%h latency=%0d",
                           e.warp, e.pc, op.rs1_data, e.rs1, op.rs2_data, e.rs2, cycle-e.cycle);
                checks++;
            end
            if (decode.valid) begin
                e.rs1 = golden[decode.warp_id][decode.rs1];
                e.rs2 = golden[decode.warp_id][decode.rs2];
                e.tag = decode.imm;
                e.mask = decode.active_mask;
                e.opcode = decode.opcode;
                e.warp = decode.warp_id;
                e.pc = decode.pc;
                e.cycle = 32'(cycle);
                pending.push_back(e);
                issued++;
            end
            if (wb.valid && wb.rd != 0)
                for (int lane = 0; lane < NUM_LANES; lane++)
                    if (wb.mask[lane]) golden[wb.warp_id][wb.rd][lane*32 +: 32] = wb.data[lane*32 +: 32];
        end
    end
    task automatic write_reg(input integer warp, rd, mask, input [63:0] data);
        @(negedge clk);
        wb.valid = 1;
        wb.warp_id = $clog2(MAX_WARPS)'(warp);
        wb.rd = 5'(rd);
        wb.mask = 32'(mask);
        wb.data = data;
    endtask
    task automatic read_stream(input bit same_register);
        @(negedge clk); wb.valid = 0;
        repeat (3) @(negedge clk);
        for (int w = 0; w < MAX_WARPS; w++)
            for (int r = 0; r < NUM_REGS; r++) begin
                @(negedge clk);
                decode.valid = 1;
                decode.warp_id = $clog2(MAX_WARPS)'(w);
                decode.rs1 = 5'(r);
                decode.rs2 = same_register ? 5'(r) : 5'(31-r);
                decode.pc = 12'(w*32+r);
                decode.imm = 32'habcd0000 | 32'(w*32+r);
                decode.active_mask = 32'(r%4);
                decode.opcode = r[0] ? 8'ha1 : 8'ha0;
            end
        @(negedge clk); decode.valid = 0;
        repeat (4) @(negedge clk);
        if (pending.size() != 0 || checks + cancelled != issued) $fatal(1, "Missing VRF operands");
    endtask
    initial begin
        wb.valid = 0; wb.warp_id = 0; wb.rd = 0; wb.mask = 0; wb.data = 0;
        decode.valid = 0; decode.warp_id = 0; decode.rs1 = 0; decode.rs2 = 0;
        decode.pc = 0; decode.imm = 0; decode.opcode = 0; decode.rd = 0;
        decode.active_mask = 0; decode.is_imm = 0;
        decode.block_idx_x = 0; decode.block_idx_y = 0; decode.thread_id_start = 0;
        for (int w = 0; w < MAX_WARPS; w++)
            for (int r = 0; r < NUM_REGS; r++) golden[w][r] = 0;
        repeat (5) @(negedge clk);
        rst_n = 1;
        for (int w = 0; w < MAX_WARPS; w++)
            for (int r = 1; r < NUM_REGS; r++)
                write_reg(w, r, 3, {32'h89ab0000 | 32'(w*32+r), 32'h13570000 | 32'(w*32+r)});
        read_stream(0);
        for (int w = 0; w < MAX_WARPS; w++) begin
            for (int r = 1; r < NUM_REGS; r++) begin
                write_reg(w, r, 1, {32'hdeadbeef, 32'h24680000 | 32'(w*32+r)});
                write_reg(w, r, 2, {32'h56780000 | 32'(w*32+r), 32'hdeadbeef});
                write_reg(w, r, 0, 64'hdeadbeefdeadbeef);
            end
            write_reg(w, 0, 3, 64'hffffffffffffffff);
        end
        read_stream(1);
        read_stream(0);
        // Assert reset between clock edges with a decode in flight. Payload
        // and RAM need no reset, but no pre-reset valid may escape afterward.
        @(negedge clk); decode.valid = 1; decode.rs1 = 1; decode.rs2 = 0;
        @(posedge clk); #1; rst_n = 0;
        #1;
        if (op.valid || dut.decode_valid_q) $fatal(1, "Asynchronous valid reset failed");
        repeat (3) begin
            @(negedge clk);
            decode.rs1 = decode.rs1 + 1'b1;
            decode.rs2 = decode.rs2 + 1'b1;
            if (op.valid) $fatal(1, "Operand valid during reset");
        end
        decode.valid = 0;
        rst_n = 1;
        repeat (4) @(negedge clk);
        read_stream(0); // The masked register contents must survive reset.
        if (cancelled != 1) $fatal(1, "Unexpected number of flushed operands");
        $display("PASS: VRF %0d back-to-back operands; ports, masks, R0, two-cycle alignment, asynchronous valid reset and RAM retention", checks);
        $finish;
    end
    initial begin
        #1000000;
        $fatal(1, "VRF test timed out");
    end
endmodule
