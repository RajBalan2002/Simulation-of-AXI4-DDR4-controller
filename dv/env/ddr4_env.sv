// -----------------------------------------------------------------------------
// ddr4_env.sv
// Agents: AXI master, APB master + RAL, DFI responder.
// Judges: scoreboard (data), protocol checker (DDR4 commands), coverage.
// -----------------------------------------------------------------------------
class ddr4_vseqr extends uvm_sequencer;
  `uvm_component_utils(ddr4_vseqr)
  axi_sequencer  axi_sqr;
  apb_sequencer  apb_sqr;
  ddr4_reg_block regmodel;
  ddr4_env_cfg   cfg;

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction
endclass

class ddr4_env extends uvm_env;
  `uvm_component_utils(ddr4_env)

  ddr4_env_cfg          cfg;
  axi_agent             axi_agt;
  apb_agent             apb_agt;
  dfi_agent             dfi_agt;
  ddr4_probe_monitor    probe_mon;
  ddr4_scoreboard       sb;
  ddr4_protocol_checker pc;
  ddr4_coverage         cov;
  ddr4_vseqr            vseqr;

  ddr4_reg_block                       regmodel;
  ddr4_reg_adapter                     adapter;
  uvm_reg_predictor #(apb_seq_item)    predictor;

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    if (!uvm_config_db#(ddr4_env_cfg)::get(this, "", "cfg", cfg))
      `uvm_fatal("NOCFG", "ddr4_env_cfg not set for the env")
    uvm_config_db#(ddr4_env_cfg)::set(this, "*", "cfg", cfg);

    axi_agt   = axi_agent::type_id::create("axi_agt", this);
    apb_agt   = apb_agent::type_id::create("apb_agt", this);
    dfi_agt   = dfi_agent::type_id::create("dfi_agt", this);
    probe_mon = ddr4_probe_monitor::type_id::create("probe_mon", this);
    sb        = ddr4_scoreboard::type_id::create("sb", this);
    pc        = ddr4_protocol_checker::type_id::create("pc", this);
    cov       = ddr4_coverage::type_id::create("cov", this);
    vseqr     = ddr4_vseqr::type_id::create("vseqr", this);

    regmodel = ddr4_reg_block::type_id::create("regmodel");
    regmodel.build();
    regmodel.reset();
    adapter   = ddr4_reg_adapter::type_id::create("adapter");
    predictor = uvm_reg_predictor#(apb_seq_item)::type_id::create("predictor", this);
  endfunction

  function void connect_phase(uvm_phase phase);
    // data path checking
    axi_agt.mon.ap.connect(sb.axi_imp);
    probe_mon.ap.connect(sb.req_imp);
    dfi_agt.rsp.ap.connect(sb.rdevt_imp);
    // DDR4 protocol
    dfi_agt.mon.ap.connect(pc.analysis_export);
    // coverage
    axi_agt.mon.ap.connect(cov.axi_imp);
    pc.ap.connect(cov.chk_imp);
    sb.ecc_ap.connect(cov.ecc_imp);
    apb_agt.mon.ap.connect(cov.apb_imp);
    // registers: explicit prediction from the APB monitor
    regmodel.default_map.set_sequencer(apb_agt.sqr, adapter);
    regmodel.default_map.set_auto_predict(0);
    predictor.map     = regmodel.default_map;
    predictor.adapter = adapter;
    apb_agt.mon.ap.connect(predictor.bus_in);
    // virtual sequencer
    vseqr.axi_sqr  = axi_agt.sqr;
    vseqr.apb_sqr  = apb_agt.sqr;
    vseqr.regmodel = regmodel;
    vseqr.cfg      = cfg;
  endfunction

  // Nothing queued or in flight anywhere.
  function bit idle();
    return axi_agt.idle() && sb.idle();
  endfunction
endclass
