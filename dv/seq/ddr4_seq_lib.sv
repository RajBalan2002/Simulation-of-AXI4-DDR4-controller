// -----------------------------------------------------------------------------
// ddr4_seq_lib.sv
// AXI traffic sequences. Knobs are plain fields set before start().
// -----------------------------------------------------------------------------

// Random bursts. Defaults: legal full-strobe INCR bursts, 50% writes,
// rows 0..7 so reads often hit written data and pages are reused.
class axi_rand_seq extends uvm_sequence #(axi_seq_item);
  `uvm_object_utils(axi_rand_seq)

  int unsigned n          = 100;
  int unsigned wr_pct     = 50;
  int unsigned strobe_mode = 0;     // 0 all 0xFF, 1 some 0x00, 2 some partial
  int unsigned unsup_pct  = 0;      // % of bursts that are FIXED, WRAP or narrow
  int unsigned max_row    = 7;
  int unsigned max_len    = 255;
  int          only_bank  = -1;     // -1: any bank, else bank 0..15
  int unsigned idle_pct   = 0;      // % chance of an idle gap after a burst
  int unsigned idle_max   = 200;    // aclk cycles

  function new(string name = "axi_rand_seq");
    super.new(name);
  endfunction

  task body();
    ddr4_env_cfg c;
    if (!uvm_config_db#(ddr4_env_cfg)::get(m_sequencer, "", "cfg", c))
      `uvm_fatal("NOCFG", "cfg not visible to the sequencer")
    for (int i = 0; i < n; i++) begin
      axi_seq_item t = axi_seq_item::type_id::create($sformatf("t%0d", i));
      bit wr    = ($urandom_range(1, 100) <= wr_pct);
      bit unsup = ($urandom_range(1, 100) <= unsup_pct);
      int unsigned unsup_kind = $urandom_range(0, 2);   // 0 FIXED, 1 WRAP, 2 narrow INCR
      start_item(t);
      // The item's soft defaults (full strobes, INCR, size 3) must not be left
      // to fight these knobs: a dist only weights values, so with c_strb on,
      // "strb dist {FF, 00}" always solved to FF; and "!(INCR && size 3)" was
      // always met by dropping only the soft size, so FIXED/WRAP never appeared.
      // Coverage (cg_axi_wr cp_strb / cp_burst at 0 hits) exposed both.
      t.c_strb.constraint_mode(strobe_mode == 0);
      if (!t.randomize() with {
            is_write == wr;
            len <= max_len;
            addr[AXI_ADDR_W-1:17] <= max_row;
            if (only_bank >= 0) addr[16:13] == only_bank[3:0];
            if (unsup) {
              if (unsup_kind == 0) burst == BURST_FIXED;
              if (unsup_kind == 1) burst == BURST_WRAP;
              if (unsup_kind == 2) { burst == BURST_INCR; size < 3'd3; }
            }
            if (strobe_mode == 1) { foreach (strb[k]) strb[k] dist { 8'hFF := 85, 8'h00 := 15 }; }
            if (strobe_mode == 2) { foreach (strb[k]) strb[k] dist { 8'hFF := 80, 8'h00 := 8, [8'h01:8'hFE] := 12 }; }
          })
        `uvm_fatal("RAND", "axi_seq_item randomization failed")
      finish_item(t);
      if (idle_pct && $urandom_range(1, 100) <= idle_pct)
        repeat ($urandom_range(1, idle_max)) @(posedge c.axi_vif.aclk);
    end
  endtask
endclass

// One write of a given burst, then a read of the same burst.
class axi_wr_rd_seq extends uvm_sequence #(axi_seq_item);
  `uvm_object_utils(axi_wr_rd_seq)
  bit [AXI_ADDR_W-1:0] addr = 'h1000;
  bit [7:0]            len  = 7;

  function new(string name = "axi_wr_rd_seq");
    super.new(name);
  endfunction

  task body();
    axi_seq_item w = axi_seq_item::type_id::create("w");
    axi_seq_item r = axi_seq_item::type_id::create("r");
    start_item(w);
    if (!w.randomize() with { is_write == 1; addr == local::addr; len == local::len;
                              burst == BURST_INCR; size == 3; foreach (strb[k]) strb[k] == 8'hFF; })
      `uvm_fatal("RAND", "randomization failed")
    finish_item(w);
    start_item(r);
    if (!r.randomize() with { is_write == 0; addr == local::addr; len == local::len;
                              burst == BURST_INCR; size == 3; })
      `uvm_fatal("RAND", "randomization failed")
    finish_item(r);
  endtask
endclass

// Address patterns that force row hits, row misses and empty banks.
class axi_page_seq extends uvm_sequence #(axi_seq_item);
  `uvm_object_utils(axi_page_seq)
  int unsigned n = 200;

  function new(string name = "axi_page_seq");
    super.new(name);
  endfunction

  task body();
    for (int i = 0; i < n; i++) begin
      axi_seq_item t = axi_seq_item::type_id::create($sformatf("p%0d", i));
      int unsigned mode = $urandom_range(0, 3);
      int unsigned bank = $urandom_range(0, 15);
      bit [15:0]   row;
      case (mode)
        0: row = 16'h0010;                       // same row every time: hits
        1: row = 16'h0010 + (i % 2);             // alternate two rows: misses
        2: row = $urandom_range(0, 1023);        // scattered rows
        default: row = 16'h0400 + i;             // a new row each time
      endcase
      start_item(t);
      if (!t.randomize() with { addr[32:17] == row; addr[16:13] == bank[3:0];
                                len inside {[0:15]}; })
        `uvm_fatal("RAND", "randomization failed")
      finish_item(t);
    end
  endtask
endclass
