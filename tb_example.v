`timescale 1ns/1ps

module tb_example;
    
    // Clock and reset
    reg CLK;
    reg RST_N;
    
    // Interface signals - from mkExample.v
    reg [7:0] put_val;
    reg EN_put;
    wire RDY_put;
    
    wire [7:0] get;
    wire RDY_get;
    reg EN_get;
    
    wire isEmpty;
    wire RDY_isEmpty;
    
    // Instantiate the module
    mkExample dut (
        .CLK(CLK),
        .RST_N(RST_N),
        .put_val(put_val),
        .EN_put(EN_put),
        .RDY_put(RDY_put),
        .get(get),
        .EN_get(EN_get),
        .RDY_get(RDY_get),
        .isEmpty(isEmpty),
        .RDY_isEmpty(RDY_isEmpty)
    );
    
    // Clock generation
    initial begin
        CLK = 0;
        forever #5 CLK = ~CLK;  // 10ns period (100MHz)
    end
    
    // Test stimulus
    initial begin
        // Open VCD file for waveform viewing
        $dumpfile("example_tb.vcd");
        $dumpvars(0, tb_example);
        
        // Initialize signals
        RST_N = 0;
        EN_put = 0;
        EN_get = 0;
        put_val = 8'h00;
        
        // Reset for a few cycles
        repeat(5) @(posedge CLK);
        RST_N = 1;
        repeat(5) @(posedge CLK);
        
        // Test 1: Put a small value (tests branch: data <= 50)
        put_val = 8'd30;
        EN_put = 1;
        @(posedge CLK);
        EN_put = 0;
        repeat(10) @(posedge CLK);
        
        // Test 2: Get the value
        EN_get = 1;
        @(posedge CLK);
        EN_get = 0;
        repeat(5) @(posedge CLK);
        
        // Test 3: Put a large value (tests branch: data > 50)
        put_val = 8'd100;
        EN_put = 1;
        @(posedge CLK);
        EN_put = 0;
        repeat(15) @(posedge CLK);
        
        // Test 4: Get the value
        EN_get = 1;
        @(posedge CLK);
        EN_get = 0;
        repeat(5) @(posedge CLK);
        
        // Test 5: Put values to test different case branches
        // Test case branch: data[7:6] = 00
        put_val = 8'b00101010;
        EN_put = 1;
        @(posedge CLK);
        EN_put = 0;
        repeat(15) @(posedge CLK);
        
        EN_get = 1;
        @(posedge CLK);
        EN_get = 0;
        repeat(5) @(posedge CLK);
        
        // Test case branch: data[7:6] = 01
        put_val = 8'b01101010;
        EN_put = 1;
        @(posedge CLK);
        EN_put = 0;
        repeat(15) @(posedge CLK);
        
        EN_get = 1;
        @(posedge CLK);
        EN_get = 0;
        repeat(5) @(posedge CLK);
        
        // Test case branch: data[7:6] = 10
        put_val = 8'b10101010;
        EN_put = 1;
        @(posedge CLK);
        EN_put = 0;
        repeat(15) @(posedge CLK);
        
        EN_get = 1;
        @(posedge CLK);
        EN_get = 0;
        repeat(5) @(posedge CLK);
        
        // Test case branch: data[7:6] = 11
        put_val = 8'b11101010;
        EN_put = 1;
        @(posedge CLK);
        EN_put = 0;
        repeat(15) @(posedge CLK);
        
        EN_get = 1;
        @(posedge CLK);
        EN_get = 0;
        repeat(10) @(posedge CLK);
        
        $finish;
    end

endmodule
