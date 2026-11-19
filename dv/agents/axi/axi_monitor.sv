// -----------------------------------------------------------------------------
// axi_monitor.sv
// Rebuilds whole AXI bursts from the bus and publishes each one when it ends:
// a write at its B handshake, a read at its RLAST handshake. Samples on the
// rising edge of aclk. Also checks the burst-level rules the slave owns:
// one B per write after its last beat, RID matching ARID, RLAST on beat ARLEN.
// -----------------------------------------------------------------------------
class axi_monitor extends uvm_monitor;
  `uvm_component_utils(axi_monitor)

  virtual ddr4_axi_if vif;
  ddr4_env_cfg        cfg;
  uvm_analysis_port #(axi_seq_item) ap;

  axi_seq_item wr_q [$];   // AW accepted, B not yet seen
  int          w_idx;      // next write in wr_q to receive W beats
  axi_seq_item rd_q [$];   // AR accepted, RLAST not yet seen
  longint      cyc;

  function new(string name, uvm_component parent);
    super.new(name, parent);
    ap = new("ap", this);
  endfunction

  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    if (!uvm_config_db#(ddr4_env_cfg)::get(this, "", "cfg", cfg))
      `uvm_fatal("NOCFG", "cfg not set")
    vif = cfg.axi_vif;
  endfunction

  function bit idle();
    return (wr_q.size() == 0) && (rd_q.size() == 0);
  endfunction

  task run_phase(uvm_phase phase);
    forever begin
      @(posedge vif.aclk);
      cyc++;
      if (vif.aresetn !== 1'b1) begin
        wr_q.delete();  rd_q.delete();  w_idx = 0;
        continue;
      end
      sample_aw();
      sample_w();
      sample_b();
      sample_ar();
      sample_r();
    end
  endtask

  function void sample_aw();
    axi_seq_item t;
    if (!(vif.awvalid && vif.awready)) return;
    t = axi_seq_item::type_id::create("wr");
    t.is_write = 1;
    t.id = vif.awid;  t.addr = vif.awaddr;  t.len = vif.awlen;
    t.size = vif.awsize;  t.burst = vif.awburst;
    t.data = new[0];  t.strb = new[0];
    t.start_cyc = cyc;
    wr_q.push_back(t);
  endfunction

  function void sample_w();
    axi_seq_item t;
    int n;
    if (!(vif.wvalid && vif.wready)) return;
    if (w_idx >= wr_q.size()) begin
      `uvm_error("AXI_MON", "W beat accepted with no write address outstanding")
      return;
    end
    t = wr_q[w_idx];
    n = t.data.size();
    t.data = new[n + 1](t.data);  t.data[n] = vif.wdata;
    t.strb = new[n + 1](t.strb);  t.strb[n] = vif.wstrb;
    if (vif.wlast) begin
      if (n + 1 != t.beats())
        `uvm_error("AXI_MON", $sformatf("WLAST on beat %0d of a %0d-beat write", n + 1, t.beats()))
      w_idx++;
    end
  endfunction

  function void sample_b();
    axi_seq_item t;
    if (!(vif.bvalid && vif.bready)) return;
    if (wr_q.size() == 0 || w_idx == 0) begin
      `uvm_error("AXI_MON", "write response before the last write beat")
      return;
    end
    t = wr_q.pop_front();
    w_idx--;
    t.bresp   = vif.bresp;
    t.resp_id = vif.bid;
    t.end_cyc = cyc;
    if (vif.bid !== t.id)
      `uvm_error("AXI_MON", $sformatf("BID %0d does not match AWID %0d", vif.bid, t.id))
    ap.write(t);
  endfunction

  function void sample_ar();
    axi_seq_item t;
    if (!(vif.arvalid && vif.arready)) return;
    t = axi_seq_item::type_id::create("rd");
    t.is_write = 0;
    t.id = vif.arid;  t.addr = vif.araddr;  t.len = vif.arlen;
    t.size = vif.arsize;  t.burst = vif.arburst;
    t.start_cyc = cyc;
    rd_q.push_back(t);
  endfunction

  function void sample_r();
    axi_seq_item t;
    bit last_due;
    if (!(vif.rvalid && vif.rready)) return;
    if (rd_q.size() == 0) begin
      `uvm_error("AXI_MON", "read data with no read address outstanding")
      return;
    end
    t = rd_q[0];
    t.rdata.push_back(vif.rdata);
    t.rresp.push_back(vif.rresp);
    if (vif.rid !== t.id)
      `uvm_error("AXI_MON", $sformatf("RID %0d does not match ARID %0d", vif.rid, t.id))
    last_due = (t.rdata.size() == t.beats());
    if (vif.rlast !== last_due)
      `uvm_error("AXI_MON", $sformatf("RLAST=%0b on beat %0d of a %0d-beat read",
                                      vif.rlast, t.rdata.size(), t.beats()))
    if (last_due) begin
      t.resp_id = vif.rid;
      t.end_cyc = cyc;
      void'(rd_q.pop_front());
      ap.write(t);
    end
  endfunction
endclass
