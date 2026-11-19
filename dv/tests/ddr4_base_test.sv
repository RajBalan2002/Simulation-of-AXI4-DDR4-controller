// -----------------------------------------------------------------------------
// ddr4_base_test.sv
// Every test extends this.
//   build:  config (with plusargs), env
//   run:    reset -> program registers from cfg -> initialize -> test_body()
//           -> drain -> final register checks
//   report: ** TEST PASSED ** / ** TEST FAILED ** from the error count
// Derived tests override configure() and test_body(); do_init = 0 skips
// initialization (register-only tests).
// -----------------------------------------------------------------------------
class ddr4_base_test extends uvm_test;
  `uvm_component_utils(ddr4_base_test)

  ddr4_env_cfg   cfg;
  ddr4_env       env;
  ddr4_reg_block rm;
  bit            do_init = 1;

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  // Derived tests change cfg here, before the env is built.
  virtual function void configure(ddr4_env_cfg c);
  endfunction

  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    cfg = ddr4_env_cfg::type_id::create("cfg");
    cfg.read_plusargs();
    if (!uvm_config_db#(virtual ddr4_ctrl_if)::get(this, "", "ctrl_vif", cfg.ctrl_vif))
      `uvm_fatal("NOVIF", "ctrl_vif not set")
    if (!uvm_config_db#(virtual ddr4_axi_if)::get(this, "", "axi_vif", cfg.axi_vif))
      `uvm_fatal("NOVIF", "axi_vif not set")
    if (!uvm_config_db#(virtual ddr4_apb_if)::get(this, "", "apb_vif", cfg.apb_vif))
      `uvm_fatal("NOVIF", "apb_vif not set")
    if (!uvm_config_db#(virtual ddr4_dfi_if)::get(this, "", "dfi_vif", cfg.dfi_vif))
      `uvm_fatal("NOVIF", "dfi_vif not set")
    if (!uvm_config_db#(virtual ddr4_probe_if)::get(this, "", "probe_vif", cfg.probe_vif))
      `uvm_fatal("NOVIF", "probe_vif not set")
    configure(cfg);
    uvm_config_db#(ddr4_env_cfg)::set(this, "env", "cfg", cfg);
    env = ddr4_env::type_id::create("env", this);
    // No uvm_root::set_timeout(): the precompiled mtiUvm package has a different
    // timescale, so 50ms from here became 50us there. The watchdog in run_phase
    // waits in this file's timescale instead.
  endfunction

  function void connect_phase(uvm_phase phase);
    rm = env.regmodel;
  endfunction

  function void end_of_elaboration_phase(uvm_phase phase);
    `uvm_info("CFG", cfg.convert2string(), UVM_LOW)
    if (uvm_report_enabled(UVM_HIGH)) uvm_root::get().print_topology();
  endfunction

  task run_phase(uvm_phase phase);
    phase.raise_objection(this);
    fork                                   // killed when run_phase ends
      begin
        #(cfg.test_timeout);
        `uvm_fatal("TIMEOUT", $sformatf("test did not finish within %0t", cfg.test_timeout))
      end
    join_none
    reset_dut();
    if (do_init) init_dut();
    test_body();
    if (do_init) begin
      drain();
      final_checks();
    end
    phase.drop_objection(this);
  endtask

  // ---------------------------------------------------------------- reset
  virtual task reset_dut();
    cfg.ctrl_vif.apply_reset(cfg.reset_cycles);
    cfg.ctrl_vif.wait_aclk(4);
    rm.reset();
    env.sb.clear_counts();
    env.sb.exp_int_stat = 0;
    `uvm_info("RESET", "reset released", UVM_MEDIUM)
  endtask

  // ----------------------------------------------------------- power-up init
  // Program every configuration register from cfg, start initialization and
  // wait for STATUS.init_done.
  virtual task init_dut();
    uvm_status_e st;
    uvm_reg_data_t v;
    int unsigned polls = 0;

    reg_wr(rm.LATENCY, (cfg.rden_lat << 4) | cfg.wr_lat);
    reg_wr(rm.REFRESH, (cfg.ref_thresh << 16) | cfg.t_refi);
    reg_wr(rm.T_RST,   cfg.eff_t_rst());
    reg_wr(rm.T_CKE,   cfg.eff_t_cke());
    reg_wr(rm.T_XPR,   cfg.t_xpr);
    reg_wr(rm.T_DLLK,  cfg.t_dllk);
    reg_wr(rm.T_CKESR, cfg.t_ckesr);
    reg_wr(rm.INT_EN,  cfg.int_en);
    for (int n = 0; n < 7; n++)        reg_wr(rm.MR[n], cfg.mr[n]);
    for (int k = 0; k < N_TIMING; k++) reg_wr(rm.TIMING[k], timing_get(cfg.timing, k));
    reg_wr(rm.CTRL, 32'h2);                              // init_start

    fork : wait_init
      begin
        do begin
          cfg.ctrl_vif.wait_aclk(64);
          rm.STATUS.read(st, v);
          polls++;
        end while (v[0] !== 1'b1);
      end
      begin
        cfg.ctrl_vif.wait_cclk(cfg.init_timeout);
        `uvm_fatal("INIT", $sformatf("init_done not set after %0d cclk cycles", cfg.init_timeout))
      end
    join_any
    disable wait_init;
    `uvm_info("INIT", $sformatf("initialization done at %0t (%0d status polls)", $time, polls), UVM_LOW)
  endtask

  // Derived tests put their stimulus here.
  virtual task test_body();
  endtask

  // ---------------------------------------------------- end of traffic
  // Wait until every burst has been driven, answered and judged.
  virtual task drain();
    int unsigned n = 0;
    while (!env.idle()) begin
      cfg.ctrl_vif.wait_aclk(16);
      n += 16;
      if (n > cfg.drain_timeout) begin
        `uvm_error("DRAIN", $sformatf("traffic did not drain in %0d aclk cycles (driver idle %0b, monitor idle %0b, scoreboard idle %0b)",
                                      cfg.drain_timeout, env.axi_agt.drv.idle(),
                                      env.axi_agt.mon.idle(), env.sb.idle()))
        break;
      end
    end
    cfg.ctrl_vif.wait_aclk(64);     // let ECC events cross into the register clock
  endtask

  // Registers that must agree with the scoreboard's predictions.
  virtual task final_checks();
    uvm_status_e st;
    uvm_reg_data_t v;
    rm.ECC_CE.read(st, v);
    if (v[31:0] !== env.sb.exp_ce)
      `uvm_error("REGCHK", $sformatf("ECC_CE = %0d, expected %0d", v[31:0], env.sb.exp_ce))
    rm.ECC_UE.read(st, v);
    if (v[31:0] !== env.sb.exp_ue)
      `uvm_error("REGCHK", $sformatf("ECC_UE = %0d, expected %0d", v[31:0], env.sb.exp_ue))
    rm.INT_STAT.read(st, v);
    if (v[1:0] !== env.sb.exp_int_stat[1:0])
      `uvm_error("REGCHK", $sformatf("INT_STAT[1:0] = %02b, expected %02b", v[1:0], env.sb.exp_int_stat[1:0]))
    if (v[2] !== 1'b0)
      `uvm_error("REGCHK", "INT_STAT.ref_overflow set")
    rm.STATUS.read(st, v);
    if (v[2] !== 1'b0)
      `uvm_error("REGCHK", "STATUS.ref_overflow set")
  endtask

  // ------------------------------------------------------------- helpers
  task reg_wr(uvm_reg r, uvm_reg_data_t v);
    uvm_status_e st;
    r.write(st, v);
    if (st != UVM_IS_OK) `uvm_error("REG", $sformatf("write to %s failed", r.get_name()))
  endtask

  task reg_rd(uvm_reg r, output uvm_reg_data_t v);
    uvm_status_e st;
    r.read(st, v);
    if (st != UVM_IS_OK) `uvm_error("REG", $sformatf("read of %s failed", r.get_name()))
  endtask

  // Start random traffic on the AXI sequencer and wait for it.
  task traffic(int unsigned n, int unsigned wr_pct = 50, int unsigned strobe_mode = 0,
               int unsigned unsup_pct = 0, int unsigned max_row = 7, int unsigned max_len = 255,
               int unsigned idle_pct = 0);
    axi_rand_seq s = axi_rand_seq::type_id::create("traffic");
    s.n = n;  s.wr_pct = wr_pct;  s.strobe_mode = strobe_mode;  s.unsup_pct = unsup_pct;
    s.max_row = max_row;  s.max_len = max_len;  s.idle_pct = idle_pct;
    s.start(env.axi_agt.sqr);
  endtask

  // Number of bursts: +NBURSTS=<n> overrides the test's default.
  function int unsigned nbursts(int unsigned dflt);
    int unsigned n;
    return $value$plusargs("NBURSTS=%d", n) ? n : dflt;
  endfunction

  // ------------------------------------------------------------- verdict
  function void report_phase(uvm_phase phase);
    uvm_report_server rs = uvm_report_server::get_server();
    int n_err = rs.get_severity_count(UVM_ERROR) + rs.get_severity_count(UVM_FATAL);
    if (n_err == 0) `uvm_info("RESULT", "** TEST PASSED **", UVM_NONE)
    else            `uvm_info("RESULT", $sformatf("** TEST FAILED ** (%0d errors)", n_err), UVM_NONE)
  endfunction
endclass
