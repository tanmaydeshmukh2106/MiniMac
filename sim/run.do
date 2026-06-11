# =============================================================================
# run.do — ModelSim compile + simulate script for MiniMAC
# Run from ModelSim transcript:  do run.do
# Or from Windows cmd:  vsim -do run.do
# =============================================================================

# Kill any existing simulation before starting fresh
quit -sim

# Create and map work library
vlib work
vmap work work

# Compile RTL (order matters — dependencies first)
vlog -sv -work work ../rtl/pe.sv
vlog -sv -work work ../rtl/sys_array.sv
vlog -sv -work work ../rtl/controller.sv
vlog -sv -work work ../rtl/minimac_top.sv

# Compile testbench
vlog -sv -work work tb_simple.sv

# Start simulation
vsim -t 1ns work.tb_simple

# Add all signals to waveform viewer
add wave -recursive *

# Run to completion
run -all
