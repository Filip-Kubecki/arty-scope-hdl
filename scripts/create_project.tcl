# Generuje projekt Vivado w katalogu build/
# Uruchomienie z głównego katalogu repo:
#   vivado -mode batch -source scripts/create_project.tcl

set origin [file normalize [file join [file dirname [info script]] ..]]
set part   xc7a100tcsg324-1

create_project arty_scope $origin/build -part $part -force
set_property target_language VHDL [current_project]

# Źródła RTL, VHDL-2008
set rtl_files [glob -nocomplain $origin/rtl/*.vhd]
if {[llength $rtl_files] > 0} {
    add_files -fileset sources_1 $rtl_files
    foreach f $rtl_files {
        set_property file_type {VHDL 2008} [get_files [file normalize $f]]
    }
}

# Ograniczenia
set xdc_files [glob -nocomplain $origin/constraints/*.xdc]
if {[llength $xdc_files] > 0} {
    add_files -fileset constrs_1 $xdc_files
}

# Testbenche, VHDL-2008
set tb_files [glob -nocomplain $origin/tb/*.vhd]
if {[llength $tb_files] > 0} {
    add_files -fileset sim_1 $tb_files
    foreach f $tb_files {
        set_property file_type {VHDL 2008} [get_files [file normalize $f]]
    }
}

# IP (ILA i FC1002_MII)
set ip_files [glob -nocomplain $origin/ip/*/*.xci]
if {[llength $ip_files] > 0} {
    add_files -fileset sources_1 $ip_files
}

set edn_files [glob -nocomplain $origin/ip/*/*.edn]
if {[llength $edn_files] > 0} {
    add_files -fileset sources_1 $edn_files
}

set_property top top [get_filesets sources_1]
update_compile_order -fileset sources_1
update_compile_order -fileset sim_1
