// -----------------------------------------------------------------------------
// dfi_agent.sv
// DFI side of the environment.
//
// dfi_monitor   decodes the phase-0 command pins every cclk cycle (DDR4
//               truth table, datasheet Table 23) and publishes each real
//               command, plus any change of CKE, RESET_n or init_done.
//               SRE = REFRESH pins with CKE falling; SRX = deselect with CKE
//               rising while in self-refresh.
// dfi_responder plays the PHY and the DRAM: raises dfi_init_complete, stores
//               write bursts, returns read bursts, checks that write data and
//               read enables arrive at the programmed latencies, and injects
//               single- and double-bit errors, publishing what it injected.
// -----------------------------------------------------------------------------
class dfi_monitor extends uvm_monitor;
  `uvm_component_utils(dfi_monitor)

  virtual ddr4_dfi_if   vif;
  virtual ddr4_probe_if pvif;
  ddr4_env_cfg          cfg;
  uvm_analysis_port #(dfi_cmd_item) ap;

  longint cyc;
  bit     in_sr;
  bit     prev_cke, prev_reset_n, prev_init_done, first;
  // The DFI pins are registered: a command seen in cycle N was decided in
  // cycle N-1, so the probed status that goes with it is last cycle's.
  bit     init_done_d, sr_req_d, ref_ovf_d;

  function new(string name, uvm_component parent);
    super.new(name, parent);
    ap = new("ap", this);
  endfunction

  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    if (!uvm_config_db#(ddr4_env_cfg)::get(this, "", "cfg", cfg))
      `uvm_fatal("NOCFG", "cfg not set")
    vif  = cfg.dfi_vif;
    pvif = cfg.probe_vif;
  endfunction

  task run_phase(uvm_phase phase);
    dfi_cmd_item t;
    forever begin
      @(posedge vif.cclk);
      if (pvif.crst_n !== 1'b1) begin
        cyc = 0;  in_sr = 0;  first = 1;
        prev_cke = 0;  prev_reset_n = 0;  prev_init_done = 0;
        init_done_d = 0;  sr_req_d = 0;  ref_ovf_d = 0;
        continue;
      end
      cyc++;
      t = decode();
      if (t.cmd == CMD_SRE) in_sr = 1;
      if (t.cmd == CMD_SRX) in_sr = 0;
      if (t.cmd != CMD_DES || first || t.cke != prev_cke || t.reset_n != prev_reset_n ||
          t.init_done != prev_init_done || t.ref_ovf)
        ap.write(t);
      prev_cke = t.cke;  prev_reset_n = t.reset_n;  prev_init_done = t.init_done;
      first = 0;
      init_done_d = pvif.init_done;  sr_req_d = pvif.sr_req;  ref_ovf_d = pvif.ref_ovf;
    end
  endtask

  function dfi_cmd_item decode();
    dfi_cmd_item t = dfi_cmd_item::type_id::create("cmd");
    t.cyc            = cyc;
    t.first          = first;
    t.cke            = vif.cke[0];
    t.reset_n        = vif.reset_n[0];
    t.prev_cke       = prev_cke;
    t.prev_reset_n   = prev_reset_n;
    t.init_done      = init_done_d;
    t.prev_init_done = prev_init_done;
    t.sr_req         = sr_req_d;
    t.ref_ovf        = ref_ovf_d;
    t.bg             = vif.bg[0];
    t.ba             = vif.ba[0];
    t.row            = {vif.cas_n[0], vif.we_n[0], vif.address[0]};
    t.col            = vif.address[0][COL_W-1:0];
    t.opcode         = vif.address[0];
    t.mr_sel         = {vif.bg[0][0], vif.ba[0]};
    t.cmd            = CMD_DES;

    if (vif.cs_n[0] === 1'b0) begin
      if (vif.act_n[0] === 1'b0) begin
        t.cmd = CMD_ACT;
      end else begin
        case ({vif.ras_n[0], vif.cas_n[0], vif.we_n[0]})
          3'b000: t.cmd = CMD_MRS;
          3'b001: t.cmd = (prev_cke && !t.cke) ? CMD_SRE : CMD_REF;
          3'b010: t.cmd = vif.address[0][10] ? CMD_PREA : CMD_PRE;
          3'b100: t.cmd = CMD_WR;
          3'b101: t.cmd = CMD_RD;
          3'b110: t.cmd = vif.address[0][10] ? CMD_ZQCL : CMD_ZQCS;
          3'b111: t.cmd = CMD_NOP;
          default: `uvm_error("DFI_MON", $sformatf("@%0d reserved command encoding", cyc))
        endcase
      end
    end else if (vif.cs_n[0] !== 1'b1) begin
      `uvm_error("DFI_MON", $sformatf("@%0d dfi_cs_n[0] is X", cyc))
    end else if (in_sr && t.cke && !prev_cke) begin
      t.cmd = CMD_SRX;
    end
    return t;
  endfunction
endclass

class dfi_responder extends uvm_component;
  `uvm_component_utils(dfi_responder)

  localparam int KEY_W = BANK_W + ROW_W + BURST_COL_W;

  virtual ddr4_dfi_if   vif;
  virtual ddr4_probe_if pvif;
  ddr4_env_cfg          cfg;
  uvm_analysis_port #(ddr4_rd_evt) ap;

  longint                   cyc;
  bit                       open_b [NUM_BANKS];
  logic [ROW_W-1:0]         row_b  [NUM_BANKS];
  logic [BURST_CODE_W-1:0]  mem    [bit [KEY_W-1:0]];
  longint                   wr_due_q [$];
  bit [KEY_W-1:0]           wr_key_q [$];
  longint                   rd_due_q [$];
  bit [KEY_W-1:0]           rd_key_q [$];
  longint                   ret_due_q [$];
  logic [BURST_CODE_W-1:0]  ret_code_q [$];
  int                       n_wr, n_rd, n_single, n_double;

  function new(string name, uvm_component parent);
    super.new(name, parent);
    ap = new("ap", this);
  endfunction

  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    if (!uvm_config_db#(ddr4_env_cfg)::get(this, "", "cfg", cfg))
      `uvm_fatal("NOCFG", "cfg not set")
    vif  = cfg.dfi_vif;
    pvif = cfg.probe_vif;
  endfunction

  function void clear();
    mem.delete();
    wr_due_q.delete();  wr_key_q.delete();
    rd_due_q.delete();  rd_key_q.delete();
    ret_due_q.delete(); ret_code_q.delete();
    foreach (open_b[i]) begin open_b[i] = 0; row_b[i] = '0; end
    cyc = 0;
  endfunction

  task run_phase(uvm_phase phase);
    fork
      init_complete_loop();
      main_loop();
    join
  endtask

  // dfi_init_complete rises phy_init_delay cycles after each reset release.
  task init_complete_loop();
    forever begin
      vif.init_complete = 1'b0;
      @(posedge vif.cclk iff pvif.crst_n === 1'b1);
      repeat (cfg.phy_init_delay) @(posedge vif.cclk);
      @(negedge vif.cclk);
      vif.init_complete = 1'b1;
      @(negedge pvif.crst_n);
    end
  endtask

  task main_loop();
    forever begin
      @(posedge vif.cclk);
      if (pvif.crst_n !== 1'b1) begin
        clear();
        vif.rddata_valid <= '0;
        continue;
      end
      cyc++;
      do_command();
      do_write_data();
      do_read_enable();
      do_read_return();
    end
  endtask

  function void do_command();
    int pb;
    bit [KEY_W-1:0] key;
    if (vif.cs_n[0] !== 1'b0) return;
    pb = int'({vif.bg[0], vif.ba[0]});
    if (vif.act_n[0] === 1'b0) begin
      open_b[pb] = 1;
      row_b[pb]  = {vif.cas_n[0], vif.we_n[0], vif.address[0]};
      return;
    end
    case ({vif.ras_n[0], vif.cas_n[0], vif.we_n[0]})
      3'b010: begin
        if (vif.address[0][10]) foreach (open_b[i]) open_b[i] = 0;
        else                    open_b[pb] = 0;
      end
      3'b100, 3'b101: begin
        if (!open_b[pb])
          `uvm_error("DFI_RSP", $sformatf("@%0d RD/WR to closed bank %0d", cyc, pb))
        if (vif.address[0][2:0] != 3'b000)
          `uvm_error("DFI_RSP", $sformatf("@%0d burst column not aligned to 8", cyc))
        if (vif.address[0][12] !== 1'b1)
          `uvm_error("DFI_RSP", $sformatf("@%0d BC_n low: burst chop not supported", cyc))
        key = {vif.bg[0], vif.ba[0], row_b[pb], vif.address[0][9:3]};
        if (vif.we_n[0]) begin
          rd_due_q.push_back(cyc + cfg.rden_lat);  rd_key_q.push_back(key);  n_rd++;
        end else begin
          wr_due_q.push_back(cyc + cfg.wr_lat);    wr_key_q.push_back(key);  n_wr++;
        end
      end
      default: ;
    endcase
  endfunction

  function void do_write_data();
    bit [KEY_W-1:0] key;
    logic [BURST_CODE_W-1:0] code;
    if (vif.wrdata_en !== '0) begin
      if (wr_due_q.size() == 0 || wr_due_q[0] != cyc) begin
        `uvm_error("DFI_RSP", $sformatf("@%0d write data in the wrong cycle (due %0d)", cyc,
                                        wr_due_q.size() ? wr_due_q[0] : -1))
        return;
      end
      key  = wr_key_q[0];
      code = mem.exists(key) ? mem[key] : '0;
      for (int w = 0; w < BURST_WORDS; w++) begin
        logic [8:0] m = vif.wrdata_mask[w*9 +: 9];
        if (m != '0 && m != '1)
          `uvm_error("DFI_RSP", $sformatf("@%0d word %0d partially masked (0x%03h)", cyc, w, m))
        if (m == '0) code[w*CODE_W +: CODE_W] = vif.wrdata[w*CODE_W +: CODE_W];
      end
      mem[key] = code;
      void'(wr_due_q.pop_front());  void'(wr_key_q.pop_front());
    end else if (wr_due_q.size() != 0 && wr_due_q[0] <= cyc) begin
      `uvm_error("DFI_RSP", $sformatf("@%0d write data did not arrive (due %0d)", cyc, wr_due_q[0]))
      void'(wr_due_q.pop_front());  void'(wr_key_q.pop_front());
    end
  endfunction

  function void do_read_enable();
    bit [KEY_W-1:0] key;
    logic [BURST_CODE_W-1:0] code;
    ddr4_rd_evt e;
    if (vif.rddata_en !== '0) begin
      if (rd_due_q.size() == 0 || rd_due_q[0] != cyc) begin
        `uvm_error("DFI_RSP", $sformatf("@%0d read enable in the wrong cycle (due %0d)", cyc,
                                        rd_due_q.size() ? rd_due_q[0] : -1))
        return;
      end
      key  = rd_key_q[0];
      code = mem.exists(key) ? mem[key] : '0;     // never written: all-zero is a valid codeword
      e = ddr4_rd_evt::type_id::create("rd_evt");
      e.cyc = cyc;
      inject(code, e);
      ap.write(e);
      ret_due_q.push_back(cyc + cfg.rd_phy_lat);  ret_code_q.push_back(code);
      void'(rd_due_q.pop_front());  void'(rd_key_q.pop_front());
    end else if (rd_due_q.size() != 0 && rd_due_q[0] <= cyc) begin
      `uvm_error("DFI_RSP", $sformatf("@%0d read enable did not arrive (due %0d)", cyc, rd_due_q[0]))
      void'(rd_due_q.pop_front());  void'(rd_key_q.pop_front());
    end
  endfunction

  // A directed injection (if queued) is applied first, then random ones.
  function void inject(ref logic [BURST_CODE_W-1:0] code, input ddr4_rd_evt e);
    bit dir_used [BURST_WORDS];
    foreach (e.bit_a[w]) begin e.bit_a[w] = -1; e.bit_b[w] = -1; end
    if (cfg.directed_inj.size() > 0) begin
      inj_t d = cfg.directed_inj.pop_front();
      flip(code, e, d.word, d.bit_a, d.bit_b);
      dir_used[d.word] = 1;
    end
    for (int w = 0; w < BURST_WORDS; w++) begin
      int roll, a, b;
      if (dir_used[w]) continue;
      roll = $urandom_range(0, 99);
      if (roll < int'(cfg.inj1_pct)) begin
        flip(code, e, w, $urandom_range(0, CODE_W-1), -1);
      end else if (roll < int'(cfg.inj1_pct + cfg.inj2_pct)) begin
        a = $urandom_range(0, CODE_W-1);
        b = (a + $urandom_range(1, CODE_W-1)) % CODE_W;
        flip(code, e, w, a, b);
      end
    end
  endfunction

  function void flip(ref logic [BURST_CODE_W-1:0] code, input ddr4_rd_evt e,
                     input int w, input int a, input int b);
    code[w*CODE_W + a] = ~code[w*CODE_W + a];
    e.bit_a[w] = a;
    if (b >= 0) begin
      code[w*CODE_W + b] = ~code[w*CODE_W + b];
      e.bit_b[w]  = b;
      e.double[w] = 1;
      n_double++;
    end else begin
      e.single[w] = 1;
      n_single++;
    end
  endfunction

  function void do_read_return();
    if (ret_due_q.size() != 0 && ret_due_q[0] == cyc + 1) begin
      vif.rddata_valid <= '1;
      vif.rddata       <= ret_code_q[0];
      void'(ret_due_q.pop_front());  void'(ret_code_q.pop_front());
    end else begin
      vif.rddata_valid <= '0;
    end
  endfunction

  function void report_phase(uvm_phase phase);
    `uvm_info("DFI_RSP", $sformatf("bursts written %0d, read %0d; injected %0d single, %0d double",
                                   n_wr, n_rd, n_single, n_double), UVM_LOW)
  endfunction
endclass

class dfi_agent extends uvm_agent;
  `uvm_component_utils(dfi_agent)
  dfi_monitor   mon;
  dfi_responder rsp;

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    mon = dfi_monitor::type_id::create("mon", this);
    rsp = dfi_responder::type_id::create("rsp", this);
  endfunction
endclass
