// -----------------------------------------------------------------------------
// ddr4_tests.sv
// The test list from the verification plan. Each is a configuration of the
// shared environment plus a short test_body(). Default burst counts are
// sized for quick runs; +NBURSTS=<n> scales them.
// -----------------------------------------------------------------------------

// One write and one read after initialization.
class sanity_test extends ddr4_base_test;
  `uvm_component_utils(sanity_test)
  function new(string name, uvm_component parent); super.new(name, parent); endfunction
  task test_body();
    axi_wr_rd_seq s = axi_wr_rd_seq::type_id::create("s");
    s.start(env.axi_agt.sqr);
  endtask
endclass

// Every register's reset value.
class reg_reset_test extends ddr4_base_test;
  `uvm_component_utils(reg_reset_test)
  function new(string name, uvm_component parent); super.new(name, parent); do_init = 0; endfunction
  task test_body();
    uvm_reg_hw_reset_seq s = uvm_reg_hw_reset_seq::type_id::create("s");
    s.model = rm;
    s.start(null);
  endtask
endclass

// Every read-write bit can be set and cleared (before initialization).
class reg_bitbash_test extends ddr4_base_test;
  `uvm_component_utils(reg_bitbash_test)
  function new(string name, uvm_component parent); super.new(name, parent); do_init = 0; endfunction
  task test_body();
    uvm_reg_bit_bash_seq s = uvm_reg_bit_bash_seq::type_id::create("s");
    s.model = rm;
    s.start(null);
  endtask
endclass

// Power-up with randomized init waits, three times, with traffic in between.
class init_test extends ddr4_base_test;
  `uvm_component_utils(init_test)
  function new(string name, uvm_component parent); super.new(name, parent); endfunction
  function void configure(ddr4_env_cfg c);
    c.short_t_rst    = $urandom_range(5, 200);
    c.short_t_cke    = $urandom_range(5, 300);
    c.phy_init_delay = $urandom_range(1, 50);
  endfunction
  task test_body();
    traffic(20);
    repeat (2) begin
      drain();
      cfg.short_t_rst = $urandom_range(5, 200);
      cfg.short_t_cke = $urandom_range(5, 300);
      reset_dut();
      init_dut();
      traffic(20);
    end
  endtask
endclass

// Random legal traffic, all lengths and start words.
class axi_rand_test extends ddr4_base_test;
  `uvm_component_utils(axi_rand_test)
  function new(string name, uvm_component parent); super.new(name, parent); endfunction
  task test_body();
    traffic(nbursts(500));
  endtask
endclass

// WSTRB 0xFF, 0x00 and partial values.
class axi_strobe_test extends ddr4_base_test;
  `uvm_component_utils(axi_strobe_test)
  function new(string name, uvm_component parent); super.new(name, parent); endfunction
  task test_body();
    traffic(nbursts(150), 60, 1);
    traffic(nbursts(150), 60, 2);
  endtask
endclass

// FIXED, WRAP and narrow bursts mixed with legal ones.
class axi_unsupported_test extends ddr4_base_test;
  `uvm_component_utils(axi_unsupported_test)
  function new(string name, uvm_component parent); super.new(name, parent); endfunction
  task test_body();
    traffic(nbursts(300), 50, 0, 30);
  endtask
endclass

// Slow and stalling BREADY / RREADY.
class axi_backpressure_test extends ddr4_base_test;
  `uvm_component_utils(axi_backpressure_test)
  function new(string name, uvm_component parent); super.new(name, parent); endfunction
  task test_body();
    int unsigned rates [4] = '{50, 20, 5, 2};
    foreach (rates[i]) begin
      cfg.rready_pct = rates[i];
      cfg.bready_pct = rates[i] < 10 ? 10 : rates[i];
      traffic(nbursts(80), 30, 0, 0, 7, 31);    // short bursts: 2% ready is slow
    end
  endtask
endclass

// Reads and writes from two sequences at once, on a small address window.
class concurrent_rw_test extends ddr4_base_test;
  `uvm_component_utils(concurrent_rw_test)
  function new(string name, uvm_component parent); super.new(name, parent); endfunction
  task test_body();
    fork
      traffic(nbursts(300), 100, 0, 0, 1, 15);
      traffic(nbursts(300), 0,   0, 0, 1, 15);
    join
  endtask
endclass

// Row hits, row misses and empty banks in every bank.
class page_policy_test extends ddr4_base_test;
  `uvm_component_utils(page_policy_test)
  function new(string name, uvm_component parent); super.new(name, parent); endfunction
  task test_body();
    axi_page_seq s = axi_page_seq::type_id::create("s");
    s.n = nbursts(400);
    s.start(env.axi_agt.sqr);
  endtask
endclass

// Widened cross-bank timing so tRRD, tFAW and tCCD become the limiting rules.
class timing_stress_test extends ddr4_base_test;
  `uvm_component_utils(timing_stress_test)
  function new(string name, uvm_component parent); super.new(name, parent); endfunction
  function void configure(ddr4_env_cfg c);
    c.timing.t_faw   = 10'd30;
    c.timing.t_rrd_s = 10'd6;
    c.timing.t_rrd_l = 10'd9;
    c.timing.t_ccd_s = 10'd3;
    c.timing.t_ccd_l = 10'd5;
    c.timing.t_rtp   = 10'd6;
    c.timing.t_wr2rd_s = 10'd7;
    c.timing.t_wr2rd_l = 10'd9;
    c.timing.t_rd2wr = 10'd6;
  endfunction
  task test_body();
    axi_page_seq s = axi_page_seq::type_id::create("s");
    s.n = nbursts(300);
    s.start(env.axi_agt.sqr);
    traffic(nbursts(300), 50, 0, 0, 31, 15);
  endtask
endclass

// One timing register set above its minimum per run (+FIELD=<k> picks it).
class timing_sweep_test extends ddr4_base_test;
  `uvm_component_utils(timing_sweep_test)
  function new(string name, uvm_component parent); super.new(name, parent); endfunction
  function void configure(ddr4_env_cfg c);
    int k;
    int unsigned v;
    if (!$value$plusargs("FIELD=%d", k)) k = $urandom_range(0, N_TIMING - 1);
    v = timing_get(c.timing, k);
    v = v + $urandom_range(1, (v < 4) ? 8 : 2 * v);
    if (v > 1023) v = 1023;
    timing_set(c.timing, k, tcnt_t'(v));
    `uvm_info("SWEEP", $sformatf("%s set to %0d", timing_name(k), v), UVM_LOW)
  endfunction
  task test_body();
    traffic(nbursts(200), 50, 0, 0, 15, 31, 10);
  endtask
endclass

// Short refresh interval: refresh under load, when idle, and at the urgent limit.
class refresh_test extends ddr4_base_test;
  `uvm_component_utils(refresh_test)
  function new(string name, uvm_component parent); super.new(name, parent); endfunction
  function void configure(ddr4_env_cfg c);
    c.t_refi     = $urandom_range(150, 400);
    c.ref_thresh = $urandom_range(1, 8);
  endfunction
  task test_body();
    traffic(nbursts(300));                       // heavy load
    traffic(nbursts(100), 50, 0, 0, 7, 15, 40);  // with idle gaps
    cfg.ctrl_vif.wait_cclk(cfg.t_refi * 12);     // idle: refreshes catch up
  endtask
endclass

// Self-refresh entry and exit with traffic waiting, short (withdrawn) and
// long requests, and a second request straight after an exit.
class self_refresh_test extends ddr4_base_test;
  `uvm_component_utils(self_refresh_test)
  function new(string name, uvm_component parent); super.new(name, parent); endfunction
  task test_body();
    fork
      traffic(nbursts(400), 50, 0, 0, 7, 31, 5);
      begin
        repeat (8) begin
          cfg.ctrl_vif.wait_aclk($urandom_range(200, 2000));
          sr_episode($urandom_range(0, 1) ? $urandom_range(1, 20) : $urandom_range(300, 3000));
          if ($urandom_range(0, 1)) begin
            cfg.ctrl_vif.wait_aclk($urandom_range(1, 10));
            sr_episode($urandom_range(300, 1000));      // re-entry straight after exit
          end
        end
      end
    join
  endtask

  // Longest legal delay before self-refresh entry, in aclk cycles. Worst case is
  // a re-entry right after an exit: tXS, then the REF owed after the exit (tRFC),
  // then tRP for banks being closed, plus 64 cclk for the APB/CDC path and
  // commands already queued. The DUT's delay is fixed in cclk, so a bound in
  // aclk cycles alone (the old "hold > 300") was too short at CLK_SET=fast.
  function int unsigned sre_bound_aclk();
    real cclk_cycles = real'(cfg.timing.t_xs) + real'(cfg.timing.t_rfc) +
                       real'(cfg.timing.t_rp) + 64.0;
    return int'($ceil(cclk_cycles * cfg.cclk_ns / cfg.aclk_ns));
  endfunction

  task sr_episode(int unsigned hold);
    uvm_reg_data_t v;
    reg_wr(rm.CTRL, 32'h3);                  // sr_req + init_start
    cfg.ctrl_vif.wait_aclk(hold);
    if (hold > 300 && hold > sre_bound_aclk()) begin
      reg_rd(rm.STATUS, v);
      `uvm_info("SR", $sformatf("in_self_refresh checked after %0d aclk (bound %0d)", hold, sre_bound_aclk()), UVM_MEDIUM)
      if (v[1] !== 1'b1) `uvm_error("SR", "STATUS.in_self_refresh not set during a long request")
    end
    reg_wr(rm.CTRL, 32'h2);
  endtask
endclass

// Single-bit errors at every bit of every word, plus random ones.
class ecc_single_test extends ddr4_base_test;
  `uvm_component_utils(ecc_single_test)
  function new(string name, uvm_component parent); super.new(name, parent); endfunction
  function void configure(ddr4_env_cfg c);
    c.inj1_pct = 5;
    for (int w = 0; w < BURST_WORDS; w++)
      for (int b = 0; b < CODE_W; b++) begin
        inj_t d;
        d.word = w;  d.bit_a = b;  d.bit_b = -1;
        c.directed_inj.push_back(d);
      end
  endfunction
  task test_body();
    traffic(nbursts(200), 100, 0, 0, 1, 31);       // fill memory
    while (cfg.directed_inj.size() > 0) traffic(50, 10, 0, 0, 1, 31);
  endtask
endclass

// Double-bit errors at increasing rates.
class ecc_double_test extends ddr4_base_test;
  `uvm_component_utils(ecc_double_test)
  function new(string name, uvm_component parent); super.new(name, parent); endfunction
  task test_body();
    int unsigned rates [3] = '{2, 20, 100};
    traffic(nbursts(100), 100, 0, 0, 1, 31);
    foreach (rates[i]) begin
      cfg.inj1_pct = 0;
      cfg.inj2_pct = rates[i];
      traffic(nbursts(100), 30, 0, 0, 1, 31);
    end
  endtask
endclass

// Error counters saturate at 2^32 - 1.
class ecc_counter_sat_test extends ddr4_base_test;
  `uvm_component_utils(ecc_counter_sat_test)
  function new(string name, uvm_component parent); super.new(name, parent); endfunction
  task test_body();
    cfg.probe_vif.force_ecc_counts(32'hFFFF_FFF0, 32'hFFFF_FFF8);
    env.sb.exp_ce = 32'hFFFF_FFF0;
    env.sb.exp_ue = 32'hFFFF_FFF8;
    cfg.inj1_pct = 20;
    cfg.inj2_pct = 10;
    traffic(nbursts(100), 40, 0, 0, 1, 31);
  endtask
  task final_checks();
    super.final_checks();
    if (env.sb.exp_ce != 32'hFFFF_FFFF || env.sb.exp_ue != 32'hFFFF_FFFF)
      `uvm_error("SAT", "not enough errors injected to reach saturation; raise NBURSTS")
  endtask
endclass

// Each interrupt cause with its enable off and on, then cleared.
class interrupt_test extends ddr4_base_test;
  `uvm_component_utils(interrupt_test)
  function new(string name, uvm_component parent); super.new(name, parent); endfunction
  task test_body();
    traffic(20, 100, 0, 0, 0, 7);
    check_cause(0, 100, 0);    // corrected
    check_cause(1, 0, 100);    // uncorrectable
  endtask

  task check_cause(int bit_i, int unsigned p1, int unsigned p2);
    uvm_reg_data_t v;
    reg_wr(rm.INT_EN, 0);
    reg_wr(rm.INT_STAT, 7);
    env.sb.exp_int_stat = 0;
    cfg.inj1_pct = p1;  cfg.inj2_pct = p2;
    traffic(4, 0, 0, 0, 0, 7);
    drain();
    cfg.inj1_pct = 0;  cfg.inj2_pct = 0;
    reg_rd(rm.INT_STAT, v);
    if (v[bit_i] !== 1'b1) `uvm_error("IRQ", $sformatf("INT_STAT[%0d] not set", bit_i))
    if (cfg.apb_vif.irq !== 1'b0) `uvm_error("IRQ", "irq high with the cause disabled")
    reg_wr(rm.INT_EN, 1 << bit_i);
    cfg.ctrl_vif.wait_aclk(2);
    if (cfg.apb_vif.irq !== 1'b1) `uvm_error("IRQ", $sformatf("irq low with cause %0d enabled and set", bit_i))
    reg_wr(rm.INT_STAT, 1 << bit_i);
    cfg.ctrl_vif.wait_aclk(2);
    if (cfg.apb_vif.irq !== 1'b0) `uvm_error("IRQ", "irq still high after write-1-to-clear")
    reg_rd(rm.INT_STAT, v);
    if (v[bit_i] !== 1'b0) `uvm_error("IRQ", $sformatf("INT_STAT[%0d] not cleared", bit_i))
    env.sb.exp_int_stat[bit_i] = 0;
    reg_wr(rm.INT_EN, 0);
  endtask
endclass

// Random DFI write and read-enable latencies and PHY read latency.
class latency_test extends ddr4_base_test;
  `uvm_component_utils(latency_test)
  function new(string name, uvm_component parent); super.new(name, parent); endfunction
  function void configure(ddr4_env_cfg c);
    c.wr_lat     = $urandom_range(0, 7);
    c.rden_lat   = $urandom_range(0, 7);
    c.rd_phy_lat = $urandom_range(1, 4);
  endfunction
  task test_body();
    traffic(nbursts(300));
  endtask
endclass

// Reset in the middle of traffic, then full recovery.
class reset_test extends ddr4_base_test;
  `uvm_component_utils(reset_test)
  function new(string name, uvm_component parent); super.new(name, parent); endfunction
  task test_body();
    repeat (3) begin
      fork
        traffic(nbursts(1000));
        cfg.ctrl_vif.wait_aclk($urandom_range(500, 5000));
      join_any
      disable fork;
      env.axi_agt.sqr.stop_sequences();
      reset_dut();
      init_dut();
    end
    traffic(nbursts(200));
  endtask
endclass

// Everything randomized: latencies, refresh, strobes, unsupported bursts,
// backpressure, errors.
class random_all_test extends ddr4_base_test;
  `uvm_component_utils(random_all_test)
  function new(string name, uvm_component parent); super.new(name, parent); endfunction
  function void configure(ddr4_env_cfg c);
    c.wr_lat     = $urandom_range(0, 7);
    c.rden_lat   = $urandom_range(0, 7);
    c.rd_phy_lat = $urandom_range(1, 4);
    c.t_refi     = $urandom_range(300, 1560);
    c.ref_thresh = $urandom_range(2, 8);
    c.inj1_pct   = $urandom_range(0, 3);
    c.inj2_pct   = $urandom_range(0, 1);
    c.rready_pct = $urandom_range(30, 100);
    c.bready_pct = $urandom_range(30, 100);
  endfunction
  task test_body();
    traffic(nbursts(1000), $urandom_range(20, 80), $urandom_range(0, 2),
            $urandom_range(0, 10), $urandom_range(1, 31), 255, $urandom_range(0, 10));
  endtask
endclass
