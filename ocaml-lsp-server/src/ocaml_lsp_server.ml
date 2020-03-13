open Import

let { Logger.log } = Logger.for_section "ocaml-lsp-server"

let make_error = Lsp.Jsonrpc.Response.Error.make

let not_supported () =
  Error
    (make_error ~code:InternalError ~message:"Request not supported yet!" ())

module Action = struct
  let destruct = "destruct"
end

module Position = struct
  include Lsp.Gprotocol.Position

  let ( - ) ({ line; character } : t) (t : t) : t =
    { line = line - t.line; character = character - t.character }

  let abs ({ line; character } : t) : t =
    { line = abs line; character = abs character }

  let compare ({ line; character } : t) (t : t) : Ordering.t =
    Stdune.Tuple.T2.compare Int.compare Int.compare (line, character)
      (t.line, t.character)

  let compare_inclusion (t : t) (r : Lsp.Gprotocol.Range.t) =
    match (compare t r.start, compare t r.end_) with
    | Lt, Lt -> `Outside (abs (r.start - t))
    | Gt, Gt -> `Outside (abs (r.end_ - t))
    | Eq, Lt
    | Gt, Eq
    | Eq, Eq
    | Gt, Lt ->
      `Inside
    | Eq, Gt
    | Lt, Eq
    | Lt, Gt ->
      assert false
end

module Range = struct
  include Lsp.Gprotocol.Range

  (* Compares ranges by their lengths*)
  let compare_size (x : t) (y : t) =
    let dx = Position.(x.end_ - x.start) in
    let dy = Position.(y.end_ - y.start) in
    Stdune.Tuple.T2.compare Int.compare Int.compare (dx.line, dy.line)
      (dx.character, dy.character)
end

let completion_kind kind : Lsp.Completion.completionItemKind option =
  match kind with
  | `Value -> Some Value
  | `Constructor -> Some Constructor
  | `Variant -> None
  | `Label -> Some Property
  | `Module
  | `Modtype ->
    Some Module
  | `Type -> Some TypeParameter
  | `MethodCall -> Some Method

module InitializeResult = Lsp.Gprotocol.InitializeResult
module ClientCapabilities = Lsp.Gprotocol.ClientCapabilities
module CodeActionKind = Lsp.Gprotocol.CodeActionKind
module CodeActionParams = Lsp.Gprotocol.CodeActionParams
module CodeAction = Lsp.Gprotocol.CodeAction
module CodeActionResult = Lsp.Gprotocol.CodeActionResult
module WorkspaceEdit = Lsp.Gprotocol.WorkspaceEdit
module TextEdit = Lsp.Gprotocol.TextEdit
module CodeLens = Lsp.Gprotocol.CodeLens
module Command = Lsp.Gprotocol.Command
module MarkupContent = Lsp.Gprotocol.MarkupContent
module MarkupKind = Lsp.Gprotocol.MarkupKind
module Hover = Lsp.Gprotocol.Hover
module HoverParams = Lsp.Gprotocol.HoverParams
module DocumentSymbolParams = Lsp.Gprotocol.DocumentSymbolParams
module DocumentSymbol = Lsp.Gprotocol.DocumentSymbol
module SymbolKind = Lsp.Gprotocol.SymbolKind
module SymbolInformation = Lsp.Gprotocol.SymbolInformation
module TextDocumentEdit = Lsp.Gprotocol.TextDocumentEdit
module VersionedTextDocumentIdentifier =
  Lsp.Gprotocol.VersionedTextDocumentIdentifier
module DocumentHighlight = Lsp.Gprotocol.DocumentHighlight
module DocumentHighlightKind = Lsp.Gprotocol.DocumentHighlightKind
module FoldingRange = Lsp.Gprotocol.FoldingRange
module FoldingRangeParams = Lsp.Gprotocol.FoldingRangeParams
module SelectionRange = Lsp.Gprotocol.SelectionRange
module PublishDiagnosticsParams = Lsp.Gprotocol.PublishDiagnosticsParams
module Diganostic = Lsp.Gprotocol.Diagnostic
module DiganosticSeverity = Lsp.Gprotocol.DiagnosticSeverity
module MessageType = Lsp.Gprotocol.MessageType
module ShowMessageParams = Lsp.Gprotocol.ShowMessageParams

let outline_kind kind : SymbolKind.t =
  match kind with
  | `Value -> Function
  | `Constructor -> Constructor
  | `Label -> Property
  | `Module -> Module
  | `Modtype -> Module
  | `Type -> String
  | `Exn -> Constructor
  | `Class -> Class
  | `Method -> Method

let initializeInfo : InitializeResult.t =
  let open Lsp.Gprotocol in
  let codeActionProvider =
    `CodeActionOptions
      (CodeActionOptions.create ~codeActionKinds:[ Other Action.destruct ] ())
  in
  let textDocumentSync =
    `TextDocumentSyncOptions
      (TextDocumentSyncOptions.create ~openClose:true
         ~change:TextDocumentSyncKind.Incremental ~willSave:false
         ~willSaveWaitUntil:false ())
  in
  let completionProvider =
    (* TODO even if this re-enabled in general, it should stay disabled for
       emacs. It makes completion too slow *)
    CompletionOptions.create ~triggerCharacters:[ "." ] ~resolveProvider:false
      ()
  in
  let capabilities =
    ServerCapabilities.create ~textDocumentSync ~hoverProvider:(`Bool true)
      ~definitionProvider:(`Bool true) ~typeDefinitionProvider:(`Bool true)
      ~completionProvider ~codeActionProvider ~referencesProvider:(`Bool true)
      ~documentHighlightProvider:(`Bool true)
      ~selectionRangeProvider:(`Bool true) ~documentSymbolProvider:(`Bool true)
      ~renameProvider:(`Bool true) ()
  in
  let serverInfo =
    (* TODO use actual version *)
    InitializeResult.create_serverInfo ~name:"ocamllsp" ()
  in
  InitializeResult.create ~capabilities ~serverInfo ()

let dispatch_in_doc doc command =
  Document.with_pipeline doc (fun pipeline ->
      Query_commands.dispatch pipeline command)

let logical_of_position (position : Lsp.Protocol.Position.t) =
  let line = position.line + 1 in
  let col = position.character in
  `Logical (line, col)

let logical_of_position' (position : Position.t) =
  let line = position.line + 1 in
  let col = position.character in
  `Logical (line, col)

let position_of_lexical_position (lex_position : Lexing.position) =
  let line = lex_position.pos_lnum - 1 in
  let character = lex_position.pos_cnum - lex_position.pos_bol in
  { Position.line; character }

let range_of_loc (loc : Location.t) : Range.t =
  { start = position_of_lexical_position loc.loc_start
  ; end_ = position_of_lexical_position loc.loc_end
  }

let send_diagnostics rpc doc =
  let command =
    Query_protocol.Errors { lexing = true; parsing = true; typing = true }
  in
  Document.with_pipeline doc @@ fun pipeline ->
  let errors = Query_commands.dispatch pipeline command in
  let diagnostics =
    List.map errors ~f:(fun (error : Location.error) ->
        let loc = Location.loc_of_report error in
        let range = range_of_loc loc in
        let severity =
          match error.source with
          | Warning -> DiganosticSeverity.Warning
          | _ -> DiganosticSeverity.Error
        in
        let message =
          Location.print_main Format.str_formatter error;
          String.trim (Format.flush_str_formatter ())
        in
        Diganostic.create ~range ~message ~severity ~relatedInformation:[]
          ~tags:[] ())
  in

  let notif =
    let uri = Document.uri doc |> Lsp.Uri.to_string in
    Lsp.Server_notification.PublishDiagnostics
      (PublishDiagnosticsParams.create ~uri ~diagnostics ())
  in

  Lsp.Rpc.send_notification rpc notif

let on_initialize rpc state _params =
  let log_consumer (section, title, text) =
    if title <> Logger.Title.LocalDebug then
      let type_, text =
        match title with
        | Error -> (MessageType.Error, text)
        | Warning -> (Warning, text)
        | Info -> (Info, text)
        | Debug -> (Log, Printf.sprintf "debug: %s" text)
        | Notify -> (Log, Printf.sprintf "notify: %s" text)
        | Custom s -> (Log, Printf.sprintf "%s: %s" s text)
        | LocalDebug -> failwith "impossible"
      in
      let message = Printf.sprintf "[%s] %s" section text in
      let notif = Lsp.Server_notification.LogMessage { message; type_ } in
      Lsp.Rpc.send_notification rpc notif
  in
  Logger.register_consumer log_consumer;
  Ok (state, initializeInfo)

let code_action_of_case_analysis uri (loc, newText) =
  let edit : WorkspaceEdit.t =
    let textedit : TextEdit.t = { range = range_of_loc loc; newText } in
    let uri = Lsp.Uri.to_string uri in
    WorkspaceEdit.create ~changes:[ (uri, [ textedit ]) ] ()
  in
  let title = String.capitalize_ascii Action.destruct in
  CodeAction.create ~title ~kind:(CodeActionKind.Other Action.destruct) ~edit
    ~isPreferred:false ()

let code_action store (params : CodeActionParams.t) =
  let open Lsp.Import.Result.O in
  match params.context.only with
  | Some set when not (List.mem (CodeActionKind.Other Action.destruct) ~set) ->
    Ok (store, None)
  | Some _
  | None ->
    let uri = Lsp.Uri.t_of_yojson (`String params.textDocument.uri) in
    Document_store.get store uri >>= fun doc ->
    let command =
      let start = logical_of_position' params.range.start in
      let finish = logical_of_position' params.range.end_ in
      Query_protocol.Case_analysis (start, finish)
    in
    let result : CodeActionResult.t =
      try
        let res = dispatch_in_doc doc command in
        Some [ `CodeAction (code_action_of_case_analysis uri res) ]
      with
      | Destruct.Wrong_parent _
      | Query_commands.No_nodes
      | Destruct.Not_allowed _
      | Destruct.Useless_refine
      | Destruct.Nothing_to_do ->
        Some []
    in
    Ok (store, result)

module Formatter = struct
  let jsonrpc_error (e : Fmt.error) =
    let message = Fmt.message e in
    let code : Lsp.Jsonrpc.Response.Error.Code.t =
      match e with
      | Missing_binary _ -> InvalidRequest
      | Unexpected_result _ -> InternalError
      | Unknown_extension _ -> InvalidRequest
    in
    make_error ~code ~message ()

  let run rpc store doc =
    let src = Document.source doc |> Msource.text in
    let fname = Document.uri doc |> Lsp.Uri.to_path in
    match Fmt.run ~contents:src ~fname with
    | Result.Error e ->
      let message = Fmt.message e in
      let error = jsonrpc_error e in
      let msg = ShowMessageParams.create ~message ~type_:Error in
      Lsp.Rpc.send_notification rpc (ShowMessage msg);
      Error error
    | Result.Ok result ->
      let pos line col = { Lsp.Protocol.Position.character = col; line } in
      let range =
        let start_pos = pos 0 0 in
        match Msource.get_logical (Document.source doc) `End with
        | `Logical (l, c) ->
          let end_pos = pos l c in
          { Lsp.Protocol.Range.start_ = start_pos; end_ = end_pos }
      in
      let change = { Lsp.Protocol.TextEdit.newText = result; range } in
      Ok (store, [ change ])
end

let on_request :
    type resp.
       Lsp.Rpc.t
    -> Document_store.t
    -> ClientCapabilities.t
    -> resp Lsp.Client_request.t
    -> (Document_store.t * resp, Lsp.Jsonrpc.Response.Error.t) result =
 fun rpc store client_capabilities req ->
  let open Lsp.Import.Result.O in
  match req with
  | Lsp.Client_request.Initialize _ -> assert false
  | Lsp.Client_request.Shutdown -> Ok (store, ())
  | Lsp.Client_request.DebugTextDocumentGet
      { textDocument = { uri }; position = _ } -> (
    let uri = Lsp.Uri.t_of_yojson (`String uri) in
    match Document_store.get_opt store uri with
    | None -> Ok (store, None)
    | Some doc -> Ok (store, Some (Msource.text (Document.source doc))) )
  | Lsp.Client_request.DebugEcho params -> Ok (store, params)
  | Lsp.Client_request.TextDocumentColor _ -> Ok (store, [])
  | Lsp.Client_request.TextDocumentColorPresentation _ -> Ok (store, [])
  | Lsp.Client_request.TextDocumentHover { textDocument = { uri }; position }
    -> (
    let query_type doc pos =
      let command = Query_protocol.Type_enclosing (None, pos, None) in
      match dispatch_in_doc doc command with
      | []
      | (_, `Index _, _) :: _ ->
        None
      | (location, `String value, _) :: _ -> Some (location, value)
    in

    let query_doc doc pos =
      let command = Query_protocol.Document (None, pos) in
      match dispatch_in_doc doc command with
      | `Found s
      | `Builtin s ->
        Some s
      | _ -> None
    in

    let format_contents ~as_markdown ~typ ~doc =
      let doc =
        match doc with
        | None -> ""
        | Some s -> Printf.sprintf "\n(** %s *)" s
      in
      `MarkupContent
        ( if as_markdown then
          { MarkupContent.value = Printf.sprintf "```ocaml\n%s%s\n```" typ doc
          ; kind = MarkupKind.Markdown
          }
        else
          { MarkupContent.value = Printf.sprintf "%s%s" typ doc
          ; kind = MarkupKind.PlainText
          } )
    in

    let uri = Lsp.Uri.t_of_yojson (`String uri) in
    Document_store.get store uri >>= fun doc ->
    let pos = logical_of_position' position in
    match query_type doc pos with
    | None -> Ok (store, None)
    | Some (loc, typ) ->
      let doc = query_doc doc pos in
      let as_markdown =
        match client_capabilities.textDocument with
        | None -> false
        | Some { hover = Some { contentFormat; _ }; _ } ->
          List.mem Lsp.Gprotocol.MarkupKind.Markdown
            ~set:(Option.value contentFormat ~default:[ Markdown ])
        | _ -> false
      in
      let contents = format_contents ~as_markdown ~typ ~doc in
      let range = range_of_loc loc in
      let resp = Hover.create ~contents ~range () in
      Ok (store, Some resp) )
  | Lsp.Client_request.TextDocumentReferences
      { textDocument = { uri }; position; context = _ } ->
    let uri = Lsp.Uri.t_of_yojson (`String uri) in
    Document_store.get store uri >>= fun doc ->
    let command =
      Query_protocol.Occurrences (`Ident_at (logical_of_position' position))
    in
    let locs : Location.t list = dispatch_in_doc doc command in
    let lsp_locs =
      List.map locs ~f:(fun loc ->
          let range = range_of_loc loc in
          (* using original uri because merlin is looking only in local file *)
          let uri = Lsp.Uri.to_string uri in
          { Lsp.Gprotocol.Location.uri; range })
    in
    Ok (store, Some lsp_locs)
  | Lsp.Client_request.TextDocumentCodeLensResolve codeLens ->
    Ok (store, codeLens)
  | Lsp.Client_request.TextDocumentCodeLens { textDocument = { uri } } ->
    let uri = Lsp.Uri.t_of_yojson (`String uri) in
    Document_store.get store uri >>= fun doc ->
    let command = Query_protocol.Outline in
    let outline = dispatch_in_doc doc command in
    let symbol_infos =
      let rec symbol_info_of_outline_item item =
        let children =
          List.concat_map item.Query_protocol.children
            ~f:symbol_info_of_outline_item
        in
        match item.Query_protocol.outline_type with
        | None -> children
        | Some typ ->
          let loc = item.Query_protocol.location in
          let info =
            let range = range_of_loc loc in
            let command = Command.create ~title:typ ~command:"" () in
            CodeLens.create ~range ~command ()
          in
          info :: children
      in
      List.concat_map ~f:symbol_info_of_outline_item outline
    in
    Ok (store, symbol_infos)
  | Lsp.Client_request.TextDocumentHighlight
      { textDocument = { uri }; position } ->
    let uri = Lsp.Uri.t_of_yojson (`String uri) in
    Document_store.get store uri >>= fun doc ->
    let command =
      Query_protocol.Occurrences (`Ident_at (logical_of_position' position))
    in
    let locs : Location.t list = dispatch_in_doc doc command in
    let lsp_locs =
      List.map locs ~f:(fun loc ->
          let range = range_of_loc loc in
          (* using the default kind as we are lacking info to make a difference
             between assignment and usage. *)
          DocumentHighlight.create ~range ~kind:DocumentHighlightKind.Text ())
    in
    Ok (store, Some lsp_locs)
  | Lsp.Client_request.WorkspaceSymbol _ -> Ok (store, None)
  | Lsp.Client_request.DocumentSymbol { textDocument = { uri } } ->
    let range item = range_of_loc item.Query_protocol.location in

    let rec symbol item =
      let children = List.map item.Query_protocol.children ~f:symbol in
      let range : Range.t = range item in
      let kind = outline_kind item.outline_kind in
      DocumentSymbol.create ~name:item.Query_protocol.outline_name ~kind
        ?detail:item.Query_protocol.outline_type ~deprecated:false ~range
        ~selectionRange:range ~children ()
    in

    let rec symbol_info ?containerName item =
      let location = { Lsp.Gprotocol.Location.uri; range = range item } in
      let info =
        let kind = outline_kind item.outline_kind in
        SymbolInformation.create ~name:item.Query_protocol.outline_name ~kind
          ~deprecated:false ~location ?containerName ()
      in
      let children =
        List.concat_map item.children ~f:(symbol_info ~containerName:info.name)
      in
      info :: children
    in

    let uri = Lsp.Uri.t_of_yojson (`String uri) in
    Document_store.get store uri >>= fun doc ->
    let command = Query_protocol.Outline in
    let outline = dispatch_in_doc doc command in
    let symbols =
      let hierarchicalDocumentSymbolSupport =
        let open Lsp.Gprotocol in
        let open Option.O in
        Option.value
          ( client_capabilities.textDocument
          >>= fun (textDocument : TextDocumentClientCapabilities.t) ->
            textDocument.documentSymbol >>= fun ds ->
            ds.hierarchicalDocumentSymbolSupport )
          ~default:false
      in
      match hierarchicalDocumentSymbolSupport with
      | true ->
        let symbols = List.map outline ~f:symbol in
        `DocumentSymbol symbols
      | false ->
        let symbols = List.concat_map ~f:symbol_info outline in
        `SymbolInformation symbols
    in
    Ok (store, Some symbols)
  | Lsp.Client_request.TextDocumentDeclaration _ -> Ok (store, None)
  | Lsp.Client_request.TextDocumentDefinition
      { textDocument = { uri }; position } -> (
    let uri = Lsp.Uri.t_of_yojson (`String uri) in
    Document_store.get store uri >>= fun doc ->
    let position = logical_of_position' position in
    let command = Query_protocol.Locate (None, `ML, position) in
    match dispatch_in_doc doc command with
    | `Found (path, lex_position) ->
      let position = position_of_lexical_position lex_position in
      let range = { Range.start = position; end_ = position } in
      let uri =
        match path with
        | None -> uri
        | Some path -> Lsp.Uri.of_path path
      in
      let locs =
        [ { Lsp.Gprotocol.Location.uri = Lsp.Uri.to_string uri; range } ]
      in
      Ok (store, Some (`Location locs))
    | `At_origin
    | `Builtin _
    | `File_not_found _
    | `Invalid_context
    | `Not_found _
    | `Not_in_env _ ->
      Ok (store, None) )
  | Lsp.Client_request.TextDocumentTypeDefinition
      { textDocument = { uri }; position } ->
    let uri = Lsp.Uri.t_of_yojson (`String uri) in
    Document_store.get store uri >>= fun doc ->
    let position = logical_of_position' position in
    Document.with_pipeline doc @@ fun pipeline ->
    let typer = Mpipeline.typer_result pipeline in
    let structures = Mbrowse.of_typedtree (Mtyper.get_typedtree typer) in
    let pos = Mpipeline.get_lexing_pos pipeline position in
    let path = Mbrowse.enclosing pos [ structures ] in
    let path =
      let rec resolve_tlink env ty =
        match ty.Types.desc with
        | Tconstr (path, _, _) -> Some (env, path)
        | Tlink ty -> resolve_tlink env ty
        | _ -> None
      in
      List.filter_map path ~f:(fun (env, node) ->
          log ~title:Logger.Title.Debug "inspecting node: %s"
            (Browse_raw.string_of_node node);
          match node with
          | Browse_raw.Expression { exp_type = ty; _ }
          | Pattern { pat_type = ty; _ }
          | Core_type { ctyp_type = ty; _ }
          | Value_description { val_desc = { ctyp_type = ty; _ }; _ } ->
            resolve_tlink env ty
          | _ -> None)
    in
    let locs =
      List.filter_map path ~f:(fun (env, path) ->
          log ~title:Logger.Title.Debug "found type: %s" (Path.name path);
          let local_defs = Mtyper.get_typedtree typer in
          match
            Locate.from_string
              ~config:(Mpipeline.final_config pipeline)
              ~env ~local_defs ~pos ~namespaces:[ `Type ] `MLI
              (* FIXME: instead of converting to a string, pass it directly. *)
              (Path.name path)
          with
          | exception Env.Error _ -> None
          | `Found (path, lex_position) ->
            let position = position_of_lexical_position lex_position in
            let range = { Range.start = position; end_ = position } in
            let uri =
              match path with
              | None -> uri
              | Some path -> Lsp.Uri.of_path path
            in
            let loc =
              { Lsp.Gprotocol.Location.uri = Lsp.Uri.to_string uri; range }
            in
            Some loc
          | `At_origin
          | `Builtin _
          | `File_not_found _
          | `Invalid_context
          | `Missing_labels_namespace
          | `Not_found _
          | `Not_in_env _ ->
            None)
    in
    Ok (store, Some (`Location locs))
  | Lsp.Client_request.TextDocumentCompletion
      { textDocument = { uri }; position; context = _ } ->
    let lsp_position = position in
    let position = logical_of_position position in

    let make_string chars =
      let chars = Array.of_list chars in
      String.init (Array.length chars) ~f:(Array.get chars)
    in

    let prefix_of_position source position =
      match Msource.text source with
      | "" -> ""
      | text ->
        let len = String.length text in

        let rec find prefix i =
          if i < 0 then
            make_string prefix
          else if i >= len then
            find prefix (i - 1)
          else
            let ch = text.[i] in
            (* The characters for an infix function are missing *)
            match ch with
            | 'a' .. 'z'
            | 'A' .. 'Z'
            | '0' .. '9'
            | '.'
            | '\''
            | '_' ->
              find (ch :: prefix) (i - 1)
            | _ -> make_string prefix
        in

        let (`Offset index) = Msource.get_offset source position in
        find [] (index - 1)
    in

    let range_prefix prefix =
      let start_ =
        let len = String.length prefix in
        let character = lsp_position.character - len in
        { lsp_position with character }
      in
      { Lsp.Protocol.Range.start_; end_ = lsp_position }
    in

    let item index entry =
      let prefix, (entry : Query_protocol.Compl.entry) =
        match entry with
        | `Keep entry -> (`Keep, entry)
        | `Replace (range, entry) -> (`Replace range, entry)
      in
      let kind = completion_kind entry.kind in
      let textEdit =
        match prefix with
        | `Keep -> None
        | `Replace range ->
          Some { Lsp.Protocol.TextEdit.range; newText = entry.name }
      in
      { Lsp.Completion.label = entry.name
      ; kind
      ; detail = Some entry.desc
      ; documentation = Some entry.info
      ; deprecated = entry.deprecated
      ; preselect = None
      ; (* Without this field the client is not forced to respect the order
           provided by merlin. *)
        sortText = Some (Printf.sprintf "%04d" index)
      ; filterText = None
      ; insertText = None
      ; insertTextFormat = None
      ; textEdit
      ; additionalTextEdits = []
      ; commitCharacters = []
      ; data = None
      ; tags = []
      }
    in

    let completion_kinds =
      [ `Constructor
      ; `Labels
      ; `Modules
      ; `Modules_type
      ; `Types
      ; `Values
      ; `Variants
      ]
    in

    Document_store.get store uri >>= fun doc ->
    let prefix = prefix_of_position (Document.source doc) position in
    log ~title:Logger.Title.Debug "completion prefix: |%s|" prefix;

    Document.with_pipeline doc @@ fun pipeline ->
    let completion =
      let complete =
        Query_protocol.Complete_prefix
          (prefix, position, completion_kinds, true, true)
      in
      Query_commands.dispatch pipeline complete
    in
    let items = completion.entries |> List.map ~f:(fun entry -> `Keep entry) in
    let items =
      match completion.context with
      | `Unknown -> items
      | `Application { Query_protocol.Compl.labels; argument_type = _ } ->
        items
        @ List.map labels ~f:(fun (name, typ) ->
              `Keep
                { Query_protocol.Compl.name
                ; kind = `Label
                ; desc = typ
                ; info = ""
                ; deprecated = false (* TODO this is wrong *)
                })
    in
    let items =
      match items with
      | _ :: _ -> items
      | [] ->
        let expand =
          Query_protocol.Expand_prefix (prefix, position, completion_kinds, true)
        in
        let { Query_protocol.Compl.entries; context = _ } =
          Query_commands.dispatch pipeline expand
        in
        let range = range_prefix prefix in
        List.map ~f:(fun entry -> `Replace (range, entry)) entries
    in
    let items = List.mapi ~f:item items in
    let resp = { Lsp.Completion.isIncomplete = false; items } in
    Ok (store, resp)
  | Lsp.Client_request.TextDocumentPrepareRename _ -> Ok (store, None)
  | Lsp.Client_request.TextDocumentRename
      { textDocument = { uri }; position; newName } ->
    let uri = Lsp.Uri.t_of_yojson (`String uri) in
    Document_store.get store uri >>= fun doc ->
    let command =
      Query_protocol.Occurrences (`Ident_at (logical_of_position' position))
    in
    let locs : Location.t list = dispatch_in_doc doc command in
    let version = Document.version doc in
    let edits =
      List.map
        ~f:(fun loc ->
          let range = range_of_loc loc in
          { TextEdit.newText = newName; range })
        locs
    in
    let workspace_edits =
      let documentChanges =
        let open Option.O in
        Option.value ~default:false
          ( client_capabilities.workspace >>= fun workspace ->
            workspace.workspaceEdit >>= fun edit -> edit.documentChanges )
      in
      let uri = Lsp.Uri.to_string uri in
      if documentChanges then
        let textDocument =
          VersionedTextDocumentIdentifier.create ~uri ~version ()
        in
        WorkspaceEdit.create
          ~documentChanges:
            [ `TextDocumentEdit (TextDocumentEdit.create ~textDocument ~edits) ]
          ()
      else
        WorkspaceEdit.create ~changes:[ (uri, edits) ] ()
    in
    Ok (store, workspace_edits)
  | Lsp.Client_request.TextDocumentFoldingRange { textDocument = { uri } } ->
    let uri = Lsp.Uri.t_of_yojson (`String uri) in
    Document_store.get store uri >>= fun doc ->
    let command = Query_protocol.Outline in
    let outline = dispatch_in_doc doc command in
    let folds : FoldingRange.t list =
      let folding_range (range : Range.t) =
        FoldingRange.create ~startLine:range.start.line ~endLine:range.end_.line
          ~startCharacter:range.start.character
          ~endCharacter:range.end_.character ~kind:Region ()
      in
      let rec loop acc (items : Query_protocol.item list) =
        match items with
        | [] -> acc
        | item :: items ->
          let range = range_of_loc item.location in
          if range.end_.line - range.start.line < 2 then
            loop acc items
          else
            let items = item.children @ items in
            let range = folding_range range in
            loop (range :: acc) items
      in
      loop [] outline
      |> List.sort ~compare:(fun x y -> Ordering.of_int (compare x y))
    in
    Ok (store, Some folds)
  | Lsp.Client_request.SignatureHelp _ -> not_supported ()
  | Lsp.Client_request.ExecuteCommand _ -> not_supported ()
  | Lsp.Client_request.TextDocumentLinkResolve l -> Ok (store, l)
  | Lsp.Client_request.TextDocumentLink _ -> Ok (store, None)
  | Lsp.Client_request.WillSaveWaitUntilTextDocument _ -> Ok (store, None)
  | Lsp.Client_request.CodeAction params -> code_action store params
  | Lsp.Client_request.CompletionItemResolve compl -> Ok (store, compl)
  | Lsp.Client_request.TextDocumentFormatting
      { textDocument = { uri }; options = _ } ->
    Document_store.get store uri >>= Formatter.run rpc store
  | Lsp.Client_request.TextDocumentOnTypeFormatting _ -> Ok (store, [])
  | Lsp.Client_request.SelectionRange { textDocument = { uri }; positions } ->
    let selection_range_of_shapes (cursor_position : Position.t)
        (shapes : Query_protocol.shape list) : SelectionRange.t option =
      let rec ranges_of_shape parent s =
        let range = range_of_loc s.Query_protocol.shape_loc in
        let selectionRange = { SelectionRange.range; parent } in
        match s.Query_protocol.shape_sub with
        | [] -> [ selectionRange ]
        | xs -> List.concat_map xs ~f:(ranges_of_shape (Some selectionRange))
      in
      let ranges = List.concat_map ~f:(ranges_of_shape None) shapes in
      (* try to find the nearest range inside first, then outside *)
      let nearest_range =
        let min_by_opt xs ~f =
          List.fold_left xs ~init:None ~f:(fun state x ->
              match state with
              | None -> Some x
              | Some y -> (
                match f x y with
                | Ordering.Lt -> Some x
                | _ -> Some y ))
        in
        min_by_opt ranges ~f:(fun r1 r2 ->
            let inc (r : SelectionRange.t) =
              Position.compare_inclusion cursor_position r.range
            in
            match (inc r1, inc r2) with
            | `Outside x, `Outside y -> Position.compare x y
            | `Outside _, `Inside -> Gt
            | `Inside, `Outside _ -> Lt
            | `Inside, `Inside -> Range.compare_size r1.range r2.range)
      in
      nearest_range
    in
    let uri = Lsp.Uri.t_of_yojson (`String uri) in
    Document_store.get store uri >>= fun doc ->
    let results =
      List.filter_map positions ~f:(fun x ->
          let command = Query_protocol.Shape (logical_of_position' x) in
          let shapes = dispatch_in_doc doc command in
          selection_range_of_shapes x shapes)
    in
    Ok (store, results)
  | Lsp.Client_request.UnknownRequest _ ->
    Error (make_error ~code:InvalidRequest ~message:"Got unkown request" ())

let on_notification rpc store (notification : Lsp.Client_notification.t) :
    (Document_store.t, string) result =
  match notification with
  | TextDocumentDidOpen params ->
    let doc =
      let uri = Lsp.Uri.t_of_yojson (`String params.textDocument.uri) in
      Document.make ~uri ~text:params.textDocument.text ()
    in
    Document_store.put store doc;
    send_diagnostics rpc doc;
    Ok store
  | TextDocumentDidClose { textDocument = { uri } } ->
    let uri = Lsp.Uri.t_of_yojson (`String uri) in
    Document_store.remove_document store uri;
    Ok store
  | TextDocumentDidChange { textDocument = { uri; version }; contentChanges }
    -> (
    let uri = Lsp.Uri.t_of_yojson (`String uri) in
    match Document_store.get store uri with
    | Ok prev_doc ->
      let doc =
        let f doc change = Document.update_text ?version change doc in
        List.fold_left ~f ~init:prev_doc contentChanges
      in
      Document_store.put store doc;
      send_diagnostics rpc doc;
      Ok store
    | Error e -> Error e.message )
  | DidSaveTextDocument _
  | WillSaveTextDocument _
  | ChangeConfiguration _
  | ChangeWorkspaceFolders _
  | Initialized
  | Exit ->
    Ok store
  | Unknown_notification req -> (
    match req.method_ with
    | "$/setTraceNotification" -> Ok store
    | "$/cancelRequest" -> Ok store
    | _ ->
      ( match req.params with
      | None ->
        log ~title:Logger.Title.Warning "unknown notification: %s" req.method_
      | Some json ->
        log ~title:Logger.Title.Warning "unknown notification: %s %a"
          req.method_
          (fun () -> Yojson.Safe.pretty_to_string ~std:false)
          json );
      Ok store )

let start () =
  let docs = Document_store.make () in
  let prepare_and_run prep_exn f =
    let f () =
      match f () with
      | Ok s -> Ok s
      | Error e -> Error e
      | exception exn -> Error (prep_exn exn)
    in
    (* TODO: what to do with merlin notifications? *)
    let _notifications = ref [] in
    Logger.with_notifications (ref []) @@ fun () -> File_id.with_cache @@ f
  in
  let on_initialize rpc state params =
    prepare_and_run Printexc.to_string @@ fun () ->
    on_initialize rpc state params
  in
  let on_notification rpc state notif =
    prepare_and_run Printexc.to_string @@ fun () ->
    on_notification rpc state notif
  in
  let on_request rpc state caps req =
    prepare_and_run Lsp.Jsonrpc.Response.Error.of_exn @@ fun () ->
    on_request rpc state caps req
  in
  Lsp.Rpc.start docs { on_initialize; on_request; on_notification } stdin stdout;
  log ~title:Logger.Title.Info "exiting"

let main () =
  (* Setup env for extensions *)
  Unix.putenv "__MERLIN_MASTER_PID" (string_of_int (Unix.getpid ()));
  start ()

let () =
  let open Cmdliner in
  Printexc.record_backtrace true;

  let lsp_server log_file =
    Lsp.Logger.with_log_file ~sections:[ "ocamllsp"; "lsp" ] log_file main
  in

  let log_file =
    let open Arg in
    let doc = "Enable logging to file (pass `-' for logging to stderr)" in
    let env = env_var "OCAML_LSP_SERVER_LOG" in
    value & opt (some string) None & info [ "log-file" ] ~docv:"FILE" ~doc ~env
  in

  let cmd =
    let doc = "Start OCaml LSP server (only stdio transport is supported)" in
    ( Term.(const lsp_server $ log_file)
    , Term.info "ocamllsp" ~doc ~exits:Term.default_exits )
  in

  Term.(exit @@ eval cmd)
