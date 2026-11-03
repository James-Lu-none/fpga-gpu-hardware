`timescale 1ns / 1ps
// AXI4 memory for the GPC's 256-bit, single-beat cache-line transactions.
// AW and W are buffered independently. Responses persist until accepted.
module axi_vram_model (
    input wire clk, rst_n,
    axi4_if.slave bus,
    output integer reads,
    output integer writes
);
    localparam MEMORY_BYTES = 65536;
    reg [63:0] memory [0:MEMORY_BYTES/8-1];
    reg have_aw = 0, have_w = 0;
    reg [31:0] write_addr;
    reg [255:0] write_data;
    reg [31:0] write_strb;
    reg write_id;
    integer cycle = 0, read_delay = 0, write_delay = 0;
    reg [255:0] pending_read;
    reg pending_read_id;
    string memory_path;
    initial begin
        reads = 0;
        writes = 0;
        for (int i = 0; i < MEMORY_BYTES/8; i++) memory[i] = 0;
        if (!$value$plusargs("memory=%s", memory_path)) $fatal(1, "Missing VRAM image");
        begin
            integer f;
            f = $fopen(memory_path, "r");
            if (f == 0) $fatal(1, "Cannot open VRAM image %s", memory_path);
            $fclose(f);
        end
        $readmemh(memory_path, memory);
    end
    assign bus.awready = rst_n && !have_aw && !bus.bvalid && write_delay == 0 && cycle % 4 != 0;
    assign bus.wready = rst_n && !have_w && !bus.bvalid && write_delay == 0 && cycle % 5 != 0;
    assign bus.arready = rst_n && !bus.rvalid && read_delay == 0 && cycle % 3 != 0;
    assign bus.bresp = 2'b00;
    assign bus.rresp = 2'b00;
    assign bus.rlast = 1'b1;
    always @(posedge clk) begin
        cycle <= cycle + 1;
        if (!rst_n) begin
            have_aw <= 0;
            have_w <= 0;
            bus.bvalid <= 0;
            bus.rvalid <= 0;
            bus.bid <= 0;
            bus.rid <= 0;
            bus.rdata <= 0;
            read_delay <= 0;
            write_delay <= 0;
        end else begin
            // RDATA is unspecified outside RVALID. Do not accidentally let
            // write responses reuse a previous read's cache-line payload.
            if (!bus.rvalid) bus.rdata <= '0;
            if (bus.awvalid && bus.awready) begin
                if (bus.awlen != 0 || bus.awsize != 5 || bus.awburst != 1 ||
                    bus.awaddr[4:0] != 0 || bus.awaddr >= MEMORY_BYTES)
                    $fatal(1, "Unsupported AXI AW transaction addr=%h", bus.awaddr);
                write_addr <= bus.awaddr;
                write_id <= bus.awid;
                have_aw <= 1;
            end
            if (bus.wvalid && bus.wready) begin
                if (!bus.wlast) $fatal(1, "Single-beat AXI write requires WLAST");
                write_data <= bus.wdata;
                write_strb <= bus.wstrb;
                have_w <= 1;
            end
            if (have_aw && have_w) begin
                for (int b = 0; b < 32; b++)
                    if (write_strb[b]) memory[(write_addr+b)/8][((write_addr+b)%8)*8 +: 8] <= write_data[b*8 +: 8];
                have_aw <= 0;
                have_w <= 0;
                write_delay <= 3 + cycle % 5;
                writes <= writes + 1;
            end
            if (write_delay > 0) begin
                write_delay <= write_delay - 1;
                if (write_delay == 1) begin
                    bus.bvalid <= 1;
                    bus.bid <= write_id;
                end
            end
            if (bus.bvalid && bus.bready) bus.bvalid <= 0;
            if (bus.arvalid && bus.arready) begin
                if (bus.arlen != 0 || bus.arsize != 5 || bus.arburst != 1 ||
                    bus.araddr[4:0] != 0 || bus.araddr >= MEMORY_BYTES)
                    $fatal(1, "Unsupported AXI AR transaction addr=%h", bus.araddr);
                for (int q = 0; q < 4; q++) pending_read[q*64 +: 64] <= memory[bus.araddr/8+q];
                pending_read_id <= bus.arid;
                read_delay <= 3 + cycle % 7;
                reads <= reads + 1;
            end
            if (read_delay > 0) begin
                read_delay <= read_delay - 1;
                if (read_delay == 1) begin
                    bus.rvalid <= 1;
                    bus.rdata <= pending_read;
                    bus.rid <= pending_read_id;
                end
            end
            if (bus.rvalid && bus.rready) bus.rvalid <= 0;
        end
    end
    task automatic dump(input string path);
        integer f;
        f = $fopen(path, "wb");
        if (f == 0) $fatal(1, "Cannot open VRAM dump");
        for (int a = 0; a < MEMORY_BYTES; a++) $fwrite(f, "%c", memory[a/8][(a%8)*8 +: 8]);
        $fclose(f);
    endtask
endmodule
