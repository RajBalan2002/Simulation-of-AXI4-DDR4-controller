# -----------------------------------------------------------------------------
# run.do - compile and run one UVM test from inside Questa (no Python needed)
#
# In the Questa transcript, first cd to the project root (the folder with rtl/ and dv/):
#   cd E:/Projects/AXI4_DDR/ddr4_ctrl
#   do dv/scripts/run.do sanity_test
#   do dv/scripts/run.do axi_rand_test 7 fast
#   do dv/scripts/run.do axi_rand_test 1 slow +NBURSTS=20
#
# Or from PowerShell, without opening the GUI:
#   vsim -c -do "do dv/scripts/run.do sanity_test 1 slow; quit -f"
#
# Arguments: test seed clk [one extra plusarg]. Waves are logged when run in the GUI.
# -----------------------------------------------------------------------------
set test  [expr {$argc >= 1 ? "$1" : "sanity_test"}]
set seed  [expr {$argc >= 2 ? "$2" : "1"}]
set clk   [expr {$argc >= 3 ? "$3" : "slow"}]
set extra [expr {$argc >= 4 ? "$4" : ""}]

set root [pwd]
if {![file exists "$root/rtl/files.f"]} {
  echo "run.do: run this from the project root (the folder with rtl/ and dv/)"
  return
}

proc read_list {root name} {
  set out {}
  set f [open "$root/$name" r]
  while {[gets $f line] >= 0} {
    set line [string trim $line]
    if {$line ne "" && ![string match "//*" $line]} { lappend out "$root/$line" }
  }
  close $f
  return $out
}

# UVM source for uvm_macros.svh
if {[info exists env(UVM_HOME)]} {
  set uvm $env(UVM_HOME)
} else {
  set uvm [file normalize "$env(MODEL_TECH)/../verilog_src/uvm-1.1d"]  ;# must match mtiUvm (1.1d in Questa 10.7c)
}

file mkdir "$root/sim"
quit -sim
if {[file exists "$root/sim/work"]} { vdel -lib "$root/sim/work" -all }
vlib "$root/sim/work"
vmap work "$root/sim/work"

set rtl [read_list $root rtl/files.f]
set dv  [read_list $root dv/dv_files.f]
set inc {}
foreach d [read_list $root dv/dv_incdirs.f] { lappend inc "+incdir+$d" }

eval vlog -sv -timescale 1ns/1ps $rtl
eval vlog -sv -timescale 1ns/1ps -L mtiUvm "+incdir+$uvm/src" $inc $dv

set rundir "$root/sim/${test}_${seed}_${clk}"
file mkdir $rundir
cd $rundir
if {[batch_mode]} {
  eval vsim -lib "$root/sim/work" -L mtiUvm tb_top +UVM_TESTNAME=$test +CLK_SET=$clk -sv_seed $seed -l run.log $extra
} else {
  eval vsim -lib "$root/sim/work" -L mtiUvm -voptargs=+acc tb_top +UVM_TESTNAME=$test +CLK_SET=$clk -sv_seed $seed -l run.log $extra
  log -r /*
}
run -all
cd $root
echo "log: $rundir/run.log"
