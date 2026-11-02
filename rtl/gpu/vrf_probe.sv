`timescale 1ns / 1ps
// Host-controlled write-back/decode inputs isolate the production VRF.
// No instruction fetch, ALU, scheduler or memory-path dependency.
module vrf_probe (
    input wire clk, rst_n,
    input wire write_enable,
    input wire [7:0] write_addr, read_addr,
    input wire [31:0] write_data,
    output reg [31:0] read_data
);
    import gpu_pkg::*;
    reg [31:0] wb_address, wb_mask, data_low, data_high, read_address, tag;
    reg [31:0] writes, snapshots;
    reg [63:0] rs1_snapshot, rs2_snapshot;
    reg [31:0] metadata_snapshot, tag_snapshot, flags_snapshot;
    reg [31:0] read_select_snapshot;
    reg [63:0] raw1_snapshot, raw2_snapshot;
    wire [31:0] read_select;
    wire [63:0] raw1, raw2;
    decode_if decode();
    operand_if op();
    wb_if wb();
    vector_regfile u_vrf(.clk(clk), .rst_n(rst_n), .decode(decode), .op(op), .wb(wb),
                        .debug_read_select(read_select), .debug_rs1_raw(raw1), .debug_rs2_raw(raw2));

    assign wb.warp_id = wb_address[5 +: $clog2(MAX_WARPS)];
    assign wb.rd = wb_address[4:0];
    assign wb.mask = wb_mask;
    assign wb.data = {data_high, data_low};
    assign decode.warp_id = read_address[10 +: $clog2(MAX_WARPS)];
    assign decode.rs1 = read_address[4:0];
    assign decode.rs2 = read_address[9:5];
    assign decode.pc = tag[11:0];
    assign decode.imm = tag;
    assign decode.opcode = 8'ha1;
    assign decode.rd = 5'd7;
    assign decode.is_imm = 0;
    assign decode.active_mask = 3;
    assign decode.block_idx_x = 0;
    assign decode.block_idx_y = 0;
    assign decode.thread_id_start = 0;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wb_address <= 0;
            wb_mask <= 0;
            data_low <= 0;
            data_high <= 0;
            read_address <= 0;
            tag <= 0;
            wb.valid <= 0;
            decode.valid <= 0;
            writes <= 0;
            snapshots <= 0;
            rs1_snapshot <= 0;
            rs2_snapshot <= 0;
            metadata_snapshot <= 0;
            tag_snapshot <= 0;
            flags_snapshot <= 0;
            read_select_snapshot <= 0;
            raw1_snapshot <= 0;
            raw2_snapshot <= 0;
        end else begin
            wb.valid <= 0;
            decode.valid <= 0;
            if (write_enable) begin
                case (write_addr)
                    8'h44: begin
                        wb.valid <= write_data[0];
                        decode.valid <= write_data[1];
                    end
                    8'h48: wb_address <= write_data;
                    8'h4c: wb_mask <= write_data;
                    8'h50: data_low <= write_data;
                    8'h54: data_high <= write_data;
                    8'h58: read_address <= write_data;
                    8'h5c: tag <= write_data;
                    default: ;
                endcase
            end
            // Count the edge on which VRF actually consumes write-back.
            if (wb.valid) writes <= writes + 1'b1;
            if (op.valid) begin
                snapshots <= snapshots + 1'b1;
                rs1_snapshot <= op.rs1_data;
                rs2_snapshot <= op.rs2_data;
                metadata_snapshot <= (32'(op.warp_id) << 16) | {20'd0, op.pc};
                tag_snapshot <= op.imm;
                flags_snapshot <= {7'd0, op.is_imm, op.opcode, 14'd0, op.active_mask[1:0]};
                read_select_snapshot <= read_select;
                raw1_snapshot <= raw1;
                raw2_snapshot <= raw2;
            end
        end
    end
    always_comb begin
        case (read_addr)
            8'h40: read_data = 32'h56524631; // VRF1
            8'h44: read_data = writes;
            8'h48: read_data = wb_address;
            8'h4c: read_data = wb_mask;
            8'h50: read_data = data_low;
            8'h54: read_data = data_high;
            8'h58: read_data = read_address;
            8'h5c: read_data = tag;
            8'h60: read_data = snapshots;
            8'h64: read_data = rs1_snapshot[31:0];
            8'h68: read_data = rs1_snapshot[63:32];
            8'h6c: read_data = rs2_snapshot[31:0];
            8'h70: read_data = rs2_snapshot[63:32];
            8'h74: read_data = metadata_snapshot;
            8'h78: read_data = tag_snapshot;
            8'h7c: read_data = flags_snapshot;
            8'h80: read_data = (32'(NUM_LANES) << 16) | (32'(MAX_WARPS) << 8) | 32'(NUM_REGS);
            8'h84: read_data = 1; // Internal-stage snapshot version.
            8'h88: read_data = read_select_snapshot;
            8'h8c: read_data = raw1_snapshot[31:0];
            8'h90: read_data = raw1_snapshot[63:32];
            8'h94: read_data = raw2_snapshot[31:0];
            8'h98: read_data = raw2_snapshot[63:32];
            default: read_data = 0;
        endcase
    end
endmodule
