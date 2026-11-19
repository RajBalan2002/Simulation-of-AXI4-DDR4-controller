// -----------------------------------------------------------------------------
// ddr4_coverage.sv
// Functional coverage, one covergroup per row of the verification plan's
// coverage model.
// -----------------------------------------------------------------------------
`uvm_analysis_imp_decl(_cov_axi)
`uvm_analysis_imp_decl(_cov_chk)
`uvm_analysis_imp_decl(_cov_ecc)
`uvm_analysis_imp_decl(_cov_apb)

class ddr4_coverage extends uvm_component;
  `uvm_component_utils(ddr4_coverage)

  uvm_analysis_imp_cov_axi #(axi_seq_item,    ddr4_coverage) axi_imp;
  uvm_analysis_imp_cov_chk #(ddr4_check_item, ddr4_coverage) chk_imp;
  uvm_analysis_imp_cov_ecc #(ddr4_ecc_obs,    ddr4_coverage) ecc_imp;
  uvm_analysis_imp_cov_apb #(apb_seq_item,    ddr4_coverage) apb_imp;

  ddr4_env_cfg cfg;

  // sampled values
  axi_seq_item    ax;
  int             strb_kind;      // 0 all 0xFF, 1 some 0x00, 2 partial
  int             max_stall;
  bit             crosses_chunk;
  ddr4_check_item ck;
  ddr4_ecc_obs    eo;
  apb_seq_item    ap_it;
  int             reg_idx;
  int             cfg_ratio;
  int             access_kind;    // see cg_dfi_cmd.cp_access, -1 = none
  int             cas_bg_kind;    // see cg_dfi_cmd.cp_cas_bg, -1 = none

  // ------------------------------------------------------------ AXI writes
  covergroup cg_axi_wr;
    option.per_instance = 1;
    cp_len   : coverpoint ax.len { bins one = {0}; bins short = {[1:6]}; bins eight = {7};
                                   bins to16 = {[8:15]}; bins long = {[16:254]}; bins max = {255}; }
    cp_start : coverpoint ax.addr[5:3];
    cp_cross : coverpoint crosses_chunk;
    cp_strb  : coverpoint strb_kind { bins full = {0}; bins skip = {1}; bins partial = {2}; }
    cp_burst : coverpoint ax.burst { bins fixed = {BURST_FIXED}; bins incr = {BURST_INCR}; bins wrap = {BURST_WRAP}; }
    cp_size  : coverpoint ax.size { bins full = {3}; bins narrow = {[0:2]}; }
    cp_resp  : coverpoint ax.bresp { bins okay = {RESP_OKAY}; bins slverr = {RESP_SLVERR}; }
    x_len_start  : cross cp_len, cp_start;
    x_strb_resp  : cross cp_strb, cp_resp { ignore_bins ok_partial = binsof(cp_strb.partial) && binsof(cp_resp.okay); }
    x_burst_size : cross cp_burst, cp_size;
  endgroup

  // ------------------------------------------------------------- AXI reads
  covergroup cg_axi_rd;
    option.per_instance = 1;
    cp_len   : coverpoint ax.len { bins one = {0}; bins short = {[1:6]}; bins eight = {7};
                                   bins to16 = {[8:15]}; bins long = {[16:254]}; bins max = {255}; }
    cp_start : coverpoint ax.addr[5:3];
    cp_resp  : coverpoint (ax.rresp.size() ? ax.rresp[0] : 2'b00) { bins okay = {RESP_OKAY}; bins slverr = {RESP_SLVERR}; }
    cp_burst : coverpoint ax.burst { bins fixed = {BURST_FIXED}; bins incr = {BURST_INCR}; bins wrap = {BURST_WRAP}; }
    cp_lat   : coverpoint (ax.end_cyc - ax.start_cyc) { bins fast = {[0:40]}; bins mid = {[41:200]}; bins slow = {[201:$]}; }
    x_len_start : cross cp_len, cp_start;
  endgroup

  // ------------------------------------------------------ DDR4 commands
  covergroup cg_dfi_cmd;
    option.per_instance = 1;
    cp_cmd  : coverpoint ck.cmd { bins act = {CMD_ACT}; bins rd = {CMD_RD}; bins wr = {CMD_WR};
                                  bins pre = {CMD_PRE}; bins prea = {CMD_PREA}; bins ref_ = {CMD_REF};
                                  bins sre = {CMD_SRE}; bins srx = {CMD_SRX}; bins mrs = {CMD_MRS};
                                  bins zqcl = {CMD_ZQCL}; }
    cp_prev : coverpoint ck.prev_same_bank { bins none = {CMD_DES}; bins act = {CMD_ACT}; bins rd = {CMD_RD};
                                             bins wr = {CMD_WR}; bins pre = {CMD_PRE}; }
    // row hit = RD/WR after RD/WR or ACT on that bank; a miss shows as PRE then ACT
    cp_access : coverpoint access_kind {
      bins rd_after_act = {0};  bins rd_after_rd = {1};  bins rd_after_wr = {2};
      bins wr_after_act = {3};  bins wr_after_wr = {4};  bins wr_after_rd = {5};
      bins pre_after_rd = {6};  bins pre_after_wr = {7};  bins act_after_pre = {8};
    }
    cp_cas_bg : coverpoint cas_bg_kind {
      bins rd_same = {0}; bins rd_other = {1}; bins wr_same = {2}; bins wr_other = {3};
    }
  endgroup

  // ------------------------------------- which timing rule limited a command
  covergroup cg_binding_rule;
    option.per_instance = 1;
    cp_rule : coverpoint ck.rule {
      bins rcd = {R_RCD};   bins rp = {R_RP};       bins ras = {R_RAS};     bins rc = {R_RC};
      bins rtp = {R_RTP};   bins wr2pre = {R_WR2PRE}; bins rrd_s = {R_RRD_S}; bins rrd_l = {R_RRD_L};
      bins faw = {R_FAW};   bins ccd_s = {R_CCD_S}; bins ccd_l = {R_CCD_L}; bins wtr_s = {R_WTR_S};
      bins wtr_l = {R_WTR_L}; bins rd2wr = {R_RD2WR}; bins rfc = {R_RFC};   bins mod = {R_MOD};
      bins mrd = {R_MRD};   bins xs = {R_XS};
      ignore_bins other = {R_NONE, R_ZQ, R_XPR, R_CKESR, R_OTHER};
    }
  endgroup

  // -------------------------------------------------------------- refresh
  covergroup cg_refresh;
    option.per_instance = 1;
    cp_owed : coverpoint ck.owed { bins none = {0}; bins one = {1}; bins few = {[2:4]};
                                   bins many = {[5:7]}; bins limit = {[8:9]}; }
  endgroup

  // -------------------------------------------------------- self-refresh
  covergroup cg_lowpower_sre;
    option.per_instance = 1;
    cp_from_open : coverpoint ck.sre_after_prea { bins from_idle = {0}; bins from_open = {1}; }
    cp_reentry   : coverpoint ck.gap_since_srx { bins first = {-1}; bins quick = {[0:300]}; bins later = {[301:$]}; }
  endgroup

  covergroup cg_lowpower_srx;
    option.per_instance = 1;
    cp_dur : coverpoint ck.sr_cycles { bins minimum = {[0:8]}; bins short = {[9:200]}; bins long = {[201:$]}; }
  endgroup

  // ------------------------------------------------------------------ ECC
  covergroup cg_ecc;
    option.per_instance = 1;
    cp_kind : coverpoint eo.kind { bins none = {0}; bins single = {1}; bins double = {2}; }
    cp_word : coverpoint eo.word { bins w[] = {[0:7]}; }
    cp_mask : coverpoint eo.in_mask;
    x_kind_word : cross cp_kind, cp_word;
    x_kind_mask : cross cp_kind, cp_mask;
  endgroup

  covergroup cg_ecc_bit;
    option.per_instance = 1;
    cp_bit  : coverpoint eo.bit_a { bins b[] = {[0:71]}; }
    cp_word : coverpoint eo.word  { bins w[] = {[0:7]}; }
    x_bit_word : cross cp_bit, cp_word;
  endgroup

  covergroup cg_ecc_double;
    option.per_instance = 1;
    cp_pair : coverpoint ((eo.bit_a < 64 ? 0 : 1) + (eo.bit_b < 64 ? 0 : 1)) {
      bins both_data = {0}; bins mixed = {1}; bins both_check = {2}; }
  endgroup

  // ------------------------------------------------------------ registers
  covergroup cg_reg;
    option.per_instance = 1;
    cp_reg : coverpoint reg_idx { bins ctrl = {0}; bins status = {1}; bins int_en = {2};
                                  bins int_stat = {3}; bins ecc_ce = {4}; bins ecc_ue = {5};
                                  bins latency = {6}; bins refresh = {7}; bins init = {[8:11]};
                                  bins ckesr = {12}; bins mr = {[16:22]}; bins timing = {[32:53]}; }
    cp_dir : coverpoint ap_it.write;
    x_reg_dir : cross cp_reg, cp_dir;
  endgroup

  // -------------------------------------------------------- configuration
  covergroup cg_config;
    option.per_instance = 1;
    cp_ratio  : coverpoint cfg_ratio { bins fast = {0}; bins equal = {1}; bins slow = {2}; bins odd = {3}; }
    cp_wrlat  : coverpoint cfg.wr_lat   { bins l[] = {[0:7]}; }
    cp_rdlat  : coverpoint cfg.rden_lat { bins l[] = {[0:7]}; }
    cp_inj    : coverpoint (cfg.inj1_pct + cfg.inj2_pct > 0);
  endgroup

  function new(string name, uvm_component parent);
    super.new(name, parent);
    axi_imp = new("axi_imp", this);
    chk_imp = new("chk_imp", this);
    ecc_imp = new("ecc_imp", this);
    apb_imp = new("apb_imp", this);
    cg_axi_wr       = new();
    cg_axi_rd       = new();
    cg_dfi_cmd      = new();
    cg_binding_rule = new();
    cg_refresh      = new();
    cg_lowpower_sre = new();
    cg_lowpower_srx = new();
    cg_ecc          = new();
    cg_ecc_bit      = new();
    cg_ecc_double   = new();
    cg_reg          = new();
    cg_config       = new();
  endfunction

  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    if (!uvm_config_db#(ddr4_env_cfg)::get(this, "", "cfg", cfg))
      `uvm_fatal("NOCFG", "cfg not set")
  endfunction

  function void start_of_simulation_phase(uvm_phase phase);
    case (cfg.clk_set)
      "fast": cfg_ratio = 0;  "equal": cfg_ratio = 1;
      "slow": cfg_ratio = 2;  default: cfg_ratio = 3;
    endcase
    if (cfg.en_coverage) cg_config.sample();
  endfunction

  function void write_cov_axi(axi_seq_item t);
    if (!cfg.en_coverage) return;
    ax = t;
    crosses_chunk = (int'(t.addr[5:3]) + t.beats()) > 8;
    if (t.is_write) begin
      strb_kind = 0;
      foreach (t.strb[i]) begin
        if (t.strb[i] == 8'h00 && strb_kind == 0) strb_kind = 1;
        if (t.strb[i] != 8'h00 && t.strb[i] != 8'hFF) strb_kind = 2;
      end
      cg_axi_wr.sample();
    end else begin
      cg_axi_rd.sample();
    end
  endfunction

  function void write_cov_chk(ddr4_check_item t);
    if (!cfg.en_coverage) return;
    ck = t;
    access_kind = -1;
    case ({t.cmd, t.prev_same_bank})
      {CMD_RD,  CMD_ACT}: access_kind = 0;
      {CMD_RD,  CMD_RD }: access_kind = 1;
      {CMD_RD,  CMD_WR }: access_kind = 2;
      {CMD_WR,  CMD_ACT}: access_kind = 3;
      {CMD_WR,  CMD_WR }: access_kind = 4;
      {CMD_WR,  CMD_RD }: access_kind = 5;
      {CMD_PRE, CMD_RD }: access_kind = 6;
      {CMD_PRE, CMD_WR }: access_kind = 7;
      {CMD_ACT, CMD_PRE}: access_kind = 8;
      default: ;
    endcase
    cas_bg_kind = -1;
    if (t.cmd == CMD_RD) cas_bg_kind = t.same_bg_as_last_cas ? 0 : 1;
    if (t.cmd == CMD_WR) cas_bg_kind = t.same_bg_as_last_cas ? 2 : 3;
    cg_dfi_cmd.sample();
    cg_binding_rule.sample();
    if (t.cmd == CMD_REF) cg_refresh.sample();
    if (t.cmd == CMD_SRE) cg_lowpower_sre.sample();
    if (t.cmd == CMD_SRX) cg_lowpower_srx.sample();
  endfunction

  function void write_cov_ecc(ddr4_ecc_obs t);
    if (!cfg.en_coverage) return;
    eo = t;
    cg_ecc.sample();
    if (t.kind == 1) cg_ecc_bit.sample();
    if (t.kind == 2) cg_ecc_double.sample();
  endfunction

  function void write_cov_apb(apb_seq_item t);
    if (!cfg.en_coverage) return;
    ap_it   = t;
    reg_idx = int'(t.addr[11:2]);
    cg_reg.sample();
  endfunction

  function void report_phase(uvm_phase phase);
    `uvm_info("COV", $sformatf("axi_wr %.1f%%  axi_rd %.1f%%  dfi_cmd %.1f%%  binding_rule %.1f%%  refresh %.1f%%  sre %.1f%%  srx %.1f%%  ecc %.1f%%  ecc_bit %.1f%%  ecc_double %.1f%%  reg %.1f%%  config %.1f%%",
      cg_axi_wr.get_inst_coverage(), cg_axi_rd.get_inst_coverage(), cg_dfi_cmd.get_inst_coverage(),
      cg_binding_rule.get_inst_coverage(), cg_refresh.get_inst_coverage(),
      cg_lowpower_sre.get_inst_coverage(), cg_lowpower_srx.get_inst_coverage(),
      cg_ecc.get_inst_coverage(), cg_ecc_bit.get_inst_coverage(), cg_ecc_double.get_inst_coverage(),
      cg_reg.get_inst_coverage(), cg_config.get_inst_coverage()), UVM_LOW)
  endfunction
endclass
