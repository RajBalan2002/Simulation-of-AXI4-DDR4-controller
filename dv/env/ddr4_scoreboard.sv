// -----------------------------------------------------------------------------
// ddr4_scoreboard.sv
// End-to-end data and response checking.
//
// Inputs
//   axi   whole AXI bursts from the AXI monitor (writes at B, reads at RLAST)
//   req   every push into the request FIFO, with its write data (probe)
//   rdevt every read burst the DFI responder returned, with injected errors
//
// Model
//   The controller serialises all reads and writes in the order they enter
//   the request FIFO, so that order is the order in which writes take effect
//   and reads sample memory. Each AXI burst is first expanded into the chunks
//   the front end must push (one per 8-word memory burst). Every probed push
//   is matched in order against the next expected chunk: address, word mask,
//   and for writes the data, are compared. Writes then update the reference
//   memory; reads snapshot it into the expected beats of their AXI burst.
//   Nothing is assumed about when each input arrives: events wait in queues
//   until everything needed to judge them is there.
//
// Checks: BRESP, RRESP, RDATA, beat count; front-end chunking and masks;
//         predicted ECC counters and interrupt status for the test to compare.
// -----------------------------------------------------------------------------
`uvm_analysis_imp_decl(_axi)
`uvm_analysis_imp_decl(_req)
`uvm_analysis_imp_decl(_rdevt)

class ddr4_scoreboard extends uvm_scoreboard;
  `uvm_component_utils(ddr4_scoreboard)

  uvm_analysis_imp_axi   #(axi_seq_item,  ddr4_scoreboard) axi_imp;
  uvm_analysis_imp_req   #(ddr4_req_item, ddr4_scoreboard) req_imp;
  uvm_analysis_imp_rdevt #(ddr4_rd_evt,   ddr4_scoreboard) rdevt_imp;
  uvm_analysis_port      #(ddr4_ecc_obs)                   ecc_ap;

  ddr4_env_cfg          cfg;
  virtual ddr4_probe_if pvif;

  // expected write chunk / read chunk
  typedef struct {
    logic [26:0]            chunk;
    logic [BURST_WORDS-1:0] mask;
    logic [DATA_W-1:0]      data [BURST_WORDS];
    int                     rd_ctx;     // reads: index into rd_ctx_q
    bit                     err;        // reads: unsupported burst, SLVERR
  } chunk_t;

  // expected beat of a read burst
  typedef struct {
    bit                check_data;
    logic [DATA_W-1:0] data;
    logic [1:0]        resp;
  } beat_t;

  // a read burst waiting for its chunks to be judged
  typedef struct {
    axi_seq_item it;
    int          chunks_left;
    beat_t       beats [$];
  } rd_ctx_t;

  logic [DATA_W-1:0] mem [bit [29:0]];   // reference memory, by 64-bit word address

  ddr4_req_item req_q   [$];
  chunk_t       exp_wr_q [$];
  chunk_t       exp_rd_q [$];
  ddr4_rd_evt   rdevt_q [$];
  rd_ctx_t      rd_ctx_q [$];
  int           rd_ctx_base;              // index of rd_ctx_q[0]

  // predictions the test compares with the registers
  logic [31:0]  exp_ce, exp_ue;
  bit [2:0]     exp_int_stat;

  // statistics
  int n_wr, n_rd, n_wr_chunks, n_rd_chunks, n_beats, n_slverr_wr, n_slverr_rd;
  int n_ce_words, n_ue_words;

  function new(string name, uvm_component parent);
    super.new(name, parent);
    axi_imp   = new("axi_imp", this);
    req_imp   = new("req_imp", this);
    rdevt_imp = new("rdevt_imp", this);
    ecc_ap    = new("ecc_ap", this);
  endfunction

  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    if (!uvm_config_db#(ddr4_env_cfg)::get(this, "", "cfg", cfg))
      `uvm_fatal("NOCFG", "cfg not set")
    pvif = cfg.probe_vif;
  endfunction

  // Reset: the DRAM is re-initialised, so memory contents are not kept.
  task run_phase(uvm_phase phase);
    forever begin
      @(negedge pvif.arst_n);
      clear();
    end
  endtask

  function void clear();
    mem.delete();
    req_q.delete();  exp_wr_q.delete();  exp_rd_q.delete();
    rdevt_q.delete();  rd_ctx_q.delete();  rd_ctx_base = 0;
  endfunction

  // Counters are cleared by register writes in some tests.
  function void clear_counts();
    exp_ce = 0;  exp_ue = 0;
  endfunction

  function bit idle();
    return (req_q.size() == 0) && (exp_wr_q.size() == 0) && (exp_rd_q.size() == 0) &&
           (rdevt_q.size() == 0) && (rd_ctx_q.size() == 0);
  endfunction

  // ------------------------------------------------------------------ inputs
  function void write_axi(axi_seq_item t);
    if (t.is_write) expect_write(t);
    else            expect_read(t);
    match_in_order();
  endfunction

  function void write_req(ddr4_req_item t);
    req_q.push_back(t);
    match_in_order();
  endfunction

  function void write_rdevt(ddr4_rd_evt e);
    rdevt_q.push_back(e);
    match_in_order();
  endfunction

  // ------------------------------------------------- AXI burst -> chunks
  // Mirrors the front end: a chunk ends at word 7 or at the last beat; only
  // beats with WSTRB = 0xFF are stored; a chunk with nothing to store is not pushed.
  function void expect_write(axi_seq_item t);
    logic [29:0] waddr = t.addr[AXI_ADDR_W-1:3];
    bit          partial = 0;
    chunk_t      c;
    logic [1:0]  exp_resp;

    n_wr++;
    foreach (t.strb[i]) if (t.strb[i] != 8'hFF && t.strb[i] != 8'h00) partial = 1;
    exp_resp = (!t.supported() || partial) ? RESP_SLVERR : RESP_OKAY;
    if (t.bresp !== exp_resp)
      `uvm_error("SB", $sformatf("BRESP %0d, expected %0d: %s", t.bresp, exp_resp, t.convert2string()))
    if (exp_resp == RESP_SLVERR) n_slverr_wr++;
    if (!t.supported()) return;

    c.mask = '0;
    for (int i = 0; i < t.beats(); i++) begin
      c.chunk = waddr[29:3];
      if (t.strb[i] == 8'hFF) begin
        c.mask[waddr[2:0]] = 1'b1;
        c.data[waddr[2:0]] = t.data[i];
      end
      if (waddr[2:0] == 3'd7 || i == t.beats() - 1) begin
        if (c.mask != '0) begin
          exp_wr_q.push_back(c);
          n_wr_chunks++;
        end
        c.mask = '0;
      end
      waddr++;
    end
  endfunction

  function void expect_read(axi_seq_item t);
    logic [29:0] waddr = t.addr[AXI_ADDR_W-1:3];
    int          left  = t.beats();
    rd_ctx_t     ctx;
    chunk_t      c;

    n_rd++;
    if (t.rdata.size() != t.beats())
      `uvm_error("SB", $sformatf("read returned %0d beats, expected %0d", t.rdata.size(), t.beats()))
    ctx.it = t;
    ctx.chunks_left = 0;
    while (left > 0) begin
      int room = 8 - int'(waddr[2:0]);
      int n    = (left < room) ? left : room;
      c.chunk  = waddr[29:3];
      c.mask   = '0;
      for (int w = int'(waddr[2:0]); w < int'(waddr[2:0]) + n; w++) c.mask[w] = 1'b1;
      c.rd_ctx = rd_ctx_base + rd_ctx_q.size();
      c.err    = !t.supported();
      exp_rd_q.push_back(c);
      ctx.chunks_left++;
      waddr += n;
      left  -= n;
    end
    rd_ctx_q.push_back(ctx);
  endfunction

  // -------------------------------------------------- in-order matching
  function void match_in_order();
    forever begin
      ddr4_req_item p;
      chunk_t       c;
      if (req_q.size() == 0) break;
      p = req_q[0];
      if (p.req.wr) begin
        if (exp_wr_q.size() == 0) break;
        c = exp_wr_q.pop_front();
        void'(req_q.pop_front());
        judge_write(p, c);
      end else begin
        if (exp_rd_q.size() == 0 || rdevt_q.size() == 0) break;
        c = exp_rd_q.pop_front();
        void'(req_q.pop_front());
        judge_read(p, c, rdevt_q.pop_front());
      end
    end
    finish_reads();
  endfunction

  function void judge_write(ddr4_req_item p, chunk_t c);
    if (p.chunk() !== c.chunk || p.req.word_mask !== c.mask)
      `uvm_error("SB", $sformatf("write request chunk 0x%07h mask %08b, expected chunk 0x%07h mask %08b",
                                 p.chunk(), p.req.word_mask, c.chunk, c.mask))
    for (int w = 0; w < BURST_WORDS; w++) begin
      if (!c.mask[w]) continue;
      if (p.wd[w*DATA_W +: DATA_W] !== c.data[w])
        `uvm_error("SB", $sformatf("write data word %0d of chunk 0x%07h: FIFO 0x%016h, AXI 0x%016h",
                                   w, c.chunk, p.wd[w*DATA_W +: DATA_W], c.data[w]))
      mem[{c.chunk, 3'(w)}] = c.data[w];
    end
  endfunction

  function void judge_read(ddr4_req_item p, chunk_t c, ddr4_rd_evt e);
    int ci = c.rd_ctx - rd_ctx_base;
    int ce = 0, ue = 0;
    if (p.chunk() !== c.chunk || p.req.word_mask !== c.mask)
      `uvm_error("SB", $sformatf("read request chunk 0x%07h mask %08b, expected chunk 0x%07h mask %08b",
                                 p.chunk(), p.req.word_mask, c.chunk, c.mask))
    for (int w = 0; w < BURST_WORDS; w++) begin
      ddr4_ecc_obs o = ddr4_ecc_obs::type_id::create("ecc");
      o.word = w;  o.in_mask = c.mask[w];
      o.kind = e.double[w] ? 2 : e.single[w] ? 1 : 0;
      o.bit_a = e.bit_a[w];  o.bit_b = e.bit_b[w];
      ecc_ap.write(o);
      if (!c.mask[w]) continue;
      if (e.single[w]) ce++;
      if (e.double[w]) ue++;
      begin
        beat_t b;
        logic [29:0] wa = {c.chunk, 3'(w)};
        b.check_data = !e.double[w];
        b.data       = mem.exists(wa) ? mem[wa] : '0;
        b.resp       = (c.err || e.double[w]) ? RESP_SLVERR : RESP_OKAY;
        rd_ctx_q[ci].beats.push_back(b);
      end
    end
    rd_ctx_q[ci].chunks_left--;
    exp_ce = sat_add32(exp_ce, ce);
    exp_ue = sat_add32(exp_ue, ue);
    if (ce) exp_int_stat[0] = 1;
    if (ue) exp_int_stat[1] = 1;
    n_ce_words += ce;
    n_ue_words += ue;
    n_rd_chunks++;
  endfunction

  // Compare every read burst whose chunks have all been judged, in order.
  function void finish_reads();
    while (rd_ctx_q.size() != 0 && rd_ctx_q[0].chunks_left == 0) begin
      rd_ctx_t     x = rd_ctx_q.pop_front();
      axi_seq_item t = x.it;
      rd_ctx_base++;
      if (x.beats.size() != t.rdata.size()) begin
        `uvm_error("SB", $sformatf("read: %0d beats returned, %0d expected: %s",
                                   t.rdata.size(), x.beats.size(), t.convert2string()))
        continue;
      end
      foreach (x.beats[i]) begin
        n_beats++;
        if (t.rresp[i] !== x.beats[i].resp)
          `uvm_error("SB", $sformatf("RRESP %0d on beat %0d, expected %0d: %s",
                                     t.rresp[i], i, x.beats[i].resp, t.convert2string()))
        if (t.rresp[i] == RESP_SLVERR) n_slverr_rd++;
        if (x.beats[i].check_data && t.rdata[i] !== x.beats[i].data)
          `uvm_error("SB", $sformatf("RDATA beat %0d = 0x%016h, expected 0x%016h: %s",
                                     i, t.rdata[i], x.beats[i].data, t.convert2string()))
      end
    end
  endfunction

  // ------------------------------------------------------------------ end
  function void check_phase(uvm_phase phase);
    if (req_q.size())    `uvm_error("SB", $sformatf("%0d request pushes never matched to an AXI burst", req_q.size()))
    if (exp_wr_q.size()) `uvm_error("SB", $sformatf("%0d expected write chunks never pushed", exp_wr_q.size()))
    if (exp_rd_q.size()) `uvm_error("SB", $sformatf("%0d expected read chunks never pushed", exp_rd_q.size()))
    if (rdevt_q.size())  `uvm_error("SB", $sformatf("%0d DFI read bursts with no request", rdevt_q.size()))
    if (rd_ctx_q.size()) `uvm_error("SB", $sformatf("%0d read bursts never completed", rd_ctx_q.size()))
  endfunction

  function void report_phase(uvm_phase phase);
    `uvm_info("SB", $sformatf("bursts: %0d writes (%0d chunks, %0d SLVERR), %0d reads (%0d chunks, %0d beats, %0d SLVERR beats); ECC words: %0d corrected, %0d uncorrectable",
                              n_wr, n_wr_chunks, n_slverr_wr, n_rd, n_rd_chunks, n_beats,
                              n_slverr_rd, n_ce_words, n_ue_words), UVM_LOW)
  endfunction
endclass

// Publishes every push into the request FIFO (white-box probe).
class ddr4_probe_monitor extends uvm_monitor;
  `uvm_component_utils(ddr4_probe_monitor)
  virtual ddr4_probe_if pvif;
  ddr4_env_cfg          cfg;
  uvm_analysis_port #(ddr4_req_item) ap;

  function new(string name, uvm_component parent);
    super.new(name, parent);
    ap = new("ap", this);
  endfunction

  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    if (!uvm_config_db#(ddr4_env_cfg)::get(this, "", "cfg", cfg))
      `uvm_fatal("NOCFG", "cfg not set")
    pvif = cfg.probe_vif;
  endfunction

  task run_phase(uvm_phase phase);
    ddr4_req_item t;
    forever begin
      @(posedge pvif.aclk);
      if (pvif.arst_n === 1'b1 && pvif.req_push === 1'b1) begin
        t = ddr4_req_item::type_id::create("req");
        t.req = pvif.req;
        t.wd  = pvif.wd;
        ap.write(t);
      end
    end
  endtask
endclass
