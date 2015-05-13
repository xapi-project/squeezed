(*
 * Copyright (C) Citrix Systems Inc.
 *
 * This program is free software; you can redistribute it and/or modify
 * it under the terms of the GNU Lesser General Public License as published
 * by the Free Software Foundation; version 2.1 only. with the special
 * exception on linking described in file LICENSE.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU Lesser General Public License for more details.
 *)
(**
 * @group Memory
 *)
open Xcp_service
open Memory_interface
open Squeezed_state
open Squeezed_xenstore
open Threadext
open Pervasiveext
open Stringext

module D = Debug.Make(struct let name = Memory_interface.service_name end)
open D

type context = unit

(** The main body of squeezed is single-threaded, so we protect it with a mutex here. *)
let big_server_mutex = Mutex.create ()

let wrap dbg f =
	try
(*
		Debug.with_thread_associated dbg
		(fun () ->
*)
			Mutex.execute big_server_mutex f
(*
		) ()
*)
	with
	| Squeeze.Cannot_free_this_much_memory (needed, free) ->
		(* NB both needed and free have been inflated by the lowmem_emergency_pool etc *)
		let needed = Int64.sub needed Squeeze_xen.target_host_free_mem_kib
		and free = Int64.sub free Squeeze_xen.target_host_free_mem_kib in
		raise (Memory_interface.Cannot_free_this_much_memory (needed, free))
	| Squeeze.Domains_refused_to_cooperate domids ->
		raise (Memory_interface.Domains_refused_to_cooperate(domids))


let start_balance_thread balance_check_interval =
	let body () =
		Xenctrl.with_intf
			(fun xc ->
				while true do
					Thread.delay !balance_check_interval;
					wrap "auto-balance"
					(fun () ->
						if Squeeze_xen.is_host_memory_unbalanced ~xc
						then Squeeze_xen.balance_memory ~xc
					)
				done
			) in
	let (_: Thread.t) = Thread.create body () in
	()


let get_diagnostics _ dbg = "diagnostics not yet available"

let login _ dbg service_name =
	wrap dbg
	(fun () ->
		(* We assume only one instance of a named service logs in at a time and therefore can use
		   the service name as a session_id. *)
		(* remove any existing reservations associated with this service *)
		Xenctrl.with_intf
		(fun xc ->
			try Client.immediate (get_client ()) (fun xs -> Client.rm xs (state_path _service ^ "/" ^ service_name)) with Xs_protocol.Enoent _ -> ()
		);
		service_name
	)

let reserve_memory _ dbg session_id kib =
	let reservation_id = Uuidm.to_string (Uuidm.create `V4) in
	if kib < 0L
	then raise (Invalid_memory_value kib);
	wrap dbg
	(fun () ->
		Xenctrl.with_intf
		(fun xc ->
			Squeeze_xen.free_memory ~xc kib;
			debug "reserved %Ld kib for reservation %s" kib reservation_id;
			add_reservation _service session_id reservation_id (Int64.to_string kib)
		);
		reservation_id
	)

let reserve_memory_range _ dbg session_id min max =
	let reservation_id = Uuidm.to_string (Uuidm.create `V4) in
	if min < 0L
	then raise (Invalid_memory_value min);
	if max < 0L
	then raise (Invalid_memory_value max);
	wrap dbg
	(fun () ->
		Xenctrl.with_intf
		(fun xc ->
			let amount = Squeeze_xen.free_memory_range ~xc min max in
			debug "reserved %Ld kib for reservation %s" amount reservation_id;
			add_reservation _service session_id reservation_id (Int64.to_string amount);
			reservation_id, amount
		)
	)


let delete_reservation _ dbg session_id reservation_id =
	wrap dbg
	(fun () ->
		Xenctrl.with_intf
		(fun xc ->
			del_reservation _service session_id reservation_id
		)
	)

let transfer_reservation_to_domain _ dbg session_id reservation_id domid =
	wrap dbg
	(fun () ->
		Xenctrl.with_intf
		(fun xc ->
			try
				let kib = Client.immediate (get_client ()) (fun xs -> Client.read xs (reservation_path _service session_id reservation_id)) in
				(* This code is single-threaded, no need to make this transactional: *)
				Client.immediate (get_client ()) (fun xs -> Client.write xs (Printf.sprintf "/local/domain/%d/memory/initial-reservation" domid) kib);
                                Client.immediate (get_client ()) (fun xs -> Client.write xs (Printf.sprintf "/local/domain/%d/memory/reservation-id" domid) reservation_id);
				Opt.iter
					(fun maxmem -> Squeeze_xen.Domain.set_maxmem_noexn xc domid maxmem)
					(try Some (Int64.of_string kib) with _ -> None);
			with Xs_protocol.Enoent _ ->
				raise (Unknown_reservation reservation_id)
		)
	)

let query_reservation_of_domain _ dbg session_id domid =
        wrap dbg
        (fun () ->
            try
                let reservation_id = Client.immediate (get_client ()) (fun xs -> Client.read xs (Printf.sprintf "/local/domain/%d/memory/reservation-id" domid)) in
                reservation_id
            with Xs_protocol.Enoent _ ->
                raise No_reservation
        )

let balance_memory _ dbg =
	wrap dbg
	(fun () ->
		Xenctrl.with_intf
		(fun xc ->
			Squeeze_xen.balance_memory ~xc
		)
	)

let get_host_reserved_memory _ dbg = Squeeze_xen.target_host_free_mem_kib

let get_host_initial_free_memory _ dbg = 0L (* XXX *)

let sysfs_stem = "/sys/devices/system/xen_memory/xen_memory0/"

let _current_allocation = "info/current_kb"
let _requested_target = "target_kb"
let _low_mem_balloon = "info/low_kb"
let _high_mem_balloon = "info/high_kb"

(** Queries the balloon driver and forms a string * int64 association list *)
let parse_sysfs_balloon () =
	let keys = [
		_current_allocation;
		_requested_target;
		_low_mem_balloon;
		_high_mem_balloon] in
	let string_of_file filename =
		let results = ref [] in
		let ic = open_in filename in
		try
			while true do
				let line = input_line ic in
				results := line :: !results
			done;
			"" (* this will never occur... *)
		with End_of_file -> String.concat "" (List.rev !results) in
	let r = Re_str.regexp "[ \t\n]+" in
	let strip line = match Re_str.split_delim r line with
		| x :: _ -> x
		| [] -> "" in
	List.map (fun key ->
		let s = string_of_file (sysfs_stem ^ key) in
		key, Int64.of_string (strip s)
	) keys

(* The total amount of memory addressable by this OS, read without
   asking xen (which may not be running if we've just installed
   the packages and are now setting them up) *)
let parse_proc_meminfo () =
	let ic = open_in "/proc/meminfo" in
	finally
		(fun () ->
			let rec loop () =
				match String.split_f String.isspace (input_line ic) with
				| [ "MemTotal:"; total; "kB" ] ->
					Int64.(mul (of_string total) 1024L)
				| _ -> loop () in
			try
				loop ()
			with End_of_file ->
				error "Failed to read MemTotal from /proc/meminfo";
				failwith "Failed to read MemTotal from /proc/meminfo"

		) (fun () -> close_in ic)

let get_total_memory () =
	try
		let pairs = parse_sysfs_balloon () in
		let keys = [ _low_mem_balloon; _high_mem_balloon; _current_allocation ] in
		let vs = List.map (fun x -> List.assoc x pairs) keys in
		Int64.mul 1024L (List.fold_left Int64.add 0L vs)
	with _ ->
		error "Failed to query balloon driver; parsing /proc/meminfo instead";
		parse_proc_meminfo ()

let get_domain_zero_policy _ dbg =
	wrap dbg
	(fun () ->
		let dom0_max = get_total_memory () in
		if !Squeeze.manage_domain_zero
		then Auto_balloon(!Squeeze.domain_zero_dynamic_min, match !Squeeze.domain_zero_dynamic_max with
			| None -> dom0_max
			| Some x -> x)
		else Fixed_size dom0_max
	)
