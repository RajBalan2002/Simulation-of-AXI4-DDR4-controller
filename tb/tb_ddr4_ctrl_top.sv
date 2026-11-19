// -----------------------------------------------------------------------------
// tb_ddr4_ctrl_top.sv
// Top-level test: AXI4 and APB traffic into the full controller, with the
// behavioral PHY and memory on the DFI side.
//
//   phase 0  program registers over APB, read them back, start initialization
//   phase 1  random AXI writes and reads, one at a time, single-bit errors injected
//   phase 2  writes and reads running concurrently on separate address regions
//   phase 3  directed checks: partial strobes, unsupported bursts, uncorrectable
//            errors and the interrupt, self-refresh through the register
// -----------------------------------------------------------------------------
`timescale 1ns/1ps
module tb_ddr4_ctrl_top #(
  parameter int NOPS = 300        // random operations in phase 1
);
  import ddr4_pkg::*;

  localparam int ID_W    = 4;
  localparam int WADDR_W = AXI_ADDR_W - 3;
  localparam int MAXB    = 256;

  // ------------------------------- clocks -----------------------------------
  logic aclk = 0, cclk = 0, aresetn = 1, crst_n = 1;
  always #5.3 aclk = ~aclk;      // deliberately unrelated to cclk
  always #2.5 cclk = ~cclk;

  // ------------------------------- DUT pins ---------------------------------
  logic [ID_W-1:0]        awid = '0, arid = '0, bid, rid;
  logic [AXI_ADDR_W-1:0]  awaddr = '0, araddr = '0;
  logic [7:0]             awlen = '0, arlen = '0;
  logic [2:0]             awsize = 3'd3, arsize = 3'd3;
  logic [1:0]             awburst = 2'b01, arburst = 2'b01, bresp, rresp;
  logic                   awvalid = 0, awready, wvalid = 0, wready, wlast = 0;
  logic                   bvalid, bready = 0, arvalid = 0, arready, rvalid, rready = 0, rlast;
  logic [DATA_W-1:0]      wdata = '0, rdata;
  logic [DATA_W/8-1:0]    wstrb = '0;
  logic                   psel = 0, penable = 0, pwrite = 0, pready, pslverr, irq;
  logic [11:0]            paddr = '0;
  logic [31:0]            pwdata = '0, prdata;

  logic                             dfi_init_complete = 0;
  logic [DFI_PHASES-1:0]            dfi_reset_n, dfi_cke, dfi_odt, dfi_cs_n, dfi_act_n;
  logic [DFI_PHASES-1:0]            dfi_ras_n, dfi_cas_n, dfi_we_n;
  logic [DFI_PHASES-1:0][BG_W-1:0]  dfi_bg;
  logic [DFI_PHASES-1:0][BA_W-1:0]  dfi_ba;
  logic [DFI_PHASES-1:0][13:0]      dfi_address;
  logic [DFI_PHASES-1:0]            dfi_wrdata_en, dfi_rddata_en, dfi_rddata_valid;
  logic [BURST_CODE_W-1:0]          dfi_wrdata, dfi_rddata;
  logic [BURST_WORDS*9-1:0]         dfi_wrdata_mask;

  ddr4_ctrl_top #(.ID_W(ID_W), .AUTO_START(1'b0)) dut (
    .aclk(aclk), .aresetn(aresetn), .cclk(cclk), .crst_n(crst_n),
    .s_axi_awid(awid), .s_axi_awaddr(awaddr), .s_axi_awlen(awlen), .s_axi_awsize(awsize),
    .s_axi_awburst(awburst), .s_axi_awvalid(awvalid), .s_axi_awready(awready),
    .s_axi_wdata(wdata), .s_axi_wstrb(wstrb), .s_axi_wlast(wlast),
    .s_axi_wvalid(wvalid), .s_axi_wready(wready),
    .s_axi_bid(bid), .s_axi_bresp(bresp), .s_axi_bvalid(bvalid), .s_axi_bready(bready),
    .s_axi_arid(arid), .s_axi_araddr(araddr), .s_axi_arlen(arlen), .s_axi_arsize(arsize),
    .s_axi_arburst(arburst), .s_axi_arvalid(arvalid), .s_axi_arready(arready),
    .s_axi_rid(rid), .s_axi_rdata(rdata), .s_axi_rresp(rresp), .s_axi_rlast(rlast),
    .s_axi_rvalid(rvalid), .s_axi_rready(rready),
    .psel(psel), .penable(penable), .pwrite(pwrite), .paddr(paddr), .pwdata(pwdata),
    .prdata(prdata), .pready(pready), .pslverr(pslverr), .irq(irq),
    .dfi_init_complete(dfi_init_complete),
    .dfi_reset_n(dfi_reset_n), .dfi_cke(dfi_cke), .dfi_odt(dfi_odt),
    .dfi_cs_n(dfi_cs_n), .dfi_act_n(dfi_act_n), .dfi_ras_n(dfi_ras_n),
    .dfi_cas_n(dfi_cas_n), .dfi_we_n(dfi_we_n), .dfi_bg(dfi_bg), .dfi_ba(dfi_ba),
    .dfi_address(dfi_address), .dfi_wrdata_en(dfi_wrdata_en), .dfi_wrdata(dfi_wrdata),
    .dfi_wrdata_mask(dfi_wrdata_mask), .dfi_rddata_en(dfi_rddata_en),
    .dfi_rddata(dfi_rddata), .dfi_rddata_valid(dfi_rddata_valid));

  phy_mem_bfm #(.WR_LAT(2), .RDEN_LAT(3), .RD_PHY_LAT(2)) phy (
    .clk(cclk), .rst_n(crst_n),
    .dfi_cs_n(dfi_cs_n), .dfi_act_n(dfi_act_n), .dfi_ras_n(dfi_ras_n),
    .dfi_cas_n(dfi_cas_n), .dfi_we_n(dfi_we_n), .dfi_bg(dfi_bg), .dfi_ba(dfi_ba),
    .dfi_address(dfi_address), .dfi_wrdata_en(dfi_wrdata_en), .dfi_wrdata(dfi_wrdata),
    .dfi_wrdata_mask(dfi_wrdata_mask), .dfi_rddata_en(dfi_rddata_en),
    .dfi_rddata(dfi_rddata), .dfi_rddata_valid(dfi_rddata_valid));

  // ------------------------------ bookkeeping -------------------------------
  int errors = 0;
  int n_wr_bursts = 0, n_rd_bursts = 0, n_beats_written = 0, n_beats_compared = 0;
  logic [DATA_W-1:0] refw [bit [WADDR_W-1:0]];      // reference memory, per word

  // beat buffers for the write task and the read task (separate: they may run together)
  logic [DATA_W-1:0]   wb_data [MAXB];
  logic [DATA_W/8-1:0] wb_strb [MAXB];
  logic [DATA_W-1:0]   rb_data [MAXB];
  logic [1:0]          rb_resp [MAXB];
  int                  rready_pct = 75;      // how often the read master is ready

  task automatic fail(input string msg);
    errors++;
    if (errors <= 30) $display("ERROR @%0t: %s", $time, msg);
  endtask

  function automatic logic [DATA_W-1:0] rand64();
    return {$urandom, $urandom};
  endfunction

  // Word address inside one of eight regions that differ in row and bank.
  function automatic logic [WADDR_W-1:0] region_addr(input int region, input int offset);
    logic [WADDR_W-1:0] a;
    a = '0;
    a[WADDR_W-1 -: ROW_W] = ROW_W'(16'h0101 * region);     // row
    a[13:10]              = 4'(region * 3);                 // bank group and bank
    a[9:0]                = 10'(offset);                    // column and word
    return a;
  endfunction

  // Bus tasks change their outputs on the falling clock edge and look at the
  // DUT's outputs a moment later, in the middle of the cycle. A READY seen
  // there is the value the DUT will use at the next rising edge, so the
  // handshake is unambiguous in every simulator (no sampling at the edge).

  // ---------------------------------- APB -----------------------------------
  task automatic apb_write(input logic [11:0] addr, input logic [31:0] data);
    @(negedge aclk); psel = 1; penable = 0; pwrite = 1; paddr = addr; pwdata = data;
    @(negedge aclk); penable = 1;
    @(negedge aclk); psel = 0; penable = 0; pwrite = 0;
  endtask

  task automatic apb_read(input logic [11:0] addr, output logic [31:0] data);
    @(negedge aclk); psel = 1; penable = 0; pwrite = 0; paddr = addr;
    @(negedge aclk); penable = 1;
    #1; data = prdata;
    @(negedge aclk); psel = 0; penable = 0;
  endtask

  task automatic apb_expect(input logic [11:0] addr, input logic [31:0] exp, input string what);
    logic [31:0] d;
    apb_read(addr, d);
    if (d !== exp) fail($sformatf("%s: read %h, expected %h", what, d, exp));
  endtask

  // ---------------------------------- AXI -----------------------------------
  // Write nbeats from wb_data/wb_strb starting at word address a.
  task automatic axi_write(input logic [WADDR_W-1:0] a, input int nbeats,
                           input logic [1:0] burst, input logic [ID_W-1:0] id,
                           output logic [1:0] resp);
    @(negedge aclk);
    awid = id; awaddr = {a, 3'b000}; awlen = 8'(nbeats - 1); awburst = burst; awvalid = 1;
    #1; while (!awready) begin @(negedge aclk); #1; end
    @(negedge aclk); awvalid = 0;
    for (int i = 0; i < nbeats; i++) begin
      if ($urandom_range(0, 99) < 20) repeat ($urandom_range(1, 3)) @(negedge aclk);
      wdata = wb_data[i]; wstrb = wb_strb[i]; wlast = (i == nbeats - 1); wvalid = 1;
      #1; while (!wready) begin @(negedge aclk); #1; end
      @(negedge aclk); wvalid = 0; wlast = 0;
    end
    repeat ($urandom_range(0, 2)) @(negedge aclk);
    bready = 1;
    #1; while (!bvalid) begin @(negedge aclk); #1; end
    resp = bresp;
    if (bid !== id) fail("BID does not match AWID");
    @(negedge aclk); bready = 0;
    n_wr_bursts++;
  endtask

  // Read nbeats starting at word address a into rb_data/rb_resp.
  task automatic axi_read(input logic [WADDR_W-1:0] a, input int nbeats,
                          input logic [1:0] burst, input logic [ID_W-1:0] id);
    int i;
    @(negedge aclk);
    arid = id; araddr = {a, 3'b000}; arlen = 8'(nbeats - 1); arburst = burst; arvalid = 1;
    #1; while (!arready) begin @(negedge aclk); #1; end
    @(negedge aclk); arvalid = 0;
    i = 0;
    while (i < nbeats) begin
      rready = ($urandom_range(0, 99) < rready_pct);
      #1;
      if (rvalid && rready) begin
        rb_data[i] = rdata; rb_resp[i] = rresp;
        if (rid !== id) fail("RID does not match ARID");
        if (rlast !== (i == nbeats - 1)) fail($sformatf("RLAST wrong on beat %0d of %0d", i, nbeats));
        i++;
      end
      @(negedge aclk);
    end
    rready = 0;
    n_rd_bursts++;
  endtask

  // Random write into a region, then update the reference memory.
  task automatic do_random_write(input int region_lo, input int region_hi);
    logic [WADDR_W-1:0] a;
    logic [1:0] resp;
    int n;
    n = $urandom_range(1, 24);
    a = region_addr($urandom_range(region_lo, region_hi), $urandom_range(0, 255));
    for (int i = 0; i < n; i++) begin
      wb_data[i] = rand64();
      wb_strb[i] = ($urandom_range(0, 99) < 10) ? 8'h00 : 8'hFF;
    end
    axi_write(a, n, 2'b01, ID_W'($urandom), resp);
    if (resp !== 2'b00) fail("write response was not OKAY");
    for (int i = 0; i < n; i++)
      if (wb_strb[i] == 8'hFF) begin
        refw[a + WADDR_W'(i)] = wb_data[i];
        n_beats_written++;
      end
  endtask

  // Random read from a region, compared with the reference memory.
  task automatic do_random_read(input int region_lo, input int region_hi,
                                input int min_beats = 1, input int max_beats = 24);
    logic [WADDR_W-1:0] a;
    int n;
    n = $urandom_range(min_beats, max_beats);
    a = region_addr($urandom_range(region_lo, region_hi), $urandom_range(0, 255));
    axi_read(a, n, 2'b01, ID_W'($urandom));
    for (int i = 0; i < n; i++) begin
      if (rb_resp[i] !== 2'b00) fail("read response was not OKAY");
      if (refw.exists(a + WADDR_W'(i))) begin
        n_beats_compared++;
        if (rb_data[i] !== refw[a + WADDR_W'(i)])
          fail($sformatf("read mismatch at word %h: got %h expected %h",
                         a + WADDR_W'(i), rb_data[i], refw[a + WADDR_W'(i)]));
      end
    end
  endtask

  // Wait until every burst has left the controller and the memory model.
  task automatic settle();
    repeat (200) @(posedge aclk);
    while (!phy.idle()) @(posedge aclk);
    repeat (50) @(posedge aclk);
  endtask

  // ------------------------- AXI protocol checks ----------------------------
  // Slave-driven channels must hold VALID and payload until READY.
  logic       bvalid_q = 0, rvalid_q = 0, bready_q = 0, rready_q = 0;
  logic [DATA_W-1:0] rdata_q = '0;
  always @(posedge aclk) if (aresetn) begin
    if (bvalid_q && !bready_q && !bvalid) fail("BVALID dropped before BREADY");
    if (rvalid_q && !rready_q && !rvalid) fail("RVALID dropped before RREADY");
    if (rvalid_q && !rready_q && rvalid && (rdata !== rdata_q)) fail("RDATA changed while waiting");
    bvalid_q <= bvalid; bready_q <= bready; rvalid_q <= rvalid; rready_q <= rready;
    rdata_q  <= rdata;
  end

  // ---------------------------------- test ----------------------------------
  initial begin
    logic [31:0] d, ce_before, ue_before;
    logic [1:0]  resp;
    logic [WADDR_W-1:0] a;
    int guard;
    int n_ops;

    // operation count: parameter default, or +nops=<n> on the command line
    n_ops = NOPS;
    void'($value$plusargs("nops=%d", n_ops));

    // a real falling edge on both resets, so the asynchronous reset takes effect
    // before the first clock edge
    // Both resets fall at 1 ns, before the first clock edge, so every flop with
    // an asynchronous reset is in a known state before anything is sampled.
    #1 aresetn = 0; crst_n = 0;
    repeat (5) @(posedge aclk);
    aresetn = 1; crst_n = 1;
    repeat (10) @(posedge aclk);
    dfi_init_complete = 1;

    // ======================= phase 0: registers and init ====================
    apb_expect(12'h000, 32'h0, "CTRL after reset");
    apb_expect(12'h080, 32'd3, "t_rcd reset value");
    apb_expect(12'h0D4, 32'd2, "t_xp reset value (last timing field)");
    apb_expect(12'h01C, {12'd0, 4'd6, 16'd1560}, "REFRESH reset value");
    apb_write(12'h020, 32'd20);   apb_expect(12'h020, 32'd20, "T_RST");
    apb_write(12'h024, 32'd30);
    apb_write(12'h028, 32'd10);
    apb_write(12'h02C, 32'd15);
    apb_write(12'h01C, {12'd0, 4'd6, 16'd300});
    apb_write(12'h048, 32'h0000_0028);  apb_expect(12'h048, 32'h28, "MR2 write/read");
    apb_write(12'h048, 32'h0000_0018);
    apb_write(12'h098, 32'd4);          apb_expect(12'h098, 32'd4, "timing field 6 write/read");
    apb_write(12'h098, 32'd1);          // back to the default t_rrd_s
    apb_write(12'h008, 32'h7);          // enable all interrupts
    apb_expect(12'h004, 32'h0, "STATUS before init start");
    apb_write(12'h000, 32'h2);          // init_start
    guard = 0;
    do begin apb_read(12'h004, d); guard++; end while (!d[0] && guard < 5000);
    if (!d[0]) fail("init_done never set");

    // ============== phase 1: random traffic, single-bit errors ==============
    phy.inj1_pct = 8;
    for (int op = 0; op < n_ops; op++) begin
      if ($urandom_range(0, 99) < 50) do_random_write(0, 3);
      else                            do_random_read(0, 3);
    end
    settle();

    // ============== phase 2: writes and reads at the same time ==============
    fork
      begin for (int k = 0; k < n_ops / 3; k++) do_random_write(4, 7); end
      begin for (int k = 0; k < n_ops / 3; k++) do_random_read(0, 3);  end
    join
    for (int k = 0; k < n_ops / 6; k++) do_random_read(4, 7);
    settle();

    // ======== phase 2b: long reads into a master that is rarely ready ========
    // The read FIFO fills and stays full, so the controller must hold back
    // further reads instead of overflowing it.
    rready_pct = 4;
    for (int k = 0; k < 4; k++) do_random_read(0, 7, 200, 256);
    rready_pct = 75;
    settle();
    phy.inj1_pct = 0;

    apb_read(12'h010, d);
    if (d == 0) fail("corrected-error counter never moved");
    if (int'(d) > phy.n_single) fail("corrected-error counter exceeds injected errors");
    apb_expect(12'h014, 32'h0, "uncorrectable counter after single-bit phase");
    apb_read(12'h00C, d);
    if (d[0] !== 1'b1) fail("corrected-error interrupt status not set");
    if (!irq) fail("irq not asserted with a corrected error pending");
    apb_write(12'h00C, 32'h7);
    apb_expect(12'h00C, 32'h0, "INT_STAT after write-1-to-clear");
    @(posedge aclk);
    if (irq) fail("irq still asserted after clearing");

    // ================== phase 3a: partial strobe -> SLVERR ==================
    a = region_addr(1, 300);
    for (int i = 0; i < 4; i++) begin wb_data[i] = rand64(); wb_strb[i] = 8'hFF; end
    axi_write(a, 4, 2'b01, 4'h3, resp);                 // known contents first
    for (int i = 0; i < 4; i++) refw[a + WADDR_W'(i)] = wb_data[i];
    for (int i = 0; i < 4; i++) begin wb_data[i] = rand64(); wb_strb[i] = 8'hFF; end
    wb_strb[2] = 8'h0F;
    axi_write(a, 4, 2'b01, 4'h4, resp);
    if (resp !== 2'b10) fail("partial strobe did not return SLVERR");
    refw[a] = wb_data[0]; refw[a + 1] = wb_data[1]; refw[a + 3] = wb_data[3];   // word 2 unchanged
    axi_read(a, 4, 2'b01, 4'h5);
    for (int i = 0; i < 4; i++)
      if (rb_data[i] !== refw[a + WADDR_W'(i)]) fail($sformatf("partial-strobe readback, beat %0d", i));

    // ================ phase 3b: unsupported burst type -> SLVERR =============
    for (int i = 0; i < 4; i++) begin wb_data[i] = rand64(); wb_strb[i] = 8'hFF; end
    axi_write(a, 4, 2'b10, 4'h6, resp);                 // WRAP
    if (resp !== 2'b10) fail("WRAP write did not return SLVERR");
    axi_read(a, 4, 2'b01, 4'h7);
    for (int i = 0; i < 4; i++)
      if (rb_data[i] !== refw[a + WADDR_W'(i)]) fail("WRAP write modified memory");
    axi_read(a, 4, 2'b10, 4'h8);                        // WRAP read
    for (int i = 0; i < 4; i++)
      if (rb_resp[i] !== 2'b10) fail("WRAP read beat was not SLVERR");

    // =========== phase 3c: uncorrectable errors, counter, interrupt ==========
    settle();
    apb_read(12'h014, ue_before);
    phy.inj2_pct = 100;
    axi_read(a, 4, 2'b01, 4'h9);
    for (int i = 0; i < 4; i++)
      if (rb_resp[i] !== 2'b10) fail("double-bit error beat was not SLVERR");
    phy.inj2_pct = 0;
    settle();
    apb_read(12'h014, d);
    if (d !== ue_before + 32'd4) fail($sformatf("uncorrectable counter: %0d, expected %0d", d, ue_before + 4));
    apb_read(12'h00C, d);
    if (d[1] !== 1'b1) fail("uncorrectable interrupt status not set");
    if (!irq) fail("irq not asserted for an uncorrectable error");
    apb_write(12'h014, 32'h0);  apb_expect(12'h014, 32'h0, "uncorrectable counter after clear");
    apb_write(12'h00C, 32'h7);
    axi_read(a, 4, 2'b01, 4'hA);                        // clean again
    for (int i = 0; i < 4; i++)
      if (rb_resp[i] !== 2'b00 || rb_data[i] !== refw[a + WADDR_W'(i)])
        fail("read after error injection was not clean");

    // ================= phase 3d: self-refresh via the register ==============
    apb_write(12'h000, 32'h3);                          // sr_req + init_start
    guard = 0;
    do begin apb_read(12'h004, d); guard++; end while (!d[1] && guard < 2000);
    if (!d[1]) fail("self-refresh status never set");
    repeat (100) @(posedge aclk);
    apb_write(12'h000, 32'h2);
    guard = 0;
    do begin apb_read(12'h004, d); guard++; end while (d[1] && guard < 2000);
    if (d[1]) fail("self-refresh status never cleared");
    do_random_write(0, 3);
    do_random_read(0, 3);
    settle();

    apb_read(12'h004, d);
    if (d[2]) fail("refresh overflow reported");
    if (rvalid) fail("read data still pending with no read outstanding");
    if (phy.n_rd == 0 || phy.n_wr == 0) fail("memory model saw no traffic");
    if (phy.errors != 0) fail($sformatf("%0d PHY model errors", phy.errors));
    if (n_beats_compared < 100) fail("too little read data was compared");

    $display("ddr4_ctrl_top: wr_bursts=%0d rd_bursts=%0d beats_written=%0d beats_compared=%0d mem_wr=%0d mem_rd=%0d injected_single=%0d injected_double=%0d errors=%0d  %s",
             n_wr_bursts, n_rd_bursts, n_beats_written, n_beats_compared, phy.n_wr, phy.n_rd,
             phy.n_single, phy.n_double, errors, errors == 0 ? "PASS" : "FAIL");
    $finish;
  end

  localparam int WATCHDOG_CYCLES = 3_000_000;
  initial begin
    repeat (WATCHDOG_CYCLES) @(posedge aclk);
    $display("TIMEOUT FAIL at %0t: wr_bursts=%0d rd_bursts=%0d errors=%0d awready=%b wready=%b bvalid=%b arready=%b rvalid=%b",
             $time, n_wr_bursts, n_rd_bursts, errors, awready, wready, bvalid, arready, rvalid);
    $finish;
  end
endmodule
