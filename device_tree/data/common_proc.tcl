#
# common procedures
#

# global variables
global def_string zynq_soc_dt_tree zynq_7000_fname
set def_string "__def_none"
set zynq_soc_dt_tree "dummy.dtsi"
set zynq_7000_fname "zynq-7000.dtsi"

proc get_clock_frequency {ip_handle portname} {
	set clk ""
	set clkhandle [get_pins -of_objects $ip_handle $portname]
	if {[string compare -nocase $clkhandle ""] != 0} {
		set clk [get_property CLK_FREQ $clkhandle ]
	}
	return $clk
}

proc set_drv_conf_prop args {
	set drv_handle [lindex $args 0]
	set pram [lindex $args 1]
	set conf_prop [lindex $args 2]
	set ip [get_cells $drv_handle]
	set value [get_property CONFIG.${pram} $ip]
	if { [llength $value] } {
		regsub -all "MIO( |)" $value "" value
		if { $value != "-1" && [llength $value] !=0  } {
			if {[llength $args] >= 4} {
				set type [lindex $args 3]
				if {[string equal -nocase $type "boolean"]} {
					set_boolean_property $drv_handle $value ${conf_prop}
					return 0
				}
				set_property ${conf_prop} $value $drv_handle
				set prop [get_comp_params ${conf_prop} $drv_handle]
				set_property CONFIG.TYPE $type $prop
				return 0
			}
			set_property ${conf_prop} $value $drv_handle
		}
	}
}

proc set_boolean_property {drv_handle value conf_prop} {
	if {[expr $value >= 1]} {
		set_property ${conf_prop} "" $drv_handle
		set prop [get_comp_params ${conf_prop} $drv_handle]
		set_property CONFIG.TYPE referencelist $prop
	}
}

proc add_cross_property args {
	set src_handle [lindex $args 0]
	set src_prams [lindex $args 1]
	set dest_handle [lindex $args 2]
	set dest_prop [lindex $args 3]
	set ip [get_cells $src_handle]
	foreach conf_prop $src_prams {
		set value [get_property ${conf_prop} $ip]
		if { [llength $value] } {
			if { $value != "-1" && [llength $value] !=0  } {
				set type "hexint"
				if {[llength $args] >= 5} {
					set type [lindex $args 4]
					if {[string equal -nocase $type "boolean"]} {
						set type referencelist
						if {[expr $value >= 1]} {
							hsm::utils::add_new_property $dest_handle $dest_prop $type ""
						}
						return 0
					}
				}
				hsm::utils::add_new_property $dest_handle $dest_prop $type $value
				return 0
			}
		}
	}
}

proc get_ip_property {drv_handle parameter} {
	set ip [get_cells $drv_handle]
	return [get_property ${parameter} $ip]
}

proc is_it_in_pl {ip} {
	# FIXME: This is a workaround to check if IP that's in PL however,
	# this is not entirely correct, it is a hack and only works for
	# IP_NAME that does not matches ps7_*
	# better detection is required

	# handles interrupt that coming from get_drivers only
	if {[llength [get_drivers $ip]] < 1} {
		return -1
	}
	set ip_type [get_property IP_NAME $ip]
	if {![regexp "ps7_*" "$ip_type" match]} {
		return 1
	}
	return -1
}

#
# HSM 2014.2 workaround
# This proc is designed to generated the correct interrupt cells for both
# MB and Zynq
proc get_intr_id { periph_name intr_port_name } {
	set intr_info -1
	set ip [get_cells $periph_name]

	set intr_pin [get_pins -of_objects $ip $intr_port_name -filter "TYPE==INTERRUPT"]
	if { [llength $intr_pin] == 0 } {
		return -1
	}

	# identify the source controller port
	set intc_port ""
	set intc_periph ""
	set intr_sink_pins [xget_sink_pins $intr_pin]
	foreach intr_sink $intr_sink_pins {
		set sink_periph [get_cells -of_objects $intr_sink]
		if { [is_interrupt_controller $sink_periph] == 1} {
			set intc_port $intr_sink
			set intc_periph $sink_periph
			break
		}
	}
	if {$intc_port == ""} {
		return -1
	}

	# workaround for 2014.2
	# get_interrupt_id returns incorrect id for Zynq
	# issue: the xget_interrupt_sources returns all interrupt signals
	# connected to the interrupt controller, which is not limited to IP
	# in PL
	set intc_type [get_property IP_NAME $intc_periph]
	# CHECK with Heera for zynq the intc_src_ports are in reverse order
	if { [string match -nocase $intc_type "ps7_scugic"] } {
		set ip_param [get_property CONFIG.C_IRQ_F2P_MODE $intc_periph]
		if { [string match -nocase "$ip_param" "REVERSE"]} {
			set intc_src_ports [xget_interrupt_sources $intc_periph]
		} else {
			set intc_src_ports [lreverse [xget_interrupt_sources $intc_periph]]
		}
		set total_intr_count -1
		foreach intc_src_port $intc_src_ports {
			set intr_periph [get_cells -of_objects $intc_src_port]
			if { [string match -nocase $intc_type "ps7_scugic"] } {
				if {[is_it_in_pl "$intr_periph"] == 1} {
					incr total_intr_count
					continue
				}
			}
		}
	} else {
		set intc_src_ports [xget_interrupt_sources $intc_periph]
	}

	set i 0
	set intr_id -1
	set ret -1
	foreach intc_src_port $intc_src_ports {
		if { [llength $intc_src_port] == 0 } {
			incr i
			continue
		}
		set intr_periph [get_cells -of_objects $intc_src_port]
		set ip_type [get_property IP_NAME $intr_periph]
		if { [string compare -nocase "$intr_port_name"  "$intc_src_port" ] == 0 } {
			if { [string compare -nocase "$intr_periph" "$ip"] == 0 } {
				set ret $i
				break
			}
		}
		if { [string match -nocase $intc_type "ps7_scugic"] } {
			if {[is_it_in_pl "$intr_periph"] == 1} {
				incr i
				continue
			}
		} else {
			incr i
		}
	}

	if { [string match -nocase $intc_type "ps7_scugic"] && [string match -nocase $intc_port "IRQ_F2P"] } {
		set ip_param [get_property CONFIG.C_IRQ_F2P_MODE $intc_periph]
		if { [string match -nocase "$ip_param" "REVERSE"]} {
			set diff [expr $total_intr_count - $ret]
			if { $diff < 8 } {
				set intr_id [expr 91 - $diff]
			} elseif { $diff  < 16} {
				set intr_id [expr 68 - ${diff} + 8 ]
			}
		} else {
			if { $ret < 8 } {
				set intr_id [expr 61 + $ret]
			} elseif { $ret  < 16} {
				set intr_id [expr 84 + $ret - 8 ]
			}
		}
	} else {
		set intr_id $ret
	}

	if { [string match -nocase $intr_id "-1"] } {
		set intr_id [xget_port_interrupt_id "$periph_name" "$intr_port_name" ]
	}

	if { [string match -nocase $intr_id "-1"] } {
		return -1
	}

	# format the interrupt cells
	set intc [get_connected_interrupt_controller $periph_name $intr_port_name]
	set intr_type [hsm::utils::get_dtg_interrupt_type $intc $ip $intr_port_name]
	if {[string match "[get_property IP_NAME $intc]" "ps7_scugic"]} {
		if { $intr_id > 32 } {
			set intr_id [expr $intr_id - 32]
		}
		set intr_info "0 $intr_id $intr_type"
	} else {
		set intr_info "$intr_id $intr_type"
	}
	return $intr_info
}

proc dtg_debug msg {
	return
	puts "# [lindex [info level -1] 0] #>> $msg"
}

proc dtg_warning msg {
	puts "WARNING: $msg"
}

proc proc_called_by {} {
	return
	puts "# [lindex [info level -1] 0] #>> called by [lindex [info level -2] 0]"
}

proc Pop {varname {nth 0}} {
	upvar $varname args
	set r [lindex $args $nth]
	set args [lreplace $args $nth $nth]
	return $r
}

proc string_is_empty {input} {
	if {[string compare -nocase $input ""] != 0} {
		return 0
	}
	return 1
}

proc gen_dt_node_search_pattern args {
	proc_called_by
	# generates device tree node search pattern and return it

	global def_string
	foreach var {node_name node_label node_unit_addr} {
		set ${var} ${def_string}
	}
	while {[string match -* [lindex $args 0]]} {
		switch -glob -- [lindex $args 0] {
			-n* {set node_name [Pop args 1]}
			-l* {set node_label [Pop args 1]}
			-u* {set node_unit_addr [Pop args 1]}
			-- { Pop args ; break }
			default {
				error "gen_dt_node_search_pattern bad option - [lindex $args 0]"
			}
		}
		Pop args
	}
	set pattern ""
	# TODO: is these search patterns correct
	# TODO: check if pattern in the list or not
	if {![string equal -nocase ${node_label} ${def_string}] && \
		![string equal -nocase ${node_name} ${def_string}] && \
		![string equal -nocase ${node_unit_addr} ${def_string}] } {
		lappend pattern "${node_label}:${node_name}@${node_unit_addr}"
		lappend pattern "${node_name}@${node_unit_addr}"
	}

	if {![string equal -nocase ${node_label} ${def_string}]} {
		lappend pattern "&${node_label}"
		lappend pattern "^${node_label}"
	}
	if {![string equal -nocase ${node_name} ${def_string}] && \
		![string equal -nocase ${node_unit_addr} ${def_string}] } {
		lappend pattern "${node_name}@${node_unit_addr}"
	}
	return $pattern
}

proc set_cur_working_dts {{dts_file ""}} {
	# set current working device tree
	# return the tree object
	proc_called_by
	if {[string_is_empty ${dts_file}] == 1} {
		return [current_dt_tree]
	}
	set dt_idx [lsearch [get_dt_trees] ${dts_file}]
	if { $dt_idx >= 0 } {
		set dt_tree_obj [current_dt_tree [lindex [get_dt_trees] $dt_idx]]
	} else {
		set dt_tree_obj [create_dt_tree -dts_file $dts_file]
	}
	return $dt_tree_obj
}

proc get_baseaddr {slave_ip} {
	# only returns the first addr
	set ip_mem_handle [lindex [hsi::utils::get_ip_mem_ranges [get_cells $slave_ip]] 0]
	return [string tolower [get_property BASE_VALUE $ip_mem_handle]]
}

proc get_highaddr {slave_ip} {
	set ip_mem_handle [lindex [hsi::utils::get_ip_mem_ranges [get_cells $slave_ip]] 0]
	return [get_property HIGH_VALUE $ip_mem_handle]
}

proc get_all_tree_nodes {dts_file} {
	# Workaround for -hier not working with -of_objects
	# get all the nodes presented in a dt_tree and return node list
	proc_called_by
	set cur_dts [current_dt_tree]
	current_dt_tree $dts_file
	set all_nodes [get_dt_nodes -hier]
	current_dt_tree $cur_dts
	return $all_nodes
}

proc check_node_in_dts {node_name dts_file_list} {
	# check if the node is in the device-tree file
	# return 1 if found
	# return 0 if not found
	proc_called_by
	foreach tmp_dts_file ${dts_file_list} {
		set dts_nodes [get_all_tree_nodes $tmp_dts_file]
		# TODO: better detection here
		foreach pattern ${node_name} {
			foreach node ${dts_nodes} {
				if {[regexp $pattern $node match]} {
					dtg_debug "Node $node ($pattern) found in $tmp_dts_file"
					return 1
				}
			}
		}
	}
	return 0
}

proc get_node_object {lu_node {dts_files ""}} {
	# get the node object based on the args
	# returns the dt node object
	proc_called_by
	if [string_is_empty $dts_files] {
		set dts_files [get_dt_trees]
	}
	set cur_dts [current_dt_tree]
	foreach dts_file ${dts_files} {
		set dts_nodes [get_all_tree_nodes $dts_file]
		foreach node ${dts_nodes} {
			if {[regexp $lu_node $node match]} {
				# workaround for -hier not working with -of_objects
				current_dt_tree $dts_file
				set node_obj [get_dt_nodes -hier $node]
				current_dt_tree $cur_dts
				return $node_obj
			}
		}
	}
	error "Failed to find $lu_node node !!!"
}

proc update_dt_parent args {
	# update device tree node's parent
	# return the node name
	proc_called_by
	set node [lindex $args 0]
	set new_parent [lindex $args 1]
	if {[llength $args] >= 3} {
		set dts_file [lindex $args 2]
	} else {
		set dts_file [current_dt_tree]
	}
	set node [get_node_object $node $dts_file]
	# Skip if node is a reference node (start with &) or amba
	if {[regexp "^&.*" "$node" match] || [regexp "amba" "$node" match]} {
		return $node
	}

	# Currently the PARENT node must within the same dt tree
	if {![check_node_in_dts $new_parent $dts_file]} {
		error "Node '$node' is not in $dts_file tree"
	}

	set cur_parent [get_property PARENT $node]
	# set new parent if required
	if {![string equal -nocase ${cur_parent} ${new_parent}] && [string_is_empty ${new_parent}] == 0} {
		dtg_debug "Update parent to $new_parent"
		set_property PARENT "${new_parent}" $node
	}
	return $node
}

proc get_all_dt_labels {{dts_files ""}} {
	# get all dt node labels
	set cur_dts [current_dt_tree]
	set labels ""
	if [string_is_empty $dts_files] {
		set dts_files [get_dt_trees]
	}
	foreach dts_file ${dts_files} {
		set dts_nodes [get_all_tree_nodes $dts_file]
		foreach node ${dts_nodes} {
			set node_label [get_property "NODE_LABEL" $node]
			if {[string_is_empty $node_label]} {
				continue
			}
			lappend labels $node_label
		}
	}
	current_dt_tree $cur_dts
	return $labels
}

proc list_remove_element {cur_list elements} {
	foreach e ${elements} {
		set rm_idx [lsearch $cur_list $e]
		set cur_list [lreplace $cur_list $rm_idx $rm_idx]
	}
	return $cur_list
}

proc update_system_dts_include {include_file} {
	# where should we get master_dts data
	set master_dts [get_property CONFIG.master_dts [get_os]]
	set cur_dts [current_dt_tree]
	set master_dts_obj [get_dt_trees ${master_dts}]

	if {[string_is_empty $master_dts_obj] == 1} {
		set master_dts_obj [set_cur_working_dts ${master_dts}]
	}
	if { [string equal ${include_file} ${master_dts_obj}] } {
		return 0
	}
	set cur_inc_list [get_property INCLUDE_FILES $master_dts_obj]
	set tmp_list [split $cur_inc_list ","]
	if { [lsearch $tmp_list $include_file] < 0} {
		if {[string_is_empty $cur_inc_list]} {
			set cur_inc_list $include_file
		} else {
			append cur_inc_list "," $include_file
		}
		set_property INCLUDE_FILES ${cur_inc_list} $master_dts_obj
	}

	# set dts version
	set dts_ver [get_property DTS_VERSION $master_dts_obj]
	if {[string_is_empty $dts_ver]} {
		set_property DTS_VERSION "/dts-v1/" $master_dts_obj
	}

	set_cur_working_dts $cur_dts
}

proc set_drv_def_dts {drv_handle} {
	# optional dts control by adding the following line in mdd file
	# PARAMETER name = def_dts, default = ps.dtsi, type = string;
	set default_dts [get_property CONFIG.def_dts $drv_handle]
	if {[string_is_empty $default_dts]} {
		if {[is_pl_ip $drv_handle] == 1} {
			set default_dts "pl.dtsi"
		} else {
			# PS IP, read pcw_dts property
			set default_dts [get_property CONFIG.pcw_dts [get_os]]
		}
	}
	set default_dts [set_cur_working_dts $default_dts]
	update_system_dts_include $default_dts
	return $default_dts
}

proc dt_node_def_checking {node_label node_name node_ua node_obj} {
	# check if the node_object has matching label, name and unit_address properties
	# ignore reference node as it does not have label and unit_addr
	if {![regexp "^&.*" "$node_obj" match]} {
		set old_label [get_property "NODE_LABEL" $node_obj]
		set old_name [get_property "NODE_NAME" $node_obj]
		set old_ua [get_property "UNIT_ADDRESS" $node_obj]
		if {![string equal -nocase $node_label $old_label] || \
			![string equal -nocase $node_ua $old_ua] || \
			![string equal -nocase $node_name $old_name] } {
			dtg_debug "dt_node_def_checking($node_obj): label: ${node_label} - ${old_label}, name: ${node_name} - ${old_name}, unit addr: ${node_ua} - ${old_ua}"
			return 0
		}
	}
	return 1
}

proc add_or_get_dt_node args {
	# Creates the dt node or the parent node if required
	# return dt node
	proc_called_by
	global def_string
	foreach var {node_name node_label node_unit_addr parent_obj dts_file} {
		set ${var} ${def_string}
	}
	set auto_ref 1
	set auto_ref_parent 0
	while {[string match -* [lindex $args 0]]} {
		switch -glob -- [lindex $args 0] {
			-disable_auto_ref {set auto_ref 0}
			-auto_ref_parent {set auto_ref_parent 1}
			-n* {set node_name [Pop args 1]}
			-l* {set node_label [Pop args 1]}
			-u* {set node_unit_addr [Pop args 1]}
			-p* {set parent_obj [Pop args 1]}
			-d* {set dts_file [Pop args 1]}
			--    { Pop args ; break }
			default {
				error "add_or_get_dt_node bad option - [lindex $args 0]"
			}
		}
		Pop args
	}

	# if no dts_file provided
	if {[string equal -nocase ${dts_file} ${def_string}]} {
		set dts_file [current_dt_tree]
	}

	# Generate unique label name to prevent issue caused by static dtsi
	# better way of handling this issue is required
	set label_list [get_all_dt_labels]
	# TODO: This only handle label duplication once. if multiple IP has
	# the same label, it will not work. Better handling required.
	if {[lsearch $label_list $node_label] >= 0} {
		set tmp_node [get_node_object ${node_label}]
		# rename if the node default properties differs
		if {[dt_node_def_checking $node_label $node_name $node_unit_addr $tmp_node] == 0} {
			dtg_warning "label found in existing tree, rename to dtg_$node_label"
			set node_label "dtg_${node_label}"
		}
	}

	set search_pattern [gen_dt_node_search_pattern -n ${node_name} -l ${node_label} -u ${node_unit_addr}]

	dtg_debug ""
	dtg_debug "node_name: ${node_name}"
	dtg_debug "node_label: ${node_label}"
	dtg_debug "node_unit_addr: ${node_unit_addr}"
	dtg_debug "search_pattern: ${search_pattern}"
	dtg_debug "parent_obj: ${parent_obj}"
	dtg_debug "dts_file: ${dts_file}"

	# save the current working dt_tree first
	set cur_working_dts [current_dt_tree]
	# tree switch the target tree
	set_cur_working_dts ${dts_file}
	set parent_dts_file ${dts_file}

	# Set correct parent object
	#  Check if the parent object in other dt_trees or not. If yes, update
	#  parent node with reference node (&parent_obj).
	#  Check if parent is / and see if it in the target dts file
	#  if not /, then check if parent is created (FIXME: is right???)
	set tmp_dts_list [list_remove_element [get_dt_trees] ${dts_file}]
	set node_in_dts [check_node_in_dts ${parent_obj} ${tmp_dts_list}]
	if {${node_in_dts} ==  1 && \
		 ![string equal ${parent_obj} "/" ]} {
		set parent_obj [get_node_object ${parent_obj} ${tmp_dts_list}]
		set parent_label [get_property "NODE_LABEL" $parent_obj]
		if {[string_is_empty $parent_label]} {
			set parent_label [get_property "NODE_NAME" $parent_obj]
		}
		if {[string_is_empty $parent_label]} {
			error "no parent node name/label"
		}
		if {[regexp "^&.*" "$parent_label" match]} {
			set ref_node "${parent_label}"
		} else {
			set ref_node "&${parent_label}"
		}
		set parent_ref_in_dts [check_node_in_dts "${ref_node}" ${dts_file}]
		if {${parent_ref_in_dts} != 1} {
			if { $auto_ref_parent } {
				set_cur_working_dts ${dts_file}
				set parent_obj [create_dt_node -n "${ref_node}"]
			}
		}
	}

	# if dt node in the target dts file
	# get the nodes in the current dts file
	set dts_nodes [get_all_tree_nodes $dts_file]
	foreach pattern ${search_pattern} {
		foreach node ${dts_nodes} {
			if {[regexp $pattern $node match]} {
				if {[string equal -nocase ${parent_obj} ${def_string}]} {
					set parent_obj ""
				}
				if {[dt_node_def_checking $node_label $node_name $node_unit_addr $node] == 0} {
					error "$pattern :: $node_label : $node_name @ $node_unit_addr, is differ to the node object $node"
				}
				set node [update_dt_parent ${node} ${parent_obj} ${dts_file}]
				set_cur_working_dts ${cur_working_dts}
				return $node
			}
		}
	}

	# if dt node in other target dts files
	# create a reference node if required
	set found_node 0
	set tmp_dts_list [list_remove_element [get_dt_trees] ${dts_file}]
	foreach tmp_dts_file ${tmp_dts_list} {
		set dts_nodes [get_all_tree_nodes $tmp_dts_file]
		# TODO: better detection here
		foreach pattern ${search_pattern} {
			foreach node ${dts_nodes} {
				if {[regexp $pattern $node match]} {
					# create reference node
					set found_node 1
					set found_node_obj [get_node_object ${node} $tmp_dts_file]
					break
				}
			}
		}
	}
	if { $found_node == 1 } {
		if { $auto_ref == 0 } {
			# return the object found on other dts files
			set_cur_working_dts ${cur_working_dts}
			return $found_node_obj
		}
		dtg_debug "INFO: Found node and create it as reference node &${node_label}"
		if {[string equal -nocase ${node_label} ${def_string}]} {
			error "Unable to create reference node as reference label is not provided"
		}

		set node [create_dt_node -n "&${node_label}"]
		set_cur_working_dts ${cur_working_dts}
		return $node
	}

	# Others - create the dt node
	set cmd ""
	if {![string equal -nocase ${node_name} ${def_string}]} {
		set cmd "${cmd} -name ${node_name}"
	}
	if {![string equal -nocase ${node_label} ${def_string}]} {
		set cmd "${cmd} -label ${node_label}"
	}
	if {![string equal -nocase ${node_unit_addr} ${def_string}]} {
		set cmd "${cmd} -unit_addr ${node_unit_addr}"
	}
	if {![string equal -nocase ${parent_obj} ${def_string}] && \
		![string_is_empty ${parent_obj}]} {
		# temp solution for getting the right node object
		#set cmd "${cmd} -objects \[get_node_object ${parent_obj} $dts_file\]"
		#report_property [get_node_object ${parent_obj} $dts_file]
		set cmd "${cmd} -objects \[get_node_object ${parent_obj} $parent_dts_file\]"
	}

	dtg_debug "create node command: create_dt_node ${cmd}"
	# FIXME: create_dt_node fail detection here
	set node [eval "create_dt_node ${cmd}"]
	set_cur_working_dts ${cur_working_dts}
	return $node
}

proc is_pl_ip {ip_inst} {
	# check if the IP is a soft IP (not PS7)
	# return 1 if it is soft ip
	# return 0 if not
	set ip_obj [get_cells $ip_inst]
	if {[llength [get_cells $ip_inst]] < 1} {
		return 0
	}
	set ip_name [get_property IP_NAME $ip_obj]
	if {![regexp "ps[7]_*" "$ip_name" match]} {
		return 1
	}
	return 0
}

proc is_ps_ip {ip_inst} {
	# check if the IP is a soft IP (not PS7)
	# return 1 if it is soft ip
	# return 0 if not
	set ip_obj [get_cells $ip_inst]
	if {[llength [get_cells $ip_inst]] < 1} {
		return 0
	}
	set ip_name [get_property IP_NAME $ip_obj]
	if {[regexp "ps[7]_*" "$ip_name" match]} {
		return 1
	}
	return 0
}

proc get_node_name {drv_handle} {
	# FIXME: handle node that is not an ip
	# what about it is a bus node
	set ip [get_cells $drv_handle]
	# node that is not a ip
	if {[string_is_empty $ip]} {
		set dt_node [add_or_get_dt_node -n ${drv_handle}]
		return $dt_node
	}
	set unit_addr [get_baseaddr ${ip}]
	set dev_type [get_property CONFIG.dev_type $drv_handle]
	if {[string_is_empty $dev_type] == 1} {
		set dev_type $drv_handle
	}
	set dt_node [add_or_get_dt_node -n ${dev_type} -l ${drv_handle} -u ${unit_addr}]
	return $dt_node
}

proc get_driver_conf_list {drv_handle} {
	# Assuming the driver property starts with CONFIG.<xyz>
	# Returns all the property name that should be add to the node
	set dts_conf_list ""
	# handle no CONFIG parameter
	if { [catch {set rt [report_property -return_string -regexp $drv_handle "CONFIG\\..*"]} msg]} {
		return ""
	}
	foreach line [split $rt "\n"] {
		regsub -all {\s+} $line { } line
		if {[regexp "CONFIG\\..*\\.dts(i|)" $line matched]} {
			continue
		}
		if {[regexp "CONFIG\\..*" $line matched]} {
			lappend dts_conf_list [lindex [split $line " "] 0]
		}
	}
	# Remove config based properties
	# currently it is not possible to different by type: Pending on HSI implementation
	# this is currently hard coded to remove CONFIG.def_dts CONFIG.dev_type CONFIG.dtg.alias CONFIG.dtg.ip_params
	set dts_conf_list [list_remove_element $dts_conf_list "CONFIG.def_dts CONFIG.dev_type CONFIG.dtg.alias CONFIG.dtg.ip_params"]
	return $dts_conf_list
}

proc add_driver_prop {drv_handle dt_node prop} {
	# driver property to DT node
	set value [get_property ${prop} $drv_handle]
	if {[string_is_empty ${prop}] != 0} {
		continue
	}

	regsub -all {CONFIG.} $prop {} prop
	set conf_prop [lindex [get_comp_params ${prop} $drv_handle] 0 ]
	if {[string_is_empty ${conf_prop}] == 0} {
		set type [lindex [get_property CONFIG.TYPE $conf_prop] 0]
	} else {
		error "Unable to add the $prop property for $drv_handle due to missing valid type"
	}
	# CHK: skip if empty? when conf_prop is not referencelist
	# if {[string_is_empty ${value}] == 1} {
	# 	continue
	# }
	# TODO: sanity check is missing
	dtg_debug "${dt_node} - ${prop} - ${value} - ${type}"
	hsm::utils::add_new_dts_param "${dt_node}" "${prop}" "${value}" "${type}"
}

proc create_dt_tree_from_dts_file {} {
	global def_string zynq_7000_fname
	set kernel_dtsi ""
	set kernel_ver [get_property CONFIG.kernel_version [get_os]]
	foreach i [get_sw_cores device_tree] {
		set kernel_dtsi "[get_property "REPOSITORY" $i]/data/kernel_dtsi/${kernel_ver}/${zynq_7000_fname}"
		if {[file exists $kernel_dtsi] } {
			foreach file [glob [get_property "REPOSITORY" $i]/data/kernel_dtsi/${kernel_ver}/*] {
				# NOTE: ./ works only if we did not change our directory
				file copy -force $file ./
			}
			break
		}
	}

	if {![file exists $kernel_dtsi] || [string_is_empty $kernel_dtsi]} {
		error "Unable to find the dts file $kernel_dtsi"
	}

	global zynq_soc_dt_tree
	set default_dts [create_dt_tree -dts_file $zynq_soc_dt_tree]
	set fp [open $kernel_dtsi r]
	set file_data [read $fp]
	set data [split $file_data "\n"]

	set node_level -1
	foreach line $data {
		set node_start_regexp "\{(\\s+|\\s|)$"
		set node_end_regexp "\}(\\s+|\\s|);(\\s+|\\s|)$"
		if {[regexp $node_start_regexp $line matched]} {
			regsub -all "\{| |\t" $line {} line
			incr node_level
			set cur_node [line_to_node $line $node_level $default_dts]
		} elseif {[regexp $node_end_regexp $line matched]} {
			set node_level [expr "$node_level - 1"]
		}
		# TODO (MAYBE): convert every property into dt node
		set status_regexp "status(|\\s+)="
		set value ""
		if {[regexp $status_regexp $line matched]} {
			regsub -all "\{| |\t|;|\"" $line {} line
			set line_data [split $line "="]
			set value [lindex $line_data 1]
			hsm::utils::add_new_dts_param "${cur_node}" "status" $value string
		}
	}
}

proc line_to_node {line node_level default_dts} {
	# TODO: make dt_node_dict as global
	global dt_node_dict
	global def_string
	regsub -all "\{| |\t" $line {} line
	set parent_node $def_string
	set node_label $def_string
	set node_name $def_string
	set node_unit_addr $def_string

	set node_data [split $line ":"]
	set node_data_size [llength $node_data]
	if {$node_data_size == 2} {
		set node_label [lindex $node_data 0]
		set tmp_data [split [lindex $node_data 1] "@"]
		set node_name [lindex $tmp_data 0]
		if {[llength $tmp_data] >= 2} {
			set node_unit_addr [lindex $tmp_data 1]
		}
	} elseif {$node_data_size == 1} {
		set node_name [lindex $node_data 0]
	} else {
		error "invalid node found - $line"
	}

	if { $node_level > 0} {
		set parent_node [dict get $dt_node_dict [expr $node_level - 1] parent_node]
	}

	set cur_node [add_or_get_dt_node -n ${node_name} -l ${node_label} -u ${node_unit_addr} -d ${default_dts} -p ${parent_node}]
	dict set dt_node_dict $node_level parent_node $cur_node
	return $cur_node
}
