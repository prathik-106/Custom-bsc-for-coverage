// Simple example design to demonstrate coverage instrumentation
// This includes branches, rules, and methods for testing

package ExampleDesign;

interface ExampleIfc;
    method Action put(Bit#(8) val);
    method ActionValue#(Bit#(8)) get();
    method Bit#(1) isEmpty();
endinterface
(*synthesize*)
module mkExample(ExampleIfc);
    Reg#(Bit#(8)) data <- mkReg(0);
    Reg#(Bool) valid <- mkReg(False);
    Reg#(Bit#(32)) counter <- mkReg(0);

    // Process data - demonstrates branches
    rule process_data (valid && counter < 100);
        Bit#(8) result;
        
        // Branch 1: if-else based on data value
        if (data > 50) begin
            result = data + 1;
        end else begin
            result = data - 1;
        end
        
        // Branch 2: case statement
        case (data[7:6])
            2'b00: data <= result;
            2'b01: data <= result + 10;
            2'b10: data <= result + 20;
            2'b11: data <= result + 30;
        endcase
        
        counter <= counter + 1;
    endrule

    // Reset rule - demonstrates another rule
    rule reset_on_max (counter >= 100);
        counter <= 0;
        valid <= False;
    endrule

    // Methods - demonstrates method coverage
    method Action put(Bit#(8) val) if (!valid);
        data <= val;
        valid <= True;
    endmethod

    method ActionValue#(Bit#(8)) get() if (valid);
        valid <= False;
        return data;
    endmethod

    method Bit#(1) isEmpty();
        return valid ? 1'b0 : 1'b1;
    endmethod

endmodule

endpackage
