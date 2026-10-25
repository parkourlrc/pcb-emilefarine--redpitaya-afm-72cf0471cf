`timescale 1ns / 1ps

// System test of one measurement through the PS bus, wired as in red_pitaya_top.sv:
// ps_pl_interface_wrapper (registers + shared BRAM) and measure_ctrl.
// The test plays the role of afm_server: fill the BRAM, set the registers, start,
// poll END, read COUNT and the acquired words, acknowledge.
module tb_measure;

  localparam int DATA_W = 14;
  localparam int ACQ_DATA_W = 17;
  localparam int ADDR_W = 16;
  localparam int DEPTH = 1 << ADDR_W;

  localparam logic [31:0] BRAM_BASE = 32'h4060_0000;
  localparam logic [31:0] REG_BASE = 32'h4064_0000;
  localparam int REG_START = 2;
  localparam int REG_DELAY = 3;
  localparam int REG_SIG_SIZE = 4;
  localparam int REG_END = 5;
  localparam int REG_COUNT = 6;
  localparam int REG_DECIMATION = 8;
  localparam int REG_STATUS = 9;
  localparam logic [31:0] MARKER = 32'h1F00;  // above every pattern value

  logic clk = 1'b0;
  logic rstn = 1'b0;
  always #4 clk = ~clk;  // 125 MHz

  // PS system bus
  logic [31:0] sys_addr = '0;
  logic [31:0] sys_wdata = '0;
  logic sys_wen = 1'b0;
  logic sys_ren = 1'b0;
  logic [31:0] sys_rdata;
  logic sys_err;
  logic sys_ack;

  // Wires between the two blocks, named as in red_pitaya_top.sv
  logic gen_bram_ren;
  logic [ADDR_W-1:0] gen_bram_addr;
  logic [DATA_W-1:0] gen_bram_data;
  logic acq_bram_wen;
  logic [ADDR_W-1:0] acq_bram_addr;
  logic [ACQ_DATA_W-1:0] acq_bram_data;
  logic start_measure;
  logic [31:0] sig_size;
  logic [31:0] delay;
  logic [10:0] decimation;
  logic end_measure;
  logic [31:0] count_measure;
  logic busy;

  logic signed [DATA_W-1:0] adc_data = '0;
  logic signed [DATA_W-1:0] dac_data;

  ps_pl_interface_wrapper #(
      .GEN_BRAM_ADDR_WIDTH(ADDR_W),
      .GEN_BRAM_DATA_WIDTH(DATA_W),
      .ACQ_BRAM_ADDR_WIDTH(ADDR_W),
      .ACQ_BRAM_DATA_WIDTH(ACQ_DATA_W)
  ) iface (
      .sys_clk_i      (clk),
      .sys_rstn_i     (rstn),
      .sys_addr_i     (sys_addr),
      .sys_wdata_i    (sys_wdata),
      .sys_sel_i      (4'b1111),
      .sys_wen_i      (sys_wen),
      .sys_ren_i      (sys_ren),
      .sys_rdata_o    (sys_rdata),
      .sys_err_o      (sys_err),
      .sys_ack_o      (sys_ack),
      .ren_gen_i      (gen_bram_ren),
      .addr_gen_i     (gen_bram_addr),
      .dout_gen_o     (gen_bram_data),
      .wen_acq_i      (acq_bram_wen),
      .addr_acq_i     (acq_bram_addr),
      .din_acq_i      (acq_bram_data),
      .start_measure_o(start_measure),
      .sig_size_o     (sig_size),
      .delay_o        (delay),
      .decimation_o   (decimation),
      .busy_i         (busy),
      .end_measure_i  (end_measure),
      .count_measure_i(count_measure)
  );

  measure_ctrl #(
      .DATA_WIDTH(DATA_W),
      .PREC_BIT  (3),
      .ADDR_WIDTH(ADDR_W),
      .GEN_ADDR_W(ADDR_W)
  ) ctrl (
      .clk           (clk),
      .rstn          (rstn),
      .start_measure (start_measure),
      .sig_size      (sig_size),
      .delay         (delay),
      .decimation_reg(decimation),
      .end_measure   (end_measure),
      .count_measure (count_measure),
      .busy_o        (busy),
      .adc_data      (adc_data),
      .gen_out       (dac_data),
      .bram_out      (gen_bram_data),
      .bram_en       (gen_bram_ren),
      .bram_addr     (gen_bram_addr),
      .bram_in_addr  (acq_bram_addr),
      .bram_in_data  (acq_bram_data),
      .bram_we       (acq_bram_wen)
  );

  int errors = 0;
  int checks = 0;

  task automatic check(input bit ok, input string what);
    checks++;
    if (!ok) begin
      errors++;
      $display("FAIL: %s", what);
    end
  endtask

  // --- Port monitors: what the decimator played and where the averager wrote ---
  int played[$];
  int written_addr[$];
  bit marker_on_dac;

  always @(posedge clk) begin
    if (ctrl.u_decimator.bram_read_active_q) played.push_back(gen_bram_data);
    if (acq_bram_wen) written_addr.push_back(acq_bram_addr);
    if (dac_data == DATA_W'(MARKER)) marker_on_dac = 1'b1;
  end

  // --- Bus access, one transaction at a time, address held until ack ---
  task automatic bus_write(input logic [31:0] addr, input logic [31:0] data);
    @(negedge clk);
    sys_addr  = addr;
    sys_wdata = data;
    sys_wen   = 1'b1;
    @(negedge clk);
    sys_wen = 1'b0;
    while (!sys_ack) @(negedge clk);
  endtask

  task automatic bus_read(input logic [31:0] addr, output logic [31:0] data);
    @(negedge clk);
    sys_addr = addr;
    sys_ren  = 1'b1;
    @(negedge clk);
    sys_ren = 1'b0;
    while (!sys_ack) @(negedge clk);
    data = sys_rdata;
  endtask

  task automatic reg_write(input int index, input logic [31:0] data);
    bus_write(REG_BASE + 32'(index * 4), data);
  endtask

  task automatic reg_read(input int index, output logic [31:0] data);
    bus_read(REG_BASE + 32'(index * 4), data);
  endtask

  function automatic int pattern(int i);
    return (i % 4000) + 1;
  endfunction

  // Word the server decodes back to `code` (DacCodec::adcToVoltage precision bits)
  function automatic logic [31:0] expected_word(int code, int dec);
    int prec = (dec < 64) ? 2 : 3;
    return 32'((code * (1 << prec)) & ((1 << ACQ_DATA_W) - 1));
  endfunction

  function automatic int signed_word(logic [31:0] word);
    return word[ACQ_DATA_W-1] ? int'(word) - (1 << ACQ_DATA_W) : int'(word);
  endfunction

  function automatic bit should_read_back(int i, int n);
    return (n <= 1024) || (i < 64) || (i >= n - 64);
  endfunction

  task automatic measure(input int n, input int dec, input int dly, input int code);
    string label = $sformatf("N %0d dec %0d delay %0d code %0d", n, dec, dly, code);
    logic [31:0] value;
    int polls;

    $display("--- %s", label);
    for (int i = 0; i < n; i++) bus_write(BRAM_BASE + 32'(i * 4), 32'(pattern(i)));
    if (n < DEPTH) bus_write(BRAM_BASE + 32'(n * 4), MARKER);

    adc_data = 14'(code);
    played.delete();
    written_addr.delete();
    marker_on_dac = 1'b0;

    reg_write(REG_DECIMATION, 32'(dec));
    reg_write(REG_DELAY, 32'(dly));
    reg_write(REG_SIG_SIZE, 32'(n));
    reg_write(REG_START, 32'd1);

    polls = 0;
    do begin
      repeat (64) @(negedge clk);
      reg_read(REG_END, value);
      polls++;
    end while (value != 32'd1 && polls < 1_000_000);
    check(value == 32'd1, {label, ": END never rose"});

    reg_read(REG_STATUS, value);
    check(value[0] == 1'b0, {label, ": still busy after END"});

    reg_read(REG_COUNT, value);
    check(value == 32'(n), $sformatf("%s: COUNT reads %0d after END, expected %0d", label,
                                     value, n));

    check(written_addr.size() == n, $sformatf("%s: %0d BRAM writes, expected %0d", label,
                                              written_addr.size(), n));
    for (int k = 0; k < written_addr.size() && k < n; k++) begin
      if (written_addr[k] != k) begin
        check(1'b0, $sformatf("%s: write %0d went to address %0d", label, k, written_addr[k]));
        break;
      end
    end

    check(played.size() >= n, $sformatf("%s: %0d samples played, expected %0d", label,
                                        played.size(), n));
    for (int k = 0; k < played.size() && k < n; k++) begin
      if (played[k] != pattern(k)) begin
        check(1'b0, $sformatf("%s: sample %0d played %0d, expected %0d (overwritten early?)",
                              label, k, played[k], pattern(k)));
        break;
      end
    end
    $display("    generation read %0d words for %0d samples", played.size(), n);

    for (int i = 0; i < n; i++) begin
      if (!should_read_back(i, n)) continue;
      bus_read(BRAM_BASE + 32'(i * 4), value);
      if (value != expected_word(code, dec)) begin
        check(1'b0, $sformatf("%s: word %0d reads %0d, expected %0d (gain %.4f)", label, i,
                              signed_word(value), signed_word(expected_word(code, dec)),
                              real'(signed_word(value)) /
                              real'(signed_word(expected_word(code, dec)))));
        break;
      end
    end
    if (n < DEPTH) begin
      bus_read(BRAM_BASE + 32'(n * 4), value);
      check(value == MARKER, $sformatf("%s: word after the last one changed to %0h", label,
                                       value));
      check(!marker_on_dac, {label, ": the word after the last sample reached the DAC"});
    end

    reg_write(REG_START, 32'd0);
    repeat (4) @(negedge clk);
    reg_read(REG_END, value);
    check(value == 32'd0, {label, ": END still set after START=0"});
    reg_read(REG_COUNT, value);
    check(value == 32'(n), $sformatf("%s: COUNT reads %0d after START=0, expected %0d", label,
                                     value, n));
    adc_data = '0;
  endtask

  initial begin
    repeat (4) @(negedge clk);
    rstn = 1'b1;
    repeat (4) @(negedge clk);

    measure(64, 16, 1, 2000);
    measure(64, 64, 3, -3000);
    measure(200, 1024, 1, 8191);
    measure(DEPTH, 16, 1, 1000);

    $display("%0d checks, %0d failed", checks, errors);
    if (errors == 0) $display("RESULT: PASS");
    else $display("RESULT: FAIL");
    $finish;
  end

endmodule
