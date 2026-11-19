// -----------------------------------------------------------------------------
// ddr4_dfi_if.sv
// DFI bus between ddr4_ctrl_top and the DFI responder agent (PHY + DRAM model).
// Named ddr4_dfi_if because rtl/dfi_if.sv is already a module called dfi_if.
//
// The controller drives commands; the responder drives dfi_init_complete and
// the read-data return path. Until the responder exists (build step 2) the
// inputs stay at their idle values below.
// -----------------------------------------------------------------------------
interface ddr4_dfi_if
  import ddr4_pkg::*;
(
  input logic cclk,
  input logic crst_n
);
  // controller -> PHY
  logic [DFI_PHASES-1:0]           reset_n;
  logic [DFI_PHASES-1:0]           cke;
  logic [DFI_PHASES-1:0]           odt;
  logic [DFI_PHASES-1:0]           cs_n;
  logic [DFI_PHASES-1:0]           act_n;
  logic [DFI_PHASES-1:0]           ras_n;
  logic [DFI_PHASES-1:0]           cas_n;
  logic [DFI_PHASES-1:0]           we_n;
  logic [DFI_PHASES-1:0][BG_W-1:0] bg;
  logic [DFI_PHASES-1:0][BA_W-1:0] ba;
  logic [DFI_PHASES-1:0][13:0]     address;
  logic [DFI_PHASES-1:0]           wrdata_en;
  logic [BURST_CODE_W-1:0]         wrdata;
  logic [BURST_WORDS*9-1:0]        wrdata_mask;
  logic [DFI_PHASES-1:0]           rddata_en;
  // PHY -> controller
  logic                            init_complete = 1'b0;
  logic [BURST_CODE_W-1:0]         rddata        = '0;
  logic [DFI_PHASES-1:0]           rddata_valid  = '0;
endinterface
