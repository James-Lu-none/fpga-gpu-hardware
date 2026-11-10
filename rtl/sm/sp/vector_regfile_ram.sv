`timescale 1ns / 1ps
// FPGA storage for one 32-bit VRF lane: replicated synchronous RAMs provide
// two reads alongside write-back. The ASIC implementation shares this boundary
// but deasserts read_ready while its single 1RW1R macro is writing.
module vector_regfile_ram #(
    parameter integer DEPTH = 256,
    parameter integer ADDR_W = $clog2(DEPTH)
)(
    input wire clk,
    input wire write_enable,
    input wire [ADDR_W-1:0] write_address,
    input wire [31:0] write_data,
    input wire read_enable,
    output wire read_ready,
    input wire [ADDR_W-1:0] read_address1,
    input wire [ADDR_W-1:0] read_address2,
    output wire [31:0] read_data1,
    output wire [31:0] read_data2
);
    assign read_ready = 1'b1;
    // Keep full-word banks in separate modules: this is the FPGA inference
    // structure qualified by the existing hardware VRF regression.
    vector_regfile_lane_bank #(.DEPTH(DEPTH), .ADDR_W(ADDR_W)) u_rs1 (
        .clk(clk), .write_enable(write_enable), .write_address(write_address),
        .write_data(write_data), .read_address(read_address1), .read_data(read_data1)
    );
    vector_regfile_lane_bank #(.DEPTH(DEPTH), .ADDR_W(ADDR_W)) u_rs2 (
        .clk(clk), .write_enable(write_enable), .write_address(write_address),
        .write_data(write_data), .read_address(read_address2), .read_data(read_data2)
    );
endmodule

// One independent inferred 1R1W bank. Reads may run while read_enable on the
// public storage boundary is low; only accepted reads are consumed upstream.
module vector_regfile_lane_bank #(
    parameter integer DEPTH = 256,
    parameter integer ADDR_W = $clog2(DEPTH)
)(
    input wire clk,
    input wire write_enable,
    input wire [ADDR_W-1:0] write_address,
    input wire [31:0] write_data,
    input wire [ADDR_W-1:0] read_address,
    output reg [31:0] read_data
);
    (* ram_style = "block" *) reg [31:0] words [0:DEPTH-1];
    always @(posedge clk) begin
        if (write_enable) words[write_address] <= write_data;
    end
    always @(posedge clk) begin
        read_data <= words[read_address];
    end
endmodule
