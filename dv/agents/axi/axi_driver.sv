// -----------------------------------------------------------------------------
// axi_driver.sv
// AXI4 master driver. Items are taken from the sequencer at once and handed
// to a write thread or a read thread, so writes and reads overlap on the bus.
// A third thread drives BREADY and RREADY at the configured ready rates.
// Signals change on the falling edge; handshakes are judged on the rising edge.
// On reset every thread stops, the bus returns to idle and queued items are
// dropped (the test stops its sequences before resetting).
// -----------------------------------------------------------------------------
class axi_driver extends uvm_driver #(axi_seq_item);
  `uvm_component_utils(axi_driver)

  virtual ddr4_axi_if vif;
  ddr4_env_cfg        cfg;

  mailbox #(axi_seq_item) wr_mb;
  mailbox #(axi_seq_item) rd_mb;
  int                     wr_busy, rd_busy;

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    if (!uvm_config_db#(ddr4_env_cfg)::get(this, "", "cfg", cfg))
      `uvm_fatal("NOCFG", "cfg not set")
    vif   = cfg.axi_vif;
    wr_mb = new(2);
    rd_mb = new(2);
  endfunction

  // True when nothing is queued or being driven.
  function bit idle();
    return (wr_mb.num() == 0) && (rd_mb.num() == 0) && !wr_busy && !rd_busy;
  endfunction

  task run_phase(uvm_phase phase);
    forever begin
      vif.idle();
      wr_busy = 0;
      rd_busy = 0;
      @(posedge vif.aclk iff vif.aresetn === 1'b1);
      fork
        get_loop();
        wr_loop();
        rd_loop();
        ready_loop();
        @(negedge vif.aresetn);
      join_any
      disable fork;
      flush_queues();
    end
  endtask

  task flush_queues();
    axi_seq_item t;
    while (wr_mb.try_get(t)) begin end
    while (rd_mb.try_get(t)) begin end
  endtask

  task get_loop();
    axi_seq_item t;
    forever begin
      seq_item_port.get(t);
      if (t.is_write) wr_mb.put(t);
      else            rd_mb.put(t);
    end
  endtask

  task wr_loop();
    axi_seq_item t;
    forever begin
      wr_mb.get(t);
      wr_busy = 1;
      repeat (t.addr_delay) @(negedge vif.aclk);
      @(negedge vif.aclk);
      vif.awid    = t.id;     vif.awaddr = t.addr;  vif.awlen = t.len;
      vif.awsize  = t.size;   vif.awburst = t.burst;
      vif.awvalid = 1'b1;
      @(posedge vif.aclk);
      while (vif.awready !== 1'b1) @(posedge vif.aclk);
      @(negedge vif.aclk);
      vif.awvalid = 1'b0;
      for (int i = 0; i < t.beats(); i++) begin
        if (t.beat_delay[i] > 0) begin
          vif.wvalid = 1'b0;
          repeat (t.beat_delay[i]) @(negedge vif.aclk);
        end
        vif.wdata  = t.data[i];
        vif.wstrb  = t.strb[i];
        vif.wlast  = (i == t.beats() - 1);
        vif.wvalid = 1'b1;
        @(posedge vif.aclk);
        while (vif.wready !== 1'b1) @(posedge vif.aclk);
        @(negedge vif.aclk);
      end
      vif.wvalid = 1'b0;
      vif.wlast  = 1'b0;
      wr_busy = 0;
    end
  endtask

  task rd_loop();
    axi_seq_item t;
    forever begin
      rd_mb.get(t);
      rd_busy = 1;
      repeat (t.addr_delay) @(negedge vif.aclk);
      @(negedge vif.aclk);
      vif.arid    = t.id;     vif.araddr = t.addr;  vif.arlen = t.len;
      vif.arsize  = t.size;   vif.arburst = t.burst;
      vif.arvalid = 1'b1;
      @(posedge vif.aclk);
      while (vif.arready !== 1'b1) @(posedge vif.aclk);
      @(negedge vif.aclk);
      vif.arvalid = 1'b0;
      rd_busy = 0;
    end
  endtask

  task ready_loop();
    forever begin
      @(negedge vif.aclk);
      vif.bready = ($urandom_range(1, 100) <= cfg.bready_pct);
      vif.rready = ($urandom_range(1, 100) <= cfg.rready_pct);
    end
  endtask
endclass
