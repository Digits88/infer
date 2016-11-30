(*
 * Copyright (c) 2016 - present Facebook, Inc.
 * All rights reserved.
 *
 * This source code is licensed under the BSD style license found in the
 * LICENSE file in the root directory of this source tree. An additional grant
 * of patent rights can be found in the PATENTS file in the same directory.
 *)

open! Utils

module F = Format
module L = Logging

module type Spec = sig
  module Source : Source.S
  module Sink : Sink.S

  (** should a flow originating at source and entering sink be reported? *)
  val should_report : Source.t -> Sink.t -> bool
end

module type S = sig
  include Spec
  type t
  type astate = t
  include AbstractDomain.S with type astate := astate

  module Sources = Source.Set
  module Sinks = Sink.Set
  module Passthroughs = Passthrough.Set

  (** path from a source to a sink with passthroughs at each step in the call stack. the first set
      of passthroughs are the ones in the "reporting" procedure that calls the first function in
      both the source and sink stack *)
  type path = Passthroughs.t * (Source.t * Passthroughs.t) list * (Sink.t * Passthroughs.t) list

  (** get the sources of the trace. *)
  val sources : t -> Sources.t

  (** get the sinks of the trace *)
  val sinks : t -> Sinks.t

  (** get the passthroughs of the trace *)
  val passthroughs : t -> Passthroughs.t

  (** get the reportable source-sink flows in this trace *)
  val get_reports : t -> (Source.t * Sink.t * Passthroughs.t) list

  (** get a path for each of the reportable source -> sink flows in this trace *)
  val get_reportable_paths : t -> trace_of_pname:(Procname.t -> t) -> path list

  (** create a loc_trace from a path; [source_should_nest s] should be true when we are going one
      deeper into a call-chain, ie when lt_level should be bumper in the next loc_trace_elem, and
      similarly for [sink_should_nest] *)
  val to_loc_trace :
    ?desc_of_source:(Source.t -> string) -> ?source_should_nest:(Source.t -> bool) ->
    ?desc_of_sink:(Sink.t -> string) -> ?sink_should_nest:(Sink.t -> bool) ->
    path -> Errlog.loc_trace

  (** create a trace from a source *)
  val of_source : Source.t -> t

  (** ad a source to the current trace *)
  val add_source : Source.t -> t -> t

  (** add a sink to the current trace. *)
  val add_sink : Sink.t -> t -> t

  (** remove the given sinks from the current trace *)
  val filter_sinks : t -> Sink.t list -> t

  (** append the trace for given call site to the current caller trace *)
  val append : t -> t -> CallSite.t -> t

  (** return true if this trace has no source or sink data *)
  val is_empty : t -> bool

  val compare : t -> t -> int

  val equal : t -> t -> bool

  val pp : F.formatter -> t -> unit

  (** pretty-print a path in the context of the given procname *)
  val pp_path : Procname.t -> F.formatter -> path -> unit
end

(** Expand a trace element (i.e., a source or sink) into a list of trace elements bottoming out in
    the "original" trace element. The list is always non-empty. *)
module Expander (TraceElem : TraceElem.S) = struct

  let expand elem0 ~elems_passthroughs_of_pname =
    let rec expand_ elem elems_passthroughs_acc =
      let elem_site = TraceElem.call_site elem in
      let elem_kind = TraceElem.kind elem in
      let elems, passthroughs = elems_passthroughs_of_pname (CallSite.pname elem_site) in
      let is_recursive elem_site callee_elem =
        Procname.equal
          (CallSite.pname elem_site) (CallSite.pname (TraceElem.call_site callee_elem)) in
      (* find sinks that are the same kind as the caller, but have a different procname *)
      let matching_elems =
        IList.filter
          (fun callee_elem ->
             TraceElem.Kind.compare (TraceElem.kind callee_elem) elem_kind = 0 &&
             not (is_recursive elem_site callee_elem))
          elems in
      match matching_elems with
      | callee_elem :: _ ->
          (* TODO: pick the shortest path to a sink here instead (t14242809) *)
          (* arbitrarily pick one elem and explore it further *)
          expand_ callee_elem ((elem, passthroughs) :: elems_passthroughs_acc)
      | _ ->
          (elem, Passthrough.Set.empty) :: elems_passthroughs_acc in
    expand_ elem0 []
end

module Make (Spec : Spec) = struct
  include Spec

  module Sources = Source.Set
  module Sinks = Sink.Set
  module Passthroughs = Passthrough.Set

  module SourceExpander = Expander(Source)
  module SinkExpander = Expander(Sink)

  type t =
    {
      sources : Sources.t; (** last functions in the trace that returned tainted data *)
      sinks : Sinks.t;
      (** last callees in the trace that transitively called a tainted function (if any) *)
      passthroughs : Passthrough.Set.t; (** calls that occurred between source and sink *)
    } [@@deriving compare]

  type astate = t

  type path = Passthroughs.t * (Source.t * Passthroughs.t) list * (Sink.t * Passthroughs.t) list

  let equal t1 t2 =
    compare t1 t2 = 0

  let pp fmt t =
    F.fprintf
      fmt
      "%a -> %a via %a"
      Sources.pp t.sources Sinks.pp t.sinks Passthroughs.pp t.passthroughs

  let sources t =
    t.sources

  let sinks t =
    t.sinks

  let passthroughs t =
    t.passthroughs

  let is_empty t =
    (* sources empty => sinks empty and passthroughs empty *)
    Sources.is_empty t.sources

  let get_reports t =
    if Sinks.is_empty t.sinks || Sources.is_empty t.sources
    then
      []
    else
      (* written to avoid closure allocations in hot code. change with caution. *)
      let report_source source sinks acc0 =
        let report_one sink acc =
          if Spec.should_report source sink
          then (source, sink, t.passthroughs) :: acc
          else acc in
        Sinks.fold report_one sinks acc0 in
      let report_sources source acc =
        if Source.is_footprint source
        then acc
        else report_source source t.sinks acc in
      Sources.fold report_sources t.sources []

  let pp_path cur_pname fmt (cur_passthroughs, sources_passthroughs, sinks_passthroughs) =
    let pp_passthroughs fmt passthroughs =
      if not (Passthrough.Set.is_empty passthroughs)
      then F.fprintf fmt "(via %a)" Passthrough.Set.pp passthroughs in

    let pp_elems elem_to_callsite fmt elems_passthroughs =
      let pp_sep fmt () = F.fprintf fmt "@." in
      let pp_elem fmt (elem, passthroughs) =
        F.fprintf
          fmt
          "|=> %a %a"
          CallSite.pp (elem_to_callsite elem) pp_passthroughs passthroughs in
      (F.pp_print_list ~pp_sep) pp_elem fmt elems_passthroughs in
    let pp_sources = pp_elems Source.call_site in
    let pp_sinks = pp_elems Sink.call_site in

    let original_source = fst (IList.hd sources_passthroughs) in
    let final_sink = fst (IList.hd sinks_passthroughs) in
    F.fprintf
      fmt
      "Error: %a -> %a. Full trace:@.%a@.Current procedure %a %a@.%a"
      Source.pp original_source
      Sink.pp final_sink
      pp_sources sources_passthroughs
      Procname.pp cur_pname
      pp_passthroughs cur_passthroughs
      pp_sinks (IList.rev sinks_passthroughs)

  let get_reportable_paths t ~trace_of_pname =
    let expand_path source sink =
      let sources_of_pname pname =
        let trace = trace_of_pname pname in
        Sources.elements (sources trace), passthroughs trace in
      let sinks_of_pname pname =
        let trace = trace_of_pname pname in
        Sinks.elements (sinks trace), passthroughs trace in
      let sources_passthroughs =
        SourceExpander.expand source ~elems_passthroughs_of_pname:sources_of_pname in
      let sinks_passthroughs =
        SinkExpander.expand sink ~elems_passthroughs_of_pname:sinks_of_pname in
      sources_passthroughs, sinks_passthroughs in

    IList.map
      (fun (source, sink, passthroughs) ->
         let sources_passthroughs, sinks_passthroughs = expand_path source sink in
         passthroughs, sources_passthroughs, sinks_passthroughs)
      (get_reports t)

  let to_loc_trace
      ?(desc_of_source=fun source ->
          let callsite = Source.call_site source in
          Format.asprintf "return from %a" Procname.pp (CallSite.pname callsite))
      ?(source_should_nest=(fun _ -> true))
      ?(desc_of_sink=fun sink ->
          let callsite = Sink.call_site sink in
          Format.asprintf "call to %a" Procname.pp (CallSite.pname callsite))
      ?(sink_should_nest=(fun _ -> true))
      (passthroughs, sources, sinks) =

    let trace_elems_of_passthroughs lt_level passthroughs acc0 =
      let trace_elem_of_passthrough passthrough acc =
        let passthrough_site = Passthrough.site passthrough in
        let desc = F.asprintf "flow through %a" Procname.pp (CallSite.pname passthrough_site) in
        (Errlog.make_trace_element lt_level (CallSite.loc passthrough_site) desc []) :: acc in
      (* sort passthroughs by ascending line number to create a coherent trace *)
      let sorted_passthroughs =
        IList.sort
          (fun passthrough1 passthrough2 ->
             let loc1 = CallSite.loc (Passthrough.site passthrough1) in
             let loc2 = CallSite.loc (Passthrough.site passthrough2) in
             Pervasives.compare loc1.Location.line loc2.Location.line)
          (Passthroughs.elements passthroughs) in
      IList.fold_right trace_elem_of_passthrough sorted_passthroughs acc0 in

    let get_nesting should_nest elems start_nesting =
      let level = ref start_nesting in
      let get_nesting_ ((elem, _) as pair) =
        if should_nest elem
        then incr level;
        pair, !level in
      IList.map get_nesting_ (IList.rev elems) in

    let trace_elems_of_path_elem call_site desc ~is_source ((elem, passthroughs), lt_level) acc =
      let desc = desc elem in
      let loc = CallSite.loc (call_site elem) in
      if is_source
      then
        let trace_elem = Errlog.make_trace_element lt_level loc desc [] in
        trace_elems_of_passthroughs (lt_level + 1) passthroughs (trace_elem :: acc)
      else
        let trace_elem = Errlog.make_trace_element (lt_level - 1) loc desc [] in
        trace_elem :: (trace_elems_of_passthroughs lt_level passthroughs acc) in

    let trace_elems_of_source =
      trace_elems_of_path_elem Source.call_site desc_of_source ~is_source:true in
    let trace_elems_of_sink =
      trace_elems_of_path_elem Sink.call_site desc_of_sink ~is_source:false in
    let sources_with_level = get_nesting source_should_nest sources (-1) in
    let sinks_with_level = get_nesting sink_should_nest sinks 0 in
    let trace_prefix =
      IList.fold_right trace_elems_of_sink sinks_with_level []
      |> trace_elems_of_passthroughs 0 passthroughs in
    IList.fold_left
      (fun acc source -> trace_elems_of_source source acc) trace_prefix sources_with_level

  let of_source source =
    let sources = Sources.singleton source in
    let passthroughs = Passthroughs.empty in
    let sinks = Sinks.empty in
    { sources; passthroughs; sinks; }

  let add_source source t =
    let sources = Sources.add source t.sources in
    { t with sources; }

  let add_sink sink t =
    let sinks = Sinks.add sink t.sinks in
    { t with sinks; }

  let filter_sinks t sinks_to_filter =
    let sinks = Sinks.diff t.sinks (Sinks.of_list sinks_to_filter) in
    { t with sinks; }

  (** compute caller_trace + callee_trace *)
  let append caller_trace callee_trace callee_site =
    if is_empty callee_trace
    then caller_trace
    else
      let non_footprint_callee_sources =
        Sources.filter (fun source -> not (Source.is_footprint source)) callee_trace.sources in
      let sources =
        if Sources.subset non_footprint_callee_sources caller_trace.sources
        then
          caller_trace.sources
        else
          IList.map
            (fun sink -> Source.with_callsite sink callee_site)
            (Sources.elements non_footprint_callee_sources)
          |> Sources.of_list
          |> Sources.union caller_trace.sources in

      let sinks =
        if Sinks.subset callee_trace.sinks caller_trace.sinks
        then
          caller_trace.sinks
        else
          IList.map
            (fun sink -> Sink.with_callsite sink callee_site)
            (Sinks.elements callee_trace.sinks)
          |> Sinks.of_list
          |> Sinks.union caller_trace.sinks in

      let passthroughs =
        if sources == caller_trace.sources && sinks == caller_trace.sinks
        then
          (* this callee didn't add any new sources or any news sinks; it's just a passthrough *)
          Passthroughs.add (Passthrough.make callee_site) caller_trace.passthroughs
        else
          caller_trace.passthroughs in

      { sources; sinks; passthroughs; }

  let initial =
    let sources = Sources.empty in
    let sinks = Sinks.empty in
    let passthroughs = Passthroughs.empty in
    { sources; sinks; passthroughs; }

  let (<=) ~lhs ~rhs =
    lhs == rhs ||
    (Sources.subset lhs.sources rhs.sources &&
     Sinks.subset lhs.sinks rhs.sinks &&
     Passthroughs.subset lhs.passthroughs rhs.passthroughs)

  let join t1 t2 =
    if t1 == t2
    then t1
    else
      let sources = Sources.union t1.sources t2.sources in
      let sinks = Sinks.union t1.sinks t2.sinks in
      let passthroughs = Passthroughs.union t1.passthroughs t2.passthroughs in
      { sources; sinks; passthroughs; }

  let widen ~prev ~next ~num_iters:_ =
    join prev next

end