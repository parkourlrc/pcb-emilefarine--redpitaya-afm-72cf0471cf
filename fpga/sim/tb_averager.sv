`timescale 1ns / 1ps

// Unit test of averager.sv at every decimation the server accepts (16 to 1024).
// A stored word must read back as the mean ADC code once the server drops its
// precision bits (DacCodec::adcToVoltage: 2 bits below dec 64, 3 bits above).
module tb_averager;

  localparam int DATA_WIDTH = 14;
  localparam int ADDR_WIDTH = 16;
  localparam int PREC_BIT = 3;
  localparam int BLOCKS = 4;

  logic clk = 1'b0;
  logic reset_n = 1'b0;
  logic enabled = 1'b0;
  logic [10:0] decimation_value = 11'd64;
  logic signed [DATA_WIDTH-1:0] adc_data = '0;
  logic [ADDR_WIDTH-1:0] bram_addr;
  logic signed [DATA_WIDTH+PREC_BIT-1:0] bram_in;
  logic bram_we;
  logic [ADDR_WIDTH-1:0] averaged_sample_count;

  averager #(
      .DATA_WIDTH(DATA_WIDTH),
      .ADDR_WIDTH(ADDR_WIDTH),
      .PREC_BIT  (PREC_BIT)
  ) dut (
      .clk                  (clk),
      .reset_n              (reset_n),
      .enabled              (enabled),
      .decimation_value     (decimation_value),
      .adc_data             (adc_data),
      .bram_addr            (bram_addr),
      .bram_in              (bram_in),
      .bram_we              (bram_we),
      .averaged_sample_count(averaged_sample_count)
  );

  always #4 clk = ~clk;  // 125 MHz

  int errors = 0;
  int checks = 0;

  int write_count;
  int written_addr[BLOCKS];
  int written_word[BLOCKS];

  always @(posedge clk) begin
    if (bram_we && write_count < BLOCKS) begin
      written_addr[write_count] = bram_addr;
      written_word[write_count] = bram_in;
    end
    if (bram_we) write_count++;
  end

  function automatic int precision_bits(int dec);
    return (dec < 64) ? 2 : 3;
  endfunction

  function automatic int floor_div(int num, int den);
    int q = num / den;
    if ((num % den != 0) && ((num < 0) != (den < 0))) q--;
    return q;
  endfunction

  task automatic check(input bit ok, input string what);
    checks++;
    if (!ok) begin
      errors++;
      $display("FAIL: %s", what);
    end
  endtask

  // Feed BLOCKS * dec samples, sample i = code_of(i), then compare each stored word
  // with the floor of the block sum scaled to the server's precision.
  task automatic run_blocks(input int dec, input int base, input int slope, input string label);
    int prec = precision_bits(dec);
    int shift = $clog2(dec) - prec;

    @(negedge clk);
    decimation_value = 11'(dec);
    write_count = 0;
    enabled = 1'b1;
    for (int i = 0; i < BLOCKS * dec; i++) begin
      adc_data = 14'(base + slope * i);
      @(negedge clk);
    end
    enabled = 1'b0;
    adc_data = '0;
    repeat (4) @(negedge clk);

    check(write_count == BLOCKS,
          $sformatf("%s dec %0d: %0d writes, expected %0d", label, dec, write_count, BLOCKS));
    for (int b = 0; b < BLOCKS && b < write_count; b++) begin
      int sum = 0;
      int expected;
      for (int i = b * dec; i < (b + 1) * dec; i++) sum += base + slope * i;
      expected = floor_div(sum, 1 << shift);
      check(written_addr[b] == b,
            $sformatf("%s dec %0d block %0d: address %0d, expected %0d", label, dec, b,
                      written_addr[b], b));
      check(written_word[b] == expected,
            $sformatf("%s dec %0d block %0d: word %0d, expected %0d (gain %.4f)", label, dec, b,
                      written_word[b], expected, real'(written_word[b]) / real'(expected)));
    end
  endtask

  initial begin
    repeat (3) @(negedge clk);
    reset_n = 1'b1;

    for (int dec = 16; dec <= 1024; dec *= 2) begin
      run_blocks(dec, 8191, 0, "positive rail");
      run_blocks(dec, -8192, 0, "negative rail");
      run_blocks(dec, 1234, 0, "constant");
      run_blocks(dec, -100, 1, "ramp");
    end

    $display("%0d checks, %0d failed", checks, errors);
    if (errors == 0) $display("RESULT: PASS");
    else $display("RESULT: FAIL");
    $finish;
  end

endmodule
