// -----------------------------------------------------------------------------
// ddr4_apb_if.sv
// APB bus between the UVM APB agent and ddr4_ctrl_top's register port.
//
// write() and read() perform one complete APB transfer (setup + access phase,
// waiting for PREADY). They are used directly by the base test until the APB
// agent exists (build step 4); the agent's driver then calls the same tasks.
// Signals change on the falling edge of pclk; PREADY/PRDATA are sampled on the
// rising edge.
// -----------------------------------------------------------------------------
interface ddr4_apb_if (
  input logic pclk,
  input logic presetn
);
  logic        psel    = 1'b0;
  logic        penable = 1'b0;
  logic        pwrite  = 1'b0;
  logic [11:0] paddr   = '0;
  logic [31:0] pwdata  = '0;
  logic [31:0] prdata;
  logic        pready;
  logic        pslverr;
  logic        irq;

  task automatic xfer(input  bit          wr,
                      input  logic [11:0] addr,
                      input  logic [31:0] wdat,
                      output logic [31:0] rdat,
                      output bit          err);
    @(negedge pclk);
    psel = 1'b1;  penable = 1'b0;  pwrite = wr;  paddr = addr;  pwdata = wdat;
    @(negedge pclk);
    penable = 1'b1;
    do @(posedge pclk); while (pready !== 1'b1);
    rdat = prdata;
    err  = pslverr;
    @(negedge pclk);
    psel = 1'b0;  penable = 1'b0;  pwrite = 1'b0;
  endtask

  task automatic write(input logic [11:0] addr, input logic [31:0] data,
                       output bit err);
    logic [31:0] unused;
    xfer(1'b1, addr, data, unused, err);
  endtask

  task automatic read(input logic [11:0] addr, output logic [31:0] data,
                      output bit err);
    xfer(1'b0, addr, '0, data, err);
  endtask
endinterface
