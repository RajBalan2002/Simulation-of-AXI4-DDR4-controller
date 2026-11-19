// -----------------------------------------------------------------------------
// ddr4_protocol_checker.sv
// Independent DDR4 command checker. Judges every command the DFI monitor
// reports against the timing values programmed into the DUT (cfg), by
// subtracting cycle stamps; it never looks at the RTL's own counters.
//
// Datasheet sources (Micron 8Gb DDR4 MT40A1G8):
//   Table 23  command truth table (decoding is in dfi_monitor)
//   Table 51  refresh: tREFI, tRFC, at most 8 REFRESH commands postponed
//   Table 153 / 161  AC timing: tRCD tRP tRAS tRC tRTP tWR tRRD_S/L tFAW
//             tCCD_S/L tWTR_S/L tMRD tMOD tZQinit tZQoper tXS tXP tCKESR
//   Initialization: RESET_n low >= 200 us, CKE low >= 500 us after RESET_n,
//             tXPR before the first command, MR3,6,5,4,2,1,0 then ZQCL,
//             tDLLK and tZQinit before normal operation
//   Self-refresh: entered only with all banks precharged and tRP met; CKE
//             low >= tCKESR; tXS after exit; one REFRESH after exit before
//             the next entry
//
// The values programmed are themselves checked against the DDR4-1600
// minimums (timing_default_1600) unless cfg.allow_below_ds is set.
// Each accepted command is published with the rule that limited it.
// -----------------------------------------------------------------------------
class ddr4_protocol_checker extends uvm_subscriber #(dfi_cmd_item);
  `uvm_component_utils(ddr4_protocol_checker)

  ddr4_env_cfg cfg;
  uvm_analysis_port #(ddr4_check_item) ap;

  timing_t tim;
  longint  cyc;

  // per bank
  bit               open_b   [NUM_BANKS];
  logic [ROW_W-1:0] row_b    [NUM_BANKS];
  longint           last_act [NUM_BANKS];
  longint           last_pre [NUM_BANKS];
  longint           last_rd  [NUM_BANKS];
  longint           last_wr  [NUM_BANKS];
  cmd_e             last_cmd [NUM_BANKS];
  // per bank group
  longint           act_bg   [NUM_BG];
  longint           cas_bg   [NUM_BG];
  longint           wr_bg    [NUM_BG];
  // device
  longint           act_hist [4];
  longint           last_rd_any, last_ref, last_mrs, last_zq, last_srx, last_sre;
  longint           rst_low, rst_rise, cke_rise;
  int               zq_need, last_cas_bg;
  bit               in_sr, init_done, prev_cke;
  int               n_mrs, n_zq;
  int               mr_order [7] = '{3, 6, 5, 4, 2, 1, 0};
  // refresh accounting
  int               owed;
  longint           credit, acct_cyc;
  bit               closed_for_sre;   // a PREA closed open banks before SRE
  // binding rule of the command being judged
  rule_e            binding;
  // statistics
  int               n_cmd [cmd_e];

  function new(string name, uvm_component parent);
    super.new(name, parent);
    ap = new("ap", this);
  endfunction

  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    if (!uvm_config_db#(ddr4_env_cfg)::get(this, "", "cfg", cfg))
      `uvm_fatal("NOCFG", "cfg not set")
  endfunction

  function void start_of_simulation_phase(uvm_phase phase);
    timing_t ds = timing_default_1600();
    if (!cfg.allow_below_ds)
      for (int k = 0; k < N_TIMING; k++)
        if (timing_get(cfg.timing, k) < timing_get(ds, k))
          `uvm_error("PC_CFG", $sformatf("%s programmed to %0d, below the DDR4-1600 minimum %0d",
                                         timing_name(k), timing_get(cfg.timing, k), timing_get(ds, k)))
    reset_state();
  endfunction

  function void reset_state();
    tim = cfg.timing;
    foreach (open_b[i]) begin
      open_b[i] = 0;  row_b[i] = '0;  last_cmd[i] = CMD_DES;
      last_act[i] = NEVER;  last_pre[i] = NEVER;  last_rd[i] = NEVER;  last_wr[i] = NEVER;
    end
    foreach (act_bg[i]) begin act_bg[i] = NEVER; cas_bg[i] = NEVER; wr_bg[i] = NEVER; end
    foreach (act_hist[i]) act_hist[i] = NEVER;
    last_rd_any = NEVER;  last_ref = NEVER;  last_mrs = NEVER;  last_zq = NEVER;
    last_srx = NEVER;  last_sre = NEVER;  rst_low = NEVER;  rst_rise = NEVER;  cke_rise = NEVER;
    zq_need = 0;  last_cas_bg = -1;
    in_sr = 0;  init_done = 0;  prev_cke = 0;  n_mrs = 0;  n_zq = 0;
    owed = 0;  credit = 0;  acct_cyc = 0;  closed_for_sre = 0;
  endfunction

  // "need" cycles must separate "since" from now. Zero slack makes it the binding rule.
  function void spacing(rule_e r, string what, longint since, int need);
    longint gap;
    if (since == NEVER) return;
    gap = cyc - since;
    if (gap < need)
      `uvm_error("PC", $sformatf("@%0d %s violated: %0d cycles, need %0d", cyc, what, gap, need))
    else if (gap == need && binding == R_NONE)
      binding = r;
  endfunction

  // Refresh debt grows by one every t_refi cycles outside self-refresh.
  function void account(longint now);
    if (init_done && !in_sr) begin
      credit += now - acct_cyc;
      while (credit >= longint'(cfg.t_refi)) begin
        credit -= cfg.t_refi;
        owed++;
      end
      if (owed > 9)
        `uvm_error("PC", $sformatf("@%0d %0d refreshes owed: more than 8 postponed", now, owed))
    end
    acct_cyc = now;
  endfunction

  function void write(dfi_cmd_item t);
    dfi_cmd_item    c = t;
    ddr4_check_item o;
    int b, g;
    if (!cfg.en_checker) return;
    if (c.first) reset_state();
    cyc     = c.cyc;
    b       = c.bank();
    g       = int'(c.bg);
    binding = R_NONE;
    account(cyc);
    if (c.cmd != CMD_DES) begin          // first use of a key: Questa warns on ++ of a missing entry
      if (!n_cmd.exists(c.cmd)) n_cmd[c.cmd] = 0;
      n_cmd[c.cmd]++;
    end

    o = ddr4_check_item::type_id::create("chk");
    o.cmd = c.cmd;
    o.prev_same_bank = last_cmd[b];
    o.same_bg_as_last_cas = (g == last_cas_bg);
    o.gap_since_srx = -1;

    // -------------------------------------------- reset, CKE, init_done
    if (c.first && !c.reset_n) rst_low = cyc;
    if (!c.prev_reset_n && c.reset_n && !c.first) begin
      spacing(R_OTHER, "RESET_n low time", rst_low, cfg.eff_t_rst());
      rst_rise = cyc;
    end
    if (c.reset_n == 0 && c.prev_reset_n == 1) rst_low = cyc;
    if (!init_done && c.cke && !c.prev_cke && !c.first) begin
      spacing(R_OTHER, "CKE low after RESET_n release", rst_rise, cfg.eff_t_cke());
      cke_rise = cyc;
    end
    if (c.init_done && !c.prev_init_done) begin
      if (n_mrs != 7 || n_zq != 1)
        `uvm_error("PC", $sformatf("@%0d init_done before the full MRS/ZQCL sequence (%0d MRS, %0d ZQCL)",
                                   cyc, n_mrs, n_zq))
      spacing(R_OTHER, "init_done after ZQCL (tZQinit + tDLLK)", last_zq, int'(tim.t_zqinit) + cfg.t_dllk);
      init_done = 1;
      acct_cyc  = cyc;
    end
    if (c.ref_ovf) `uvm_error("PC", $sformatf("@%0d controller flagged refresh overflow", cyc))

    // ----------------------------------- rules common to every command
    if (c.cmd != CMD_DES) begin
      if (!c.reset_n) `uvm_error("PC", $sformatf("@%0d command while RESET_n is low: %s", cyc, c.convert2string()))
      if (c.cmd != CMD_SRE && !c.cke) `uvm_error("PC", $sformatf("@%0d command while CKE is low: %s", cyc, c.convert2string()))
      if (in_sr && c.cmd != CMD_SRX) `uvm_error("PC", $sformatf("@%0d command during self-refresh: %s", cyc, c.convert2string()))
      if (c.cmd != CMD_SRX) begin
        spacing(R_RFC, "tRFC", last_ref, int'(tim.t_rfc));
        spacing(R_ZQ,  "tZQ",  last_zq,  zq_need);
        spacing(R_XS,  "tXS",  last_srx, int'(tim.t_xs));
        if (c.cmd == CMD_MRS) spacing(R_MRD, "tMRD", last_mrs, int'(tim.t_mrd));
        else                  spacing(R_MOD, "tMOD", last_mrs, int'(tim.t_mod));
      end
      if (!init_done) begin
        if (c.cmd != CMD_MRS && c.cmd != CMD_ZQCL)
          `uvm_error("PC", $sformatf("@%0d %s before initialization finished", cyc, c.cmd.name()))
        spacing(R_XPR, "tXPR", cke_rise, cfg.t_xpr);
      end
    end else if (!c.first) begin
      if (in_sr && c.cke)                  `uvm_error("PC", $sformatf("@%0d CKE high during self-refresh", cyc))
      if (init_done && !in_sr && !c.cke)   `uvm_error("PC", $sformatf("@%0d CKE low outside self-refresh", cyc))
    end

    case (c.cmd)
      CMD_MRS: begin
        if (n_mrs >= 7) `uvm_error("PC", $sformatf("@%0d more than seven MRS commands", cyc))
        else begin
          if (c.mr_sel != mr_order[n_mrs])
            `uvm_error("PC", $sformatf("@%0d MRS to MR%0d, expected MR%0d", cyc, c.mr_sel, mr_order[n_mrs]))
          if (c.opcode !== cfg.mr[c.mr_sel])
            `uvm_error("PC", $sformatf("@%0d MR%0d opcode 0x%04h, programmed 0x%04h",
                                       cyc, c.mr_sel, c.opcode, cfg.mr[c.mr_sel]))
        end
        if (n_zq != 0) `uvm_error("PC", $sformatf("@%0d MRS after ZQCL", cyc))
        last_mrs = cyc;  n_mrs++;
      end

      CMD_ZQCL: begin
        if (n_mrs != 7) `uvm_error("PC", $sformatf("@%0d ZQCL before all seven MRS commands", cyc))
        zq_need = init_done ? int'(tim.t_zqoper) : int'(tim.t_zqinit);
        last_zq = cyc;  n_zq++;
      end

      CMD_ACT: begin
        if (open_b[b]) `uvm_error("PC", $sformatf("@%0d ACT to bank %0d which is already open", cyc, b))
        spacing(R_RP, "tRP", last_pre[b], int'(tim.t_rp));
        spacing(R_RC, "tRC", last_act[b], int'(tim.t_rc));
        for (int k = 0; k < NUM_BG; k++)
          if (k == g) spacing(R_RRD_L, "tRRD_L", act_bg[k], int'(tim.t_rrd_l));
          else        spacing(R_RRD_S, "tRRD_S", act_bg[k], int'(tim.t_rrd_s));
        spacing(R_FAW, "tFAW", act_hist[3], int'(tim.t_faw));
        open_b[b] = 1;  row_b[b] = c.row;
        last_act[b] = cyc;  act_bg[g] = cyc;
        act_hist[3] = act_hist[2];  act_hist[2] = act_hist[1];
        act_hist[1] = act_hist[0];  act_hist[0] = cyc;
      end

      CMD_RD, CMD_WR: begin
        if (!open_b[b]) `uvm_error("PC", $sformatf("@%0d %s to closed bank %0d", cyc, c.cmd.name(), b))
        spacing(R_RCD, "tRCD", last_act[b], int'(tim.t_rcd));
        for (int k = 0; k < NUM_BG; k++)
          if (k == g) spacing(R_CCD_L, "tCCD_L", cas_bg[k], int'(tim.t_ccd_l));
          else        spacing(R_CCD_S, "tCCD_S", cas_bg[k], int'(tim.t_ccd_s));
        if (c.cmd == CMD_RD) begin
          for (int k = 0; k < NUM_BG; k++)
            if (k == g) spacing(R_WTR_L, "tWTR_L (write to read, same group)",  wr_bg[k], int'(tim.t_wr2rd_l));
            else        spacing(R_WTR_S, "tWTR_S (write to read, other group)", wr_bg[k], int'(tim.t_wr2rd_s));
          last_rd[b] = cyc;  last_rd_any = cyc;
        end else begin
          spacing(R_RD2WR, "read to write turnaround", last_rd_any, int'(tim.t_rd2wr));
          last_wr[b] = cyc;  wr_bg[g] = cyc;
        end
        cas_bg[g] = cyc;  last_cas_bg = g;
      end

      CMD_PRE: begin
        if (!open_b[b]) `uvm_error("PC", $sformatf("@%0d PRE to bank %0d with no open row", cyc, b))
        spacing(R_RAS,    "tRAS",             last_act[b], int'(tim.t_ras));
        spacing(R_RTP,    "tRTP",             last_rd[b],  int'(tim.t_rtp));
        spacing(R_WR2PRE, "write recovery",   last_wr[b],  int'(tim.t_wr2pre));
        open_b[b] = 0;  last_pre[b] = cyc;
      end

      CMD_PREA: begin
        bit any_open = 0;
        for (int k = 0; k < NUM_BANKS; k++) begin
          if (open_b[k]) begin
            any_open = 1;
            spacing(R_RAS,    "tRAS (PREA)",           last_act[k], int'(tim.t_ras));
            spacing(R_RTP,    "tRTP (PREA)",           last_rd[k],  int'(tim.t_rtp));
            spacing(R_WR2PRE, "write recovery (PREA)", last_wr[k],  int'(tim.t_wr2pre));
          end
          open_b[k] = 0;  last_pre[k] = cyc;
        end
        if (c.sr_req && any_open) closed_for_sre = 1;
      end

      CMD_REF, CMD_SRE: begin
        for (int k = 0; k < NUM_BANKS; k++) begin
          if (open_b[k]) `uvm_error("PC", $sformatf("@%0d %s with bank %0d open", cyc, c.cmd.name(), k))
          spacing(R_RP, "tRP before REF/SRE", last_pre[k], int'(tim.t_rp));
        end
        if (c.cmd == CMD_REF) begin
          o.owed = owed;
          if (owed > 0) owed--;
          last_ref = cyc;
        end else begin
          if (!c.sr_req) `uvm_error("PC", $sformatf("@%0d self-refresh entry without a request", cyc))
          if (last_srx != NEVER && last_ref < last_srx)
            `uvm_error("PC", $sformatf("@%0d self-refresh re-entered with no REFRESH since the last exit", cyc))
          o.gap_since_srx  = (last_srx == NEVER) ? -1 : cyc - last_srx;
          o.sre_after_prea = closed_for_sre;
          closed_for_sre = 0;
          in_sr = 1;  last_sre = cyc;
          owed = 0;  credit = 0;            // the device refreshes itself while in self-refresh
        end
      end

      CMD_SRX: begin
        if (!in_sr) `uvm_error("PC", $sformatf("@%0d SRX while not in self-refresh", cyc))
        spacing(R_CKESR, "tCKESR", last_sre, cfg.t_ckesr + 1);
        o.sr_cycles = cyc - last_sre;
        in_sr = 0;  last_srx = cyc;  acct_cyc = cyc;
      end

      CMD_ZQCS: `uvm_error("PC", $sformatf("@%0d ZQCS issued: not supported by this controller", cyc))
      CMD_NOP:  ;
      CMD_DES:  ;
      default:  `uvm_error("PC", $sformatf("@%0d unexpected command %s", cyc, c.cmd.name()))
    endcase

    if (c.cmd inside {CMD_ACT, CMD_RD, CMD_WR, CMD_PRE}) last_cmd[b] = c.cmd;
    prev_cke = c.cke;
    if (c.cmd != CMD_DES) begin
      o.rule = binding;
      ap.write(o);
    end
  endfunction

  function void check_phase(uvm_phase phase);
    if (cfg.en_checker && n_cmd.exists(CMD_MRS) && !init_done)
      `uvm_error("PC", "initialization never completed")
  endfunction

  function void report_phase(uvm_phase phase);
    string s = "commands:";
    foreach (n_cmd[k]) s = {s, $sformatf(" %s=%0d", k.name(), n_cmd[k])};
    `uvm_info("PC", s, UVM_LOW)
  endfunction
endclass
