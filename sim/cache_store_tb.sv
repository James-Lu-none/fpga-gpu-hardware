`timescale 1ns / 1ps
// A write acknowledgement carries no cache-line data. Poison it deliberately.
module cache_store_tb;
    bit clk = 0;
    always #5 clk = ~clk;
    bit rst_n = 0;
    cache_line_if core();
    cache_line_if memory_bus();
    unified_cache dut (.clk(clk), .rst_n(rst_n), .flush(1'b0),
                       .core(core), .memory(memory_bus));
    reg [255:0] backing;
    integer reads = 0;
    assign memory_bus.req_ready = !memory_bus.rsp_valid;
    always @(posedge clk) begin
        if (!rst_n) begin
            memory_bus.rsp_valid <= 0;
            memory_bus.rsp_rdata <= '0;
            backing <= {8{32'h11223344}};
        end else begin
            if (memory_bus.rsp_valid && memory_bus.rsp_ready)
                memory_bus.rsp_valid <= 0;
            if (memory_bus.req_valid && memory_bus.req_ready) begin
                if (memory_bus.req_we) begin
                    for (int b = 0; b < 32; b++)
                        if (memory_bus.req_wstrb[b])
                            backing[b*8 +: 8] <= memory_bus.req_wdata[b*8 +: 8];
                    memory_bus.rsp_rdata <= {8{32'hDEADBEEF}};
                end else begin
                    reads <= reads + 1;
                    memory_bus.rsp_rdata <= backing;
                end
                memory_bus.rsp_valid <= 1;
            end
        end
    end

    task automatic access_line(input bit we, input reg [31:0] data,
                               input reg [31:0] strb, output reg [255:0] result);
        @(negedge clk);
        core.req_valid = 1;
        core.req_we = we;
        core.req_addr = 32'h10000;
        core.req_wdata = {224'd0, data};
        core.req_wstrb = strb;
        do @(posedge clk); while (!core.req_ready);
        @(negedge clk);
        core.req_valid = 0;
        while (!core.rsp_valid) @(negedge clk);
        result = core.rsp_rdata;
    endtask

    reg [255:0] result;
    initial begin
        core.req_valid = 0;
        core.req_we = 0;
        core.req_addr = 0;
        core.req_wdata = 0;
        core.req_wstrb = 0;
        core.rsp_ready = 1;
        repeat (3) @(negedge clk);
        rst_n = 1;
        // Store miss: subsequent load must fetch the updated line, not the B payload.
        access_line(1, 32'h55667788, 32'hF, result);
        access_line(0, 0, 0, result);
        if (result !== backing || reads != 1)
            $fatal(1, "Store miss poisoned cache: data=%h expected=%h reads=%0d", result, backing, reads);
        // Store hit: partial write must preserve all untouched bytes on refill.
        access_line(1, 32'h000000AA, 32'h1, result);
        access_line(0, 0, 0, result);
        if (result !== backing || result[31:0] !== 32'h556677AA || reads != 2)
            $fatal(1, "Partial store hit poisoned cache: %h", result);
        access_line(0, 0, 0, result);
        if (result !== backing || reads != 2)
            $fatal(1, "Read refill was not cached correctly");
        $display("PASS: store acknowledgement cannot fill cache; partial writes survive refill");
        $finish;
    end
    initial begin
        #10000;
        $fatal(1, "Cache test timed out");
    end
endmodule
