open Import

let ocaml_flags sctx ~dir melange =
  let open Memo.O in
  let* expander = Super_context.expander sctx ~dir in
  let* flags =
    let+ ocaml_flags =
      Super_context.env_node sctx ~dir >>= Env_node.ocaml_flags
    in
    Ocaml_flags.make_with_melange ~melange ~default:ocaml_flags
      ~eval:(Expander.expand_and_eval_set expander)
  in
  Super_context.build_dir_is_vendored dir >>| function
  | false -> flags
  | true ->
    let ocaml_version = (Super_context.context sctx).version in
    Super_context.with_vendored_flags ~ocaml_version flags

let lib_output_dir ~target_dir ~lib_dir =
  Path.Build.append_source target_dir
    (Path.Build.drop_build_context_exn lib_dir)

let make_js_name ~js_ext ~dst_dir m =
  let name = Melange.js_basename m ^ js_ext in
  Path.Build.relative dst_dir name

let local_of_lib ~loc lib =
  match Lib.Local.of_lib lib with
  | Some s -> s
  | None ->
    let lib_name = Lib.name lib in
    User_error.raise ~loc
      [ Pp.textf "The external library %s cannot be used"
          (Lib_name.to_string lib_name)
      ]

let impl_only_modules_defined_in_this_lib sctx lib =
  let open Memo.O in
  let+ modules = Dir_contents.modules_of_lib sctx lib >>| Option.value_exn in
  (* for a virtual library,this will return all modules *)
  (Modules.split_by_lib modules).impl
  |> List.filter ~f:(Module.has ~ml_kind:Impl)

let js_deps libs ~loc ~target_dir ~js_ext =
  let glob = Glob.of_string_exn Loc.none ("*" ^ js_ext) in
  let of_lib lib =
    let lib_dir = local_of_lib ~loc lib |> Lib.Local.info |> Lib_info.src_dir in
    let dir = Path.build @@ lib_output_dir ~target_dir ~lib_dir in
    Dep.file_selector @@ File_selector.of_glob ~dir glob
  in
  Resolve.Memo.List.concat_map libs ~f:(fun lib ->
      let for_lib = [ of_lib lib ] in
      match Lib.implements lib with
      | None -> Resolve.Memo.return for_lib
      | Some vlib ->
        let open Resolve.Memo.O in
        let+ vlib = vlib in
        let for_vlib = of_lib vlib in
        for_vlib :: for_lib)
  |> Resolve.Memo.map ~f:Dep.Set.of_list

let cmj_glob = Glob.of_string_exn Loc.none "*.cmj"

let cmj_includes ~(requires_link : Lib.t list Resolve.t) ~scope =
  let project = Scope.project scope in
  let deps_of_lib lib =
    let info = Lib.info lib in
    let obj_dir = Lib_info.obj_dir info in
    let dir = Obj_dir.melange_dir obj_dir in
    Dep.file_selector @@ File_selector.of_glob ~dir cmj_glob
  in
  let open Resolve.O in
  Command.Args.memo @@ Resolve.args
  @@ let+ requires_link = requires_link in
     let deps = List.map requires_link ~f:deps_of_lib |> Dep.Set.of_list in
     Command.Args.S
       [ Lib_flags.L.include_flags ~project requires_link Melange
       ; Hidden_deps deps
       ]

let build_js ~loc ~dir ~pkg_name ~mode ~module_system ~dst_dir ~obj_dir ~sctx
    ~includes ~js_ext m =
  let open Memo.O in
  let* compiler = Melange_binary.melc sctx ~loc:(Some loc) ~dir in
  let src = Obj_dir.Module.cm_file_exn obj_dir m ~kind:(Melange Cmj) in
  let output = make_js_name ~js_ext ~dst_dir m in
  let obj_dir =
    [ Command.Args.A "-I"; Path (Path.build (Obj_dir.melange_dir obj_dir)) ]
  in
  let melange_package_args =
    let pkg_name_args =
      match pkg_name with
      | None -> []
      | Some pkg_name ->
        [ "--bs-package-name"; Package.Name.to_string pkg_name ]
    in
    let js_modules_str = Melange.Module_system.to_string module_system in
    "--bs-module-type" :: js_modules_str :: pkg_name_args
  in
  Super_context.add_rule sctx ~dir ~loc ~mode
    (Command.run
       ~dir:(Path.build (Super_context.context sctx).build_dir)
       compiler
       [ Command.Args.S obj_dir
       ; Command.Args.as_any includes
       ; As melange_package_args
       ; A "-o"
       ; Target output
       ; Dep (Path.build src)
       ])

let add_rules_for_entries ~sctx ~dir ~expander ~dir_contents ~scope
    ~compile_info ~target_dir ~mode (mel : Melange_stanzas.Emit.t) =
  let open Memo.O in
  (* Use "mobjs" rather than "objs" to avoid a potential conflict with a library
     of the same name *)
  let* modules, obj_dir =
    Dir_contents.ocaml dir_contents
    >>| Ml_sources.modules_and_obj_dir ~for_:(Melange { target = mel.target })
  in
  let* () = Check_rules.add_obj_dir sctx ~obj_dir in
  let* modules, pp =
    Buildable_rules.modules_rules sctx
      (Melange
         { preprocess = mel.preprocess
         ; preprocessor_deps = mel.preprocessor_deps
         ; (* TODO still needed *)
           lint = Preprocess.Per_module.default ()
         ; (* why is this always false? *)
           empty_module_interface_if_absent = false
         })
      expander ~dir scope modules
  in
  let requires_link = Lib.Compile.requires_link compile_info in
  let* flags = ocaml_flags sctx ~dir mel.compile_flags in
  let* cctx =
    let js_of_ocaml = None in
    let direct_requires = Lib.Compile.direct_requires compile_info in
    Compilation_context.create () ~loc:mel.loc ~super_context:sctx ~expander
      ~scope ~obj_dir ~modules ~flags ~requires_link
      ~requires_compile:direct_requires ~preprocessing:pp ~js_of_ocaml
      ~opaque:Inherit_from_settings ~package:mel.package
      ~modes:
        { ocaml = { byte = None; native = None }
        ; melange = Some (Requested Loc.none)
        }
  in
  let pkg_name = Option.map mel.package ~f:Package.name in
  let loc = mel.loc in
  let js_ext = mel.javascript_extension in
  let* requires_link = Memo.Lazy.force requires_link in
  let includes = cmj_includes ~requires_link ~scope in
  let* () = Module_compilation.build_all cctx in
  let modules_for_js =
    Modules.fold_no_vlib modules ~init:[] ~f:(fun x acc ->
        if Module.has x ~ml_kind:Impl then x :: acc else acc)
  in
  let dst_dir =
    Path.Build.append_source target_dir (Path.Build.drop_build_context_exn dir)
  in
  let* () =
    Memo.parallel_iter modules_for_js ~f:(fun m ->
        build_js ~dir ~loc ~pkg_name ~mode ~module_system:mel.module_system
          ~dst_dir ~obj_dir ~sctx ~includes ~js_ext m)
  in
  let* () =
    match mel.alias with
    | None -> Memo.return ()
    | Some alias_name ->
      let alias = Alias.make alias_name ~dir in
      let deps =
        List.rev_map modules_for_js ~f:(fun m ->
            make_js_name ~js_ext ~dst_dir m |> Path.build)
        |> Action_builder.paths
      in
      let* () = Rules.Produce.Alias.add_deps alias deps in
      Rules.Produce.Alias.add_deps alias
        (let open Action_builder.O in
        let* requires = Resolve.read requires_link in
        let* deps =
          Resolve.Memo.read @@ js_deps requires ~loc:mel.loc ~target_dir ~js_ext
        in
        Action_builder.deps deps)
  in
  let* requires_compile = Compilation_context.requires_compile cctx in
  let preprocess =
    Preprocess.Per_module.with_instrumentation mel.preprocess
      ~instrumentation_backend:
        (Lib.DB.instrumentation_backend (Scope.libs scope))
  in
  let stdlib_dir = (Super_context.context sctx).stdlib_dir in
  Memo.return
    ( cctx
    , Merlin.make ~requires:requires_compile ~stdlib_dir ~flags ~modules
        ~source_dirs:Path.Source.Set.empty ~libname:None ~preprocess ~obj_dir
        ~ident:(Lib.Compile.merlin_ident compile_info)
        ~dialects:(Dune_project.dialects (Scope.project scope))
        ~modes:`Melange_emit )

let add_rules_for_libraries ~dir ~scope ~target_dir ~sctx ~requires_link ~mode
    (mel : Melange_stanzas.Emit.t) =
  Memo.parallel_iter requires_link ~f:(fun lib ->
      let open Memo.O in
      let lib_name = Lib.name lib in
      let* lib, lib_compile_info =
        Lib.DB.get_compile_info (Scope.libs scope) lib_name
          ~allow_overlaps:mel.allow_overlapping_dependencies
      in
      let info = local_of_lib ~loc:mel.loc lib |> Lib.Local.info in
      let loc = Lib_info.loc info in
      let obj_dir = Lib_info.obj_dir info in
      let pkg_name = Lib_info.package info in
      let js_ext = mel.javascript_extension in
      let* includes =
        let+ requires_link =
          Memo.Lazy.force (Lib.Compile.requires_link lib_compile_info)
        in
        cmj_includes ~requires_link ~scope
      in
      let* () =
        match Lib.implements lib with
        | None -> Memo.return ()
        | Some vlib ->
          let* vlib = Resolve.Memo.read_memo vlib in
          let dst_dir =
            let lib_dir =
              local_of_lib ~loc vlib |> Lib.Local.info |> Lib_info.src_dir
            in
            lib_output_dir ~target_dir ~lib_dir
          in
          let* includes =
            let+ requires_link =
              Lib.Compile.for_lib
                ~allow_overlaps:mel.allow_overlapping_dependencies
                (Scope.libs scope) vlib
              |> Lib.Compile.requires_link |> Memo.Lazy.force
            in
            cmj_includes ~requires_link ~scope
          in
          impl_only_modules_defined_in_this_lib sctx vlib
          >>= Memo.parallel_iter
                ~f:
                  (build_js ~loc ~dir ~pkg_name ~mode
                     ~module_system:mel.module_system ~dst_dir ~obj_dir ~sctx
                     ~includes ~js_ext)
      in
      let* source_modules = impl_only_modules_defined_in_this_lib sctx lib in
      let dst_dir =
        let lib_dir = Lib_info.src_dir info in
        lib_output_dir ~target_dir ~lib_dir
      in
      Memo.parallel_iter source_modules
        ~f:
          (build_js ~loc ~dir ~pkg_name ~mode ~module_system:mel.module_system
             ~dst_dir ~obj_dir ~sctx ~includes ~js_ext))

let compile_info ~scope (mel : Melange_stanzas.Emit.t) =
  let open Memo.O in
  let dune_version = Scope.project scope |> Dune_project.dune_version in
  let+ pps =
    Resolve.Memo.read_memo
      (Preprocess.Per_module.with_instrumentation mel.preprocess
         ~instrumentation_backend:
           (Lib.DB.instrumentation_backend (Scope.libs scope)))
    >>| Preprocess.Per_module.pps
  in
  let merlin_ident = Merlin_ident.for_melange ~target:mel.target in
  Lib.DB.resolve_user_written_deps (Scope.libs scope) (`Melange_emit mel.target)
    ~allow_overlaps:mel.allow_overlapping_dependencies ~forbidden_libraries:[]
    mel.libraries ~pps ~dune_version ~merlin_ident

let emit_rules ~dir_contents ~dir ~scope ~sctx ~expander mel =
  let open Memo.O in
  let* compile_info = compile_info ~scope mel in
  let target_dir = Path.Build.relative dir mel.target in
  let mode =
    match mel.promote with
    | None -> Rule.Mode.Standard
    | Some p -> Promote p
  in
  let f () =
    let+ cctx_and_merlin =
      add_rules_for_entries ~sctx ~dir ~expander ~dir_contents ~scope
        ~compile_info ~target_dir ~mode mel
    and+ () =
      let* requires_link =
        Memo.Lazy.force (Lib.Compile.requires_link compile_info)
      in
      let* requires_link = Resolve.read_memo requires_link in
      add_rules_for_libraries ~dir ~scope ~target_dir ~sctx ~requires_link ~mode
        mel
    in
    cctx_and_merlin
  in
  Buildable_rules.with_lib_deps
    (Super_context.context sctx)
    compile_info ~dir ~f
