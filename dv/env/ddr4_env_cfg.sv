// -----------------------------------------------------------------------------
// ddr4_env_cfg.sv
// Everything a test can change about the environment, in one object.
// The base test programs the DUT registers from these values, and the
// checkers judge the DUT against the same values.
// -----------------------------------------------------------------------------
class ddr4_env_cfg extends uvm_object;
  `uvm_object_utils(ddr4_env_cfg)

  // ---- interfaces (set by the base test from uvm_config_db) ----
  virtual ddr4_ctrl_if  ctrl_vif;
  virtual ddr4_axi_if   axi_vif;
  virtual ddr4_apb_if   apb_vif;
  virtual ddr4_dfi_if   dfi_vif;
  virtual ddr4_probe_if probe_vif;

  // ---- clocks (tb_top picks the periods from +CLK_SET; copied here) ----
  string clk_set  = "slow";   // fast | equal | slow | odd
  real   aclk_ns  = 10.0;
  real   cclk_ns  = 5.0;

  // ---- DUT programming (written to the registers by the base test) ----
  timing_t     timing     = timing_default_1600();
  logic [13:0] mr [7]     = MR_DEFAULT;
  int unsigned t_refi     = 1560;   // cclk cycles
  int unsigned ref_thresh = 6;
  int unsigned t_ckesr    = 2;
  int unsigned wr_lat     = 2;      // DFI write latency, 0..7
  int unsigned rden_lat   = 3;      // DFI read-enable latency, 0..7
  int unsigned int_en     = 0;

  // ---- initialization ----
  // short_init shortens only the two long waits (RESET_n low 200 us and
  // CKE low 500 us). tXPR and tDLLK keep their datasheet values.
  bit          short_init     = 1'b1;
  int unsigned t_rst          = 40000;
  int unsigned t_cke          = 100000;
  int unsigned t_xpr          = 72;
  int unsigned t_dllk         = 150;
  int unsigned short_t_rst    = 20;
  int unsigned short_t_cke    = 30;
  int unsigned phy_init_delay = 10;       // cclk cycles before dfi_init_complete
  int unsigned init_timeout   = 300_000;  // cclk cycles allowed for init_done

  // ---- DFI responder ----
  int unsigned rd_phy_lat = 2;            // rddata_en to rddata_valid, cclk cycles
  int unsigned inj1_pct   = 0;            // % of returned words with a 1-bit error
  int unsigned inj2_pct   = 0;            // % of returned words with a 2-bit error
  inj_t        directed_inj [$];          // one per read burst, used first

  // ---- AXI master ----
  int unsigned bready_pct = 100;
  int unsigned rready_pct = 100;

  // ---- checking ----
  bit          allow_below_ds = 1'b0;     // let a test program timing below DDR4-1600 minimums
  bit          en_checker     = 1'b1;
  bit          en_coverage    = 1'b1;

  // ---- run control ----
  int unsigned reset_cycles  = 16;
  time         test_timeout  = 50ms;
  int unsigned drain_timeout = 400_000;   // aclk cycles

  function new(string name = "ddr4_env_cfg");
    super.new(name);
  endfunction

  // Clock settings must match tb_top's table.
  function void read_plusargs();
    string s;
    if ($value$plusargs("CLK_SET=%s", s)) clk_set = s;
    case (clk_set)
      "fast":  aclk_ns = 2.5;    // AXI clock 2x the controller clock
      "equal": aclk_ns = 5.0;
      "slow":  aclk_ns = 10.0;   // default: 100 MHz AXI, 200 MHz controller
      "odd":   aclk_ns = 10.6;   // unrelated ratio
      default: `uvm_fatal("CFG", $sformatf("unknown +CLK_SET=%s", clk_set))
    endcase
    if ($test$plusargs("FULL_INIT")) short_init = 1'b0;
  endfunction

  function int unsigned eff_t_rst();
    return short_init ? short_t_rst : t_rst;
  endfunction

  function int unsigned eff_t_cke();
    return short_init ? short_t_cke : t_cke;
  endfunction

  function string convert2string();
    string s;
    s = $sformatf("clk_set=%s aclk=%.1fns cclk=%.1fns short_init=%0b wr_lat=%0d rden_lat=%0d rd_phy_lat=%0d t_refi=%0d ref_thresh=%0d inj1=%0d%% inj2=%0d%% bready=%0d%% rready=%0d%%",
                  clk_set, aclk_ns, cclk_ns, short_init, wr_lat, rden_lat, rd_phy_lat,
                  t_refi, ref_thresh, inj1_pct, inj2_pct, bready_pct, rready_pct);
    for (int k = 0; k < N_TIMING; k++)
      if (timing_get(timing, k) != timing_get(timing_default_1600(), k))
        s = {s, $sformatf(" %s=%0d", timing_name(k), timing_get(timing, k))};
    return s;
  endfunction
endclass
