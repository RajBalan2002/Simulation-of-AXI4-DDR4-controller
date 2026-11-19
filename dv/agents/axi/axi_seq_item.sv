// -----------------------------------------------------------------------------
// axi_seq_item.sv
// One whole AXI4 burst, read or write. The driver uses the request fields;
// the monitor fills in the response fields from what it saw on the bus.
// Defaults (soft) give legal full-width INCR bursts with full strobes inside
// a small address window, so reads often hit addresses that were written.
// -----------------------------------------------------------------------------
class axi_seq_item extends uvm_sequence_item;
  `uvm_object_utils(axi_seq_item)

  // ---------------- request ----------------
  rand bit                    is_write;
  rand bit [AXI_ID_W-1:0]     id;
  rand bit [AXI_ADDR_W-1:0]   addr;
  rand bit [7:0]              len;        // beats - 1
  rand bit [2:0]              size;
  rand bit [1:0]              burst;
  rand bit [DATA_W-1:0]       data [];
  rand bit [DATA_W/8-1:0]     strb [];
  rand int unsigned           addr_delay; // cycles before AxVALID
  rand int unsigned           beat_delay [];  // idle cycles before each W beat

  // ---------------- response (filled by the monitor) ----------------
  bit [1:0]                   bresp;
  bit [DATA_W-1:0]            rdata [$];
  bit [1:0]                   rresp [$];
  bit [AXI_ID_W-1:0]          resp_id;
  longint                     start_cyc, end_cyc;  // aclk cycles, for latency

  constraint c_size   { soft size  == 3'd3; }
  constraint c_burst  { soft burst == BURST_INCR; burst != 2'b11; }
  constraint c_len    { soft len dist { 0 := 10, [1:6] := 15, 7 := 15, [8:15] := 20,
                                        [16:63] := 20, [64:254] := 15, 255 := 5 }; }
  constraint c_legal  { burst == BURST_WRAP  -> len inside {1, 3, 7, 15};
                        burst == BURST_FIXED -> len <= 15;
                        burst == BURST_INCR  -> int'(addr[11:0]) + (int'(len) + 1) * 8 <= 4096; }
  constraint c_align  { soft addr[2:0] == 3'd0; }
  constraint c_window { soft addr[AXI_ADDR_W-1:17] < 8; }       // rows 0..7
  constraint c_arrays { if (is_write) { data.size() == int'(len) + 1;
                                        strb.size() == int'(len) + 1;
                                        beat_delay.size() == int'(len) + 1; }
                        else          { data.size() == 0; strb.size() == 0;
                                        beat_delay.size() == 0; } }
  constraint c_strb   { foreach (strb[i]) soft strb[i] == 8'hFF; }
  constraint c_delay  { soft addr_delay dist { 0 := 70, [1:3] := 25, [4:12] := 5 };
                        foreach (beat_delay[i])
                          soft beat_delay[i] dist { 0 := 85, [1:2] := 12, [3:6] := 3 }; }
  constraint c_order  { solve is_write before len; solve len before data;
                        solve len before strb; solve len before beat_delay; }

  function new(string name = "axi_seq_item");
    super.new(name);
  endfunction

  function bit supported();
    return (burst == BURST_INCR) && (size == 3'd3);
  endfunction

  function int beats();
    return int'(len) + 1;
  endfunction

  function void do_copy(uvm_object rhs);
    axi_seq_item r;
    if (!$cast(r, rhs)) `uvm_fatal("COPY", "not an axi_seq_item")
    super.do_copy(rhs);
    is_write = r.is_write;  id = r.id;  addr = r.addr;  len = r.len;
    size = r.size;  burst = r.burst;  data = r.data;  strb = r.strb;
    addr_delay = r.addr_delay;  beat_delay = r.beat_delay;
    bresp = r.bresp;  rdata = r.rdata;  rresp = r.rresp;  resp_id = r.resp_id;
    start_cyc = r.start_cyc;  end_cyc = r.end_cyc;
  endfunction

  function string convert2string();
    return $sformatf("%s id=%0d addr=0x%09h len=%0d size=%0d burst=%0d %s",
                     is_write ? "WR" : "RD", id, addr, len, size, burst,
                     is_write ? $sformatf("bresp=%0d", bresp)
                              : $sformatf("beats_seen=%0d", rdata.size()));
  endfunction
endclass
