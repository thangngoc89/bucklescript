(* Copyright (C) 2015-2016 Bloomberg Finance L.P.
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU Lesser General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * In addition to the permissions granted to you by the LGPL, you may combine
 * or link a "work that uses the Library" with a publicly distributed version
 * of this file to produce a combined library or application, then distribute
 * that combined work under the terms of your choosing, with no requirement
 * to comply with the obligations normally placed on you by section 4 of the
 * LGPL version 3 (or the corresponding section of a later version of the LGPL
 * should you choose to use a later version).
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU Lesser General Public License for more details.
 *
 * You should have received a copy of the GNU Lesser General Public License
 * along with this program; if not, write to the Free Software
 * Foundation, Inc., 59 Temple Place - Suite 330, Boston, MA 02111-1307, USA. *)

(** *)
module Js = struct
  module Unsafe = struct
    type any
    external inject : 'a -> any = "%identity"
    external get : 'a -> 'b -> 'c = "caml_js_get"
    external set : 'a -> 'b -> 'c -> unit = "caml_js_set"
    external pure_js_expr : string -> 'a = "caml_pure_js_expr"
    let global = pure_js_expr "joo_global_object"
    type obj
    external obj : (string * any) array -> obj = "caml_js_object"
  end
  type (-'a, +'b) meth_callback
  type 'a callback = (unit, 'a) meth_callback
  external wrap_callback : ('a -> 'b) -> ('c, 'a -> 'b) meth_callback = "caml_js_wrap_callback"
  external wrap_meth_callback : ('a -> 'b) -> ('a, 'b) meth_callback = "caml_js_wrap_meth_callback"
  type + 'a t
  type js_string
  external string : string -> js_string t = "caml_js_from_string"
  external to_string : js_string t -> string = "caml_js_to_string"
  external create_file : js_string t -> js_string t -> unit = "caml_create_file"
  external to_bytestring : js_string t -> string = "caml_js_to_byte_string"
end


(*
 Error:
     *  {
     *    row: 12,
     *    column: 2, //can be undefined
     *    text: "Missing argument",
     *    type: "error" // or "warning" or "info"
     *  }
*)
let () =
  Clflags.bs_only := true;
  Oprint.out_ident := Outcome_printer_ns.out_ident;
  Clflags.assume_no_mli := Clflags.Mli_non_exists;
  Bs_conditional_initial.setup_env ();
  Clflags.dont_write_files := true;
  Clflags.unsafe_string := false;
  Clflags.record_event_when_debug := false

let list_dependencies parser text =
  let ast = parser (Lexing.from_string text) in
  Depend.free_structure_names := Depend.StringSet.empty;
  Depend.add_implementation Depend.StringSet.empty ast;
  !Depend.free_structure_names

let list_dependencies parser text =
  let depSet = list_dependencies parser text in
  Array.of_list (Depend.StringSet.elements depSet |> List.map Js.string)


let error_of_exn e =   
#if OCAML_VERSION =~ ">4.03.0" then
  match Location.error_of_exn e with 
  | Some (`Ok e) -> Some e 
  | Some `Already_displayed
  | None -> None
#else  
  Location.error_of_exn e
#end  

type react_ppx_version = V2 | V3

let implementation ?module_name ~use_super_errors ?(react_ppx_version=V3) prefix impl str  : Js.Unsafe.obj =
  let modulename = match module_name with | None -> "Test" | Some name -> name in
  let writeCmi = module_name != None in
  (* let env = !Toploop.toplevel_env in *)
  (* Compmisc.init_path false; *)
  (* let modulename = module_of_filename ppf sourcefile outputprefix in *)
  begin match module_name with
  | None -> ()
  | Some module_name -> Env.set_unit_name module_name
  end;
  Lam_compile_env.reset () ;
  let env = Compmisc.initial_env() in (* Question ?? *)
  let finalenv = ref Env.empty in
  let types_signature = ref [] in
  if use_super_errors then begin
    Misc.Color.setup (Some Always);
    Super_main.setup ();
  end;

  (* copied over from Bsb_warning.default_warning_flag *)
  Warnings.parse_options false Bsb_warning.default_warning;

  try
    let ast = impl 
      (Lexing.from_string
        (if prefix then "[@@@bs.config{no_export}]\n#1 \"repl.ml\"\n"  ^ str else str )) in 
    let ast = match react_ppx_version with
    | V2 -> Reactjs_jsx_ppx_v2.rewrite_implementation ast
    | V3 -> Reactjs_jsx_ppx_v3.rewrite_implementation ast in 
    let ast = Bs_builtin_ppx.rewrite_implementation ast in 
    
    let typed_tree =
      if writeCmi then Clflags.dont_write_files := false else ();
      let (a,b,c,signature) =
        Typemod.type_implementation_more modulename modulename modulename env ast in
      if writeCmi then Clflags.dont_write_files := true else ();
      finalenv := c; 
      types_signature := signature; 
      (a, b) in
  typed_tree
  |>  Translmod.transl_implementation modulename
  |> (* Printlambda.lambda ppf *) (fun 
#if OCAML_VERSION =~ ">4.03.0" then
    {Lambda.code = lam}
#else    
    lam 
#end    
    ->
      let buffer = Buffer.create 1000 in
      let () = Js_dump_program.pp_deps_program
                          ~output_prefix:"" (* does not matter here *)
                          NodeJS
                          (Lam_compile_main.compile ~filename:"" ""
                             !finalenv  lam)
                          (Ext_pp.from_buffer buffer) in
      let v = Buffer.contents buffer in
      Js.Unsafe.(obj [| "js_code", inject @@ Js.string v |]) )
      (* Format.fprintf output_ppf {| { "js_code" : %S }|} v ) *)
  with
  | Refmt_api.Migrate_parsetree.Def.Migration_error (missing_feature, loc) ->
    
    let (file,line,startchar) = Location.get_pos_info loc.loc_start in
    let (file,endline,endchar) = Location.get_pos_info loc.loc_end in
    let errorString = Refmt_api.Migrate_parsetree.Def.migration_error_message missing_feature in
    Js.Unsafe.(obj
        [|
          "js_error_msg",
            inject @@ Js.string (errorString);
              "row"    , inject (line - 1);
              "column" , inject startchar;
              "endRow" , inject (endline - 1);
              "endColumn" , inject endchar;
              "type" , inject @@ Js.string "error"
        |]
      );
  (* | Syntaxerr.Error err ->
    let location = Syntaxerr.location_of_error err in
    let (file,line,startchar) = Location.get_pos_info location.loc_start in
    let (file,endline,endchar) = Location.get_pos_info location.loc_end in
    Syntaxerr.report_error Format.str_formatter err;
    let errorString = Format.flush_str_formatter () in

    Js.Unsafe.(obj
      [|
        "js_error_msg",
          inject @@ Js.string (errorString);
            "row"    , inject (line - 1);
            "column" , inject startchar;
            "endRow" , inject (endline - 1);
            "endColumn" , inject endchar;
            "type" , inject @@ Js.string "error"
      |]
    ); *)
  | e ->
      begin match error_of_exn e with
      | Some error ->
          Location.report_error Format.err_formatter  error;
          let (file,line,startchar) = Location.get_pos_info error.loc.loc_start in
          let (file,endline,endchar) = Location.get_pos_info error.loc.loc_end in
          Js.Unsafe.(obj
          [|
            "js_error_msg",
              inject @@ Js.string (Printf.sprintf "Line %d, %d:\n  %s"  line startchar error.msg);
               "row"    , inject (line - 1);
               "column" , inject startchar;
               "endRow" , inject (endline - 1);
               "endColumn" , inject endchar;
               "text" , inject @@ Js.string error.msg;
               "type" , inject @@ Js.string "error"
          |]
          );
      | None ->
        Js.Unsafe.(obj [|
        "js_error_msg" , inject @@ Js.string (Printexc.to_string e);
        "type" , inject @@ Js.string "error"
        |])

      end


let compile impl ?module_name ~use_super_errors ?react_ppx_version =
    implementation ?module_name ~use_super_errors ?react_ppx_version false impl

(** TODO: add `[@@bs.config{no_export}]\n# 1 "repl.ml"`*)
let shake_compile impl ~use_super_errors ?react_ppx_version =
   implementation ~use_super_errors ?react_ppx_version true impl



let load_module cmi_path cmi_content cmj_name cmj_content =
  Js.create_file cmi_path cmi_content;
  Js_cmj_datasets.data_sets :=
    String_map.add !Js_cmj_datasets.data_sets
      cmj_name (lazy (Js_cmj_format.from_string cmj_content))
      


let export (field : string) v =
  Js.Unsafe.set (Js.Unsafe.global) field v
;;

(* To add a directory to the load path *)

let dir_directory d =
  Config.load_path := d :: !Config.load_path


let () =
  dir_directory "/static/cmis"

let () =
  dir_directory "/static"


module Converter = Refmt_api.Migrate_parsetree.Convert(Refmt_api.Migrate_parsetree.OCaml_404)(Refmt_api.Migrate_parsetree.OCaml_402)

let reason_parse lexbuf = 
  Refmt_api.Reason_toolchain.RE.implementation lexbuf |> Converter.copy_structure;;

let make_compiler name impl =
  export name
    (Js.Unsafe.(obj
                  [|"compile",
                    inject @@
                    Js.wrap_meth_callback
                      (fun _ code ->
                         (compile impl ~use_super_errors:false (Js.to_string code)));
                    "compile_module",
                    inject @@
                    Js.wrap_meth_callback
                      (fun _ module_name code ->
                        (compile impl ~module_name:(Js.to_string module_name) ~use_super_errors:true (Js.to_string code)));
                    "shake_compile",
                    inject @@
                    Js.wrap_meth_callback
                      (fun _ code ->
                         (shake_compile impl ~use_super_errors:false (Js.to_string code)));
                    "compile_super_errors",
                    inject @@
                    Js.wrap_meth_callback
                      (fun _ code ->
                         (compile impl ~use_super_errors:true (Js.to_string code)));
                    "compile_super_errors_ppx_v2",
                    inject @@
                    Js.wrap_meth_callback
                      (fun _ code ->
                         (compile impl ~use_super_errors:true ~react_ppx_version:V2 (Js.to_string code)));
                    "compile_super_errors_ppx_v3",
                    inject @@
                    Js.wrap_meth_callback
                      (fun _ code ->
                         (compile impl ~use_super_errors:true ~react_ppx_version:V3 (Js.to_string code)));
                    "shake_compile_super_errors",
                    inject @@
                    Js.wrap_meth_callback
                      (fun _ code -> (shake_compile impl ~use_super_errors:true (Js.to_string code)));
                    "list_dependencies",
                    inject @@
                    Js.wrap_meth_callback
                      (fun _ code ->
                         (list_dependencies impl (Js.to_string code)));
                    "version", Js.Unsafe.inject (Js.string (Bs_version.version));
                    "load_module",
                    inject @@
                    Js.wrap_meth_callback
                      (fun _ cmi_path cmi_content cmj_name cmj_content ->
                        let cmj_bytestring = Js.to_bytestring cmj_content in
                        (* HACK: force string tag to ASCII (9) to avoid
                         * UTF-8 encoding *)
                        Js.Unsafe.set cmj_bytestring "t" 9;
                        load_module cmi_path cmi_content (Js.to_string cmj_name) cmj_bytestring);
                  |]))
let () = make_compiler "ocaml" Parse.implementation
let () = make_compiler "reason" reason_parse

(* local variables: *)
(* compile-command: "ocamlbuild -use-ocamlfind -pkg compiler-libs -no-hygiene driver.cmo" *)
(* end: *)
