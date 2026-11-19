// -----------------------------------------------------------------------------
// ddr4_sva_bind.sv
// Binds the assertion modules into the DUT. Port names are resolved in the
// scope of the module bound to, so internal signals can be connected.
// -----------------------------------------------------------------------------
bind ddr4_ctrl_top ddr4_axi_sva #(.ID_W(ID_W)) u_axi_sva (.*);

bind ddr4_ctrl_top ddr4_apb_sva u_apb_sva (
  .aclk(aclk), .aresetn(aresetn), .psel(psel), .penable(penable), .pwrite(pwrite),
  .prdata(prdata), .pready(pready), .pslverr(pslverr), .irq(irq));

bind ddr4_ctrl_top ddr4_dfi_sva u_dfi_sva (
  .cclk(cclk), .crst_n(crst_sync_n),
  .dfi_reset_n(dfi_reset_n), .dfi_cke(dfi_cke), .dfi_odt(dfi_odt), .dfi_cs_n(dfi_cs_n),
  .dfi_wrdata_en(dfi_wrdata_en), .dfi_rddata_en(dfi_rddata_en),
  .dfi_act_n(dfi_act_n), .dfi_ras_n(dfi_ras_n), .dfi_cas_n(dfi_cas_n), .dfi_we_n(dfi_we_n));

bind ddr4_ctrl_top ddr4_internal_sva u_int_sva (
  .aclk(aclk), .arst_n(arst_n), .cclk(cclk), .crst_n(crst_sync_n),
  .req_push(req_push), .req_full(req_full), .wd_push(wd_push), .wd_full(wd_full),
  .rd_pop(rd_pop), .rd_empty(rd_empty),
  .req_pop(req_pop), .req_empty(req_empty), .wd_pop(wd_pop), .wd_empty(wd_empty),
  .rd_push(rd_push), .rd_full(rd_full));

bind apb_csr ddr4_csr_sva u_csr_sva (
  .pclk(pclk), .presetn(presetn), .int_stat(int_stat), .int_en(int_en), .irq_o(irq_o));
