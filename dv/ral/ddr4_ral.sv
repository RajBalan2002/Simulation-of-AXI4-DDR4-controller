// -----------------------------------------------------------------------------
// ddr4_ral.sv
// Register model for apb_csr, from docs/register_map.md.
//
// Status, interrupt-status and counter registers are volatile and excluded
// from the bit-bash test. CTRL is excluded too, because toggling init_start
// or sr_req would start initialization or self-refresh.
// -----------------------------------------------------------------------------
class ddr4_reg extends uvm_reg;
  `uvm_object_utils(ddr4_reg)
  function new(string name = "ddr4_reg");
    super.new(name, 32, UVM_NO_COVERAGE);
  endfunction
endclass

class ddr4_reg_block extends uvm_reg_block;
  `uvm_object_utils(ddr4_reg_block)

  ddr4_reg CTRL, STATUS, INT_EN, INT_STAT, ECC_CE, ECC_UE, LATENCY, REFRESH;
  ddr4_reg T_RST, T_CKE, T_XPR, T_DLLK, T_CKESR;
  ddr4_reg MR [7];
  ddr4_reg TIMING [N_TIMING];

  uvm_reg_field sr_req, init_start;
  uvm_reg_field init_done, in_self_refresh, ref_overflow;
  uvm_reg_field wr_lat, rden_lat, refi, ref_thresh;

  function new(string name = "ddr4_reg_block");
    super.new(name, UVM_NO_COVERAGE);
  endfunction

  local function ddr4_reg mk(string name, uvm_reg_addr_t offset);
    ddr4_reg r = ddr4_reg::type_id::create(name);
    r.configure(this, null, "");
    default_map.add_reg(r, offset, "RW");
    return r;
  endfunction

  local function uvm_reg_field fld(ddr4_reg r, string name, int unsigned size,
                                   int unsigned lsb, string access,
                                   uvm_reg_data_t reset, bit volatile = 0);
    uvm_reg_field f = uvm_reg_field::type_id::create(name);
    f.configure(r, size, lsb, access, volatile, reset, 1, 1, 0);
    return f;
  endfunction

  local function void no_bitbash(ddr4_reg r);
    uvm_resource_db#(bit)::set({"REG::", r.get_full_name()}, "NO_REG_BIT_BASH_TEST", 1, this);
  endfunction

  virtual function void build();
    timing_t t = timing_default_1600();
    default_map = create_map("apb_map", 'h0, 4, UVM_LITTLE_ENDIAN, 1);

    CTRL     = mk("CTRL",     REG_CTRL);
    sr_req     = fld(CTRL, "sr_req",     1, 0, "RW", 0);
    init_start = fld(CTRL, "init_start", 1, 1, "RW", 0);       // tb uses AUTO_START = 0

    STATUS   = mk("STATUS",   REG_STATUS);
    init_done       = fld(STATUS, "init_done",       1, 0, "RO", 0, 1);
    in_self_refresh = fld(STATUS, "in_self_refresh", 1, 1, "RO", 0, 1);
    ref_overflow    = fld(STATUS, "ref_overflow",    1, 2, "RO", 0, 1);

    INT_EN   = mk("INT_EN",   REG_INT_EN);
    void'(fld(INT_EN,   "en",   3, 0, "RW",  0));
    INT_STAT = mk("INT_STAT", REG_INT_STAT);
    void'(fld(INT_STAT, "stat", 3, 0, "W1C", 0, 1));
    ECC_CE   = mk("ECC_CE",   REG_ECC_CE);
    void'(fld(ECC_CE,   "count", 32, 0, "WC", 0, 1));
    ECC_UE   = mk("ECC_UE",   REG_ECC_UE);
    void'(fld(ECC_UE,   "count", 32, 0, "WC", 0, 1));

    LATENCY  = mk("LATENCY",  REG_LATENCY);
    wr_lat   = fld(LATENCY, "wr_lat",   3, 0, "RW", 2);
    rden_lat = fld(LATENCY, "rden_lat", 3, 4, "RW", 3);
    REFRESH  = mk("REFRESH",  REG_REFRESH);
    refi       = fld(REFRESH, "interval",  16, 0,  "RW", 1560);
    ref_thresh = fld(REFRESH, "threshold", 4,  16, "RW", 6);

    T_RST   = mk("T_RST",   REG_T_RST);    void'(fld(T_RST,   "cycles", 20, 0, "RW", 40000));
    T_CKE   = mk("T_CKE",   REG_T_CKE);    void'(fld(T_CKE,   "cycles", 20, 0, "RW", 100000));
    T_XPR   = mk("T_XPR",   REG_T_XPR);    void'(fld(T_XPR,   "cycles", 20, 0, "RW", 72));
    T_DLLK  = mk("T_DLLK",  REG_T_DLLK);   void'(fld(T_DLLK,  "cycles", 20, 0, "RW", 150));
    T_CKESR = mk("T_CKESR", REG_T_CKESR);  void'(fld(T_CKESR, "cycles", TCNT_W, 0, "RW", 2));

    foreach (MR[n]) begin
      MR[n] = mk($sformatf("MR%0d", n), REG_MR0 + 4 * n);
      void'(fld(MR[n], "opcode", 14, 0, "RW", MR_DEFAULT[n]));
    end
    foreach (TIMING[k]) begin
      TIMING[k] = mk($sformatf("TIMING%0d_%s", k, timing_name(k)), REG_TIMING0 + 4 * k);
      void'(fld(TIMING[k], "cycles", TCNT_W, 0, "RW", timing_get(t, k)));
    end

    no_bitbash(CTRL);
    no_bitbash(STATUS);
    no_bitbash(INT_STAT);
    no_bitbash(ECC_CE);
    no_bitbash(ECC_UE);
    lock_model();
  endfunction
endclass

// Converts register operations to APB items and back.
class ddr4_reg_adapter extends uvm_reg_adapter;
  `uvm_object_utils(ddr4_reg_adapter)

  function new(string name = "ddr4_reg_adapter");
    super.new(name);
    supports_byte_enable = 0;
    provides_responses   = 0;
  endfunction

  virtual function uvm_sequence_item reg2bus(const ref uvm_reg_bus_op rw);
    apb_seq_item t = apb_seq_item::type_id::create("reg_apb");
    t.write = (rw.kind == UVM_WRITE);
    t.addr  = rw.addr[11:0];
    t.data  = rw.data[31:0];
    return t;
  endfunction

  virtual function void bus2reg(uvm_sequence_item bus_item, ref uvm_reg_bus_op rw);
    apb_seq_item t;
    if (!$cast(t, bus_item)) `uvm_fatal("ADAPT", "not an apb_seq_item")
    rw.kind   = t.write ? UVM_WRITE : UVM_READ;
    rw.addr   = t.addr;
    rw.data   = t.data;
    rw.status = t.slverr ? UVM_NOT_OK : UVM_IS_OK;
  endfunction
endclass
