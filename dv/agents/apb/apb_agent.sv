// -----------------------------------------------------------------------------
// apb_agent.sv
// APB master agent: item, driver, monitor, agent. The driver reuses the
// transfer task in ddr4_apb_if. The monitor publishes every completed
// transfer; the RAL predictor and the register coverage subscribe to it.
// -----------------------------------------------------------------------------
class apb_seq_item extends uvm_sequence_item;
  `uvm_object_utils(apb_seq_item)
  rand bit        write;
  rand bit [11:0] addr;
  rand bit [31:0] data;     // write data, or read data once complete
  bit             slverr;

  constraint c_aligned { addr[1:0] == 2'b00; }

  function new(string name = "apb_seq_item");
    super.new(name);
  endfunction

  function string convert2string();
    return $sformatf("APB %s 0x%03h = 0x%08h%s", write ? "WR" : "RD", addr, data,
                     slverr ? " SLVERR" : "");
  endfunction
endclass



typedef uvm_sequencer #(apb_seq_item) apb_sequencer;

class apb_driver extends uvm_driver #(apb_seq_item);
  `uvm_component_utils(apb_driver)
  virtual ddr4_apb_if vif;
  ddr4_env_cfg        cfg;

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    if (!uvm_config_db#(ddr4_env_cfg)::get(this, "", "cfg", cfg))
      `uvm_fatal("NOCFG", "cfg not set")
    vif = cfg.apb_vif;
  endfunction

  task run_phase(uvm_phase phase);
    logic [31:0] rd;
    bit          err;
    forever begin
      seq_item_port.get_next_item(req);
      if (vif.presetn !== 1'b1) @(posedge vif.pclk iff vif.presetn === 1'b1);
      vif.xfer(req.write, req.addr, req.data, rd, err);
      if (!req.write) req.data = rd;
      req.slverr = err;
      seq_item_port.item_done();
    end
  endtask
endclass

class apb_monitor extends uvm_monitor;
  `uvm_component_utils(apb_monitor)
  virtual ddr4_apb_if vif;
  ddr4_env_cfg        cfg;
  uvm_analysis_port #(apb_seq_item) ap;

  function new(string name, uvm_component parent);
    super.new(name, parent);
    ap = new("ap", this);
  endfunction

  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    if (!uvm_config_db#(ddr4_env_cfg)::get(this, "", "cfg", cfg))
      `uvm_fatal("NOCFG", "cfg not set")
    vif = cfg.apb_vif;
  endfunction

  task run_phase(uvm_phase phase);
    apb_seq_item t;
    forever begin
      @(posedge vif.pclk);
      if (vif.presetn === 1'b1 && vif.psel && vif.penable && vif.pready) begin
        t = apb_seq_item::type_id::create("apb");
        t.write  = vif.pwrite;
        t.addr   = vif.paddr;
        t.data   = vif.pwrite ? vif.pwdata : vif.prdata;
        t.slverr = vif.pslverr;
        ap.write(t);
      end
    end
  endtask
endclass

class apb_agent extends uvm_agent;
  `uvm_component_utils(apb_agent)
  apb_sequencer sqr;
  apb_driver    drv;
  apb_monitor   mon;

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    sqr = apb_sequencer::type_id::create("sqr", this);
    drv = apb_driver::type_id::create("drv", this);
    mon = apb_monitor::type_id::create("mon", this);
  endfunction

  function void connect_phase(uvm_phase phase);
    drv.seq_item_port.connect(sqr.seq_item_export);
  endfunction
endclass
