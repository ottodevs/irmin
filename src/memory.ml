(*
 * Copyright (c) 2013 Thomas Gazagnaire <thomas@gazagnaire.org>
 *
 * Permission to use, copy, modify, and distribute this software for any
 * purpose with or without fee is hereby granted, provided that the above
 * copyright notice and this permission notice appear in all copies.
 *
 * THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
 * WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
 * MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR
 * ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
 * WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN
 * ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF
 * OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.
 *)

(* In memory representation of Irminsule *)
module Types = struct

  type blob = B of string

  type key = K of string

  type label = L of string

  type tree = {
    value   : key option;
    children: (label * key) list;
  }

  type revision = {
    parents: key list;
    tree   : key;
  }

  type value =
    | Blob of blob
    | Tree of tree
    | Revision of revision

  type tag = T of string

  type t = {
    store: (key, value) Hashtbl.t;
    tags : (tag, key  ) Hashtbl.t;
  }

  type remote = Uri.t

end

let sha1 (value: Types.value) =
  let str = Marshal.to_string value [] in
  Types.K (Lib.Misc.sha1 str)

module J = struct

  open Types

  (* From http://erratique.ch/software/jsonm/doc/Jsonm.html#datamodel *)
  type json =
    [ `Null | `Bool of bool | `Float of float| `String of string
    | `A of json list | `O of (string * json) list ]

  exception Escape of ((int * int) * (int * int)) * Jsonm.error

  (* strings *)
  let json_of_string s = `String s

  let string_of_json fn (json:json) = match json with
    | `String k -> fn k
    | _         -> failwith "string_of_json"

  (* list *)
  let json_of_list fn = function
    | [] -> `Null
    | l  -> `A (List.map fn l)

  let list_of_json fn (json:json) = match json with
    | `Null -> []
    | `A ks -> List.map fn ks
    | _ -> failwith "list_of_json"

  (* options *)
  let json_of_option fn = function
    | None   -> `Null
    | Some x -> fn x

  let option_of_json fn (json:json) = match json with
    | `Null  -> None
    |  _     -> Some (fn json)

  (* pairs *)
  let json_of_pair fk fv (k, v) =
    `A [fk k; fv v]

  let pair_of_json fk fv (json:json) = match json with
    | `A [k; v] -> (fk k, fv v)
    | _ -> failwith "pair_of_json"

  (* keys *)
  let json_of_key (K k) = json_of_string k
  let json_of_keys = json_of_list json_of_key
  let key_of_json = string_of_json (fun x -> K x)
  let keys_of_json = list_of_json key_of_json

  (* blobs *)
  let json_of_blob (B b) = json_of_string b
  let blob_of_json = string_of_json (fun x -> B x)

  (* tags *)
  let json_of_tag (T t) = json_of_string t
  let json_of_tags  = json_of_list json_of_tag
  let tag_of_json = string_of_json (fun x -> T x)
  let tags_of_json = list_of_json tag_of_json

  (* labels *)
  let json_of_label (L l) = json_of_string l
  let label_of_json = string_of_json (fun x -> L x)

  (* trees *)
  let json_of_tree tree =
    let value = json_of_option json_of_key tree.value in
    let child = json_of_pair json_of_label json_of_key in
    let children = json_of_list child tree.children in
    `O [ ("value", value); ("children", children) ]

  let tree_of_json (json:json) = match json with
    | `O [ ("value", value); ("children", children) ] ->
      let value = option_of_json key_of_json value in
      let children = list_of_json (pair_of_json label_of_json key_of_json) children in
      let children = List.sort compare children in
      { value; children }
    | _ -> failwith "tree_of_json"

  (* revisions *)
  let json_of_revision r =
    let parents = json_of_keys r.parents in
    let tree = json_of_key r.tree in
    `O [ ("parents", parents); ("tree"   , tree) ]

  let revision_of_json (json:json) = match json with
    | `O [ ("parents", parents); ("tree", tree) ] ->
      let parents = keys_of_json parents in
      let parents = List.sort compare parents in
      let tree = key_of_json tree in
      { parents; tree }
    | _ -> failwith "revision_of_json"

  (* values *)
  let json_of_value = function
    | Blob b     -> `O [ "blob"    , json_of_blob b ]
    | Tree t     -> `O [ "tree"    , json_of_tree t ]
    | Revision r -> `O [ "revision", json_of_revision r ]

  let value_of_json = function
    | `O [ "blob"    , json ] -> Blob (blob_of_json json)
    | `O [ "tree"    , json ] -> Tree (tree_of_json json)
    | `O [ "revision", json ] -> Revision (revision_of_json json)
    | _ -> failwith "value_of_json"

  let values_of_json = list_of_json value_of_json
  let json_of_values = json_of_list json_of_value

 (* XXX: should be replaced by a streaming API *)
  let discover_of_json = function
    | `O [ ("local", local); ("remote", remote) ] ->
      let keys = keys_of_json local in
      let tags = tags_of_json remote in
      keys, tags
    | _ -> failwith "discover_of_json"

  let json_of_discover (keys, tags) =
    `O [ ("local", json_of_keys keys); ("remote", json_of_tags tags) ]

  let json_of_src ?encoding src =
    let dec d = match Jsonm.decode d with
      | `Lexeme l -> l
      | `Error e -> raise (Escape (Jsonm.decoded_range d, e))
      | `End | `Await -> assert false
    in
    let rec value v k d = match v with
      | `Os -> obj [] k d  | `As -> arr [] k d
      | `Null | `Bool _ | `String _ | `Float _ as v -> k v d
      | _ -> assert false
    and arr vs k d = match dec d with
      | `Ae -> k (`A (List.rev vs)) d
      | v -> value v (fun v -> arr (v :: vs) k) d
    and obj ms k d = match dec d with
      | `Oe -> k (`O (List.rev ms)) d
      | `Name n -> value (dec d) (fun v -> obj ((n, v) :: ms) k) d
      | _ -> assert false
    in
    let d = Jsonm.decoder ?encoding src in
    try `JSON (value (dec d) (fun v _ -> v) d) with
    | Escape (r, e) -> `Error (r, e)

  let json_of_string str: json =
    match json_of_src (`String str) with
    | `JSON j  -> j
    | `Error _ -> failwith "json_of_string"

  let json_to_dst ~minify dst (json:json) =
    let enc e l = ignore (Jsonm.encode e (`Lexeme l)) in
    let rec value v k e = match v with
      | `A vs -> arr vs k e
      | `O ms -> obj ms k e
      | `Null | `Bool _ | `Float _ | `String _ as v -> enc e v; k e
    and arr vs k e = enc e `As; arr_vs vs k e
    and arr_vs vs k e = match vs with
      | v :: vs' -> value v (arr_vs vs' k) e
      | [] -> enc e `Ae; k e
    and obj ms k e = enc e `Os; obj_ms ms k e
    and obj_ms ms k e = match ms with
      | (n, v) :: ms -> enc e (`Name n); value v (obj_ms ms k) e
      | [] -> enc e `Oe; k e
    in
    let e = Jsonm.encoder ~minify dst in
    let finish e = ignore (Jsonm.encode e `End) in
    match json with
    | `A _ | `O _ as json -> value json finish e
    | _ -> invalid_arg "invalid json text"

  let string_of_json (json:json) =
    let buf = Buffer.create 1024 in
    json_to_dst ~minify:false (`Buffer buf) json;
    Buffer.contents buf

end

module Low: Database.LOW with module T = Types = struct

  module T = Types
  open T

  let write t value =
    let sha1 = sha1 value in
    Hashtbl.add t.store sha1 value;
    sha1

  let valid t key =
    Hashtbl.mem t.store key

  let read t sha1 =
    Printf.printf "Reading %s\n%!" (match sha1 with K k -> k);
    try Some (Hashtbl.find t.store sha1)
    with Not_found -> None

  let list t =
    Hashtbl.fold (fun k _ l -> k::l) t.store []

end

module Tree: sig
  include Database.TREE with module T = Types
  val leaf: Types.key -> Types.tree
end = struct

  module T = Types
  open T

  let read t key = match Low.read t key with
    | Some (Tree t) -> Some t
    | _ -> None

  let write t tree =
    Low.write t (Tree tree)

  let list t =
    List.filter (fun k -> read t k <> None) (Low.list t)

  type node = {
    k: key;
    v: key option;
  }
  type trie = (label, node) Lib.Trie.t

  (* Convert a tree into a lazy trie *)
  let rec mktrie t tree: trie =
    let child (label, key) =
      match Low.read t key with
      | Some (Tree tree) -> (label, mktrie t tree)
      | Some v           -> failwith (J.string_of_json (J.json_of_value v))
      | None             -> failwith "mktree" in
    let children = lazy (
      List.map child tree.children
    ) in
    let value = {
      k = sha1 (Tree tree);
      v = tree.value
    } in
    Lib.Trie.create ~value ~children ()

  (* Save a lazy trie into a the database *)
  let rec save t (trie:trie) =
    let children = List.map (fun (label, child) ->
        let value = Lib.Trie.find child [] in
        if Low.valid t value.k then (label, value.k)
        else (label, save t child)
      ) (Lib.Trie.children trie) in
    let children = List.sort compare children in
    let node = Lib.Trie.find trie [] in
    Low.write t (Tree { children; value = node.v })

  (* Save a trie in the database and return its corresponding tree.*)
  let mktree t trie =
    let key = save t trie in
    match Low.read t key with
    | Some (Tree t) -> t
    | _             -> failwith "tree"

  let get t tree labels =
    let trie = mktrie t tree in
    try Some (Lib.Trie.find trie labels).k
    with Not_found -> None

  let leaf key = {
    value = Some key;
    children = [];
  }

  let node key =
    let tree = leaf key in
    {
      k = sha1 (Tree tree);
      v = Some key;
    }

  (* XXX: not very efficient *)
  let set t tree labels value =
    let trie = mktrie t tree in
    let key = Low.write t value in
    let trie = Lib.Trie.set trie labels (node key) in
    mktree t trie

  exception EAGAIN
  exception Invalid_values

  let merge t fn t1 t2 =
    let t1 = mktrie t t1 in
    let t2 = mktrie t t2 in
    let values l1 l2 =
      match l1, l2 with
      | [n1], [n2] ->
        begin match fn (Low.read t n1.k) (Low.read t n2.k) with
          | Some v3 -> let k3 = Low.write t v3 in [node k3]
          | None    -> []
        end
      | _ -> raise Invalid_values
    in
    try Some (mktree t (Lib.Trie.merge ~values t1 t2))
    with EAGAIN | Not_found -> None

  let succ t tree =
    let trie = mktrie t tree in
    let children = Lib.Trie.children trie in
    List.map (fun (label,trie) -> (label, mktree t trie)) children

end

module Revision: Database.REVISION with module T = Types = struct

  module T = Types
  open T

  let read t key = match Low.read t key with
    | Some (Revision r) -> Some r
    | _ -> None

  let write t rev =
    Low.write t (Revision rev)

  let list t =
    List.filter (fun k -> read t k <> None) (Low.list t)

  let pred t rev =
    List.fold_left (fun l k -> match read t k with
        | None   -> l
        | Some r -> r::l
      ) [] rev.parents

  let tree t rev =
    Tree.read t rev.tree

  let commit t parents working_tree =
    let commit () =
      let parents = List.map (write t) parents in
      let parents = List.sort compare parents in
      let tree = Tree.write t working_tree in
      let rev = { parents; tree } in
      let _key = write t rev in
      rev in
    match parents with
    | [parent] ->
      (* Avoid empty commit *)
      begin match tree t parent with
        | None   -> commit ()
        | Some t -> if t = working_tree then parent else commit ()
      end
    | _ -> commit ()

end

module Tag: Database.TAG with module T = Types = struct

  module T = Types
  open T

  let tags t =
    Hashtbl.fold (fun t _ l -> t::l) t.tags []

  let revision t tag =
    try
      let key = Hashtbl.find t.tags tag in
      match Hashtbl.find t.store key with
      | Revision r -> Some r
      | _          -> None
    with Not_found -> None

  let tag t tag revision =
    let key = sha1 (Revision revision) in
    if Hashtbl.mem t.store key then
      Hashtbl.replace t.tags tag key
    else
      raise Not_found

end

module Vertex = struct
  type t = Types.key
  let compare = Pervasives.compare
  let hash = Hashtbl.hash
  let equal = (=)
end

module Label = struct
  type t = Types.label option
  let default = None
  let compare = Pervasives.compare
end

module Graph = Graph.Imperative.Digraph.ConcreteBidirectionalLabeled(Vertex)(Label)

let mkgraph t ~roots ~sinks =
  let open Types in
  let g = Graph.create () in
  let rec add_one key =
    if List.mem key roots then Graph.add_vertex g key
    else add_all key
  and add_all key =
    if not (Graph.mem_vertex g key) then (
      Graph.add_vertex g key;
      match Low.read t key with
      | None                      -> ()
      | Some (Blob _)       -> ()
      | Some (Revision rev) -> List.iter add_one rev.parents
      | Some (Tree tree)    ->
        List.iter (fun (label,child) ->
            add_one child;
            Graph.add_edge_e g (key, (Some label), child);
          ) tree.children;
        match tree.value with
        | None       -> ()
        | Some child ->
          add_one child;
          Graph.add_edge g key child
    )
  in
  List.iter add_one sinks;
  g

module Remote: Database.REMOTE with module T = Types = struct

  module T = Types
  open T

  let discover t keys tags =
    let sinks = List.fold_left (fun sinks tag ->
        try Hashtbl.find t.tags tag :: sinks
        with Not_found -> sinks
      ) [] tags in
    let graph = mkgraph t ~roots:keys ~sinks in
    let new_keys = ref [] in
    Graph.iter_vertex (fun rev -> new_keys := rev :: !new_keys) graph;
    !new_keys

  let pull t keys =
    List.fold_left (fun values k ->
        match Low.read t k with
        | None   -> values
        | Some v -> v :: values
      ) [] keys

  let push t values =
    List.iter (fun v ->
        let _key = Low.write t in ()
      ) values

  let watch _ = failwith "TODO"

end

open Types

let create () = {
  store = Hashtbl.create 1024;
  tags  = Hashtbl.create 64;
}

let save_file t file =
  Printf.printf "save_file: %s\n%!" file;
  let ic = open_in file in
  let n = in_channel_length ic in
  let str = String.create n in
  really_input ic str 0 n;
  close_in ic;
  let key = Low.write t (Blob (B str)) in
  let leaf = Tree.leaf key in
  Low.write t (Tree leaf)

let rec save_dir t ?(exclude=[]) dir =
  Printf.printf "save_dir: %s\n%!" dir;
  let files = Array.to_list (Sys.readdir dir) in
  let files = List.filter (fun f -> not (List.mem f exclude)) files in
  let files = List.map (Filename.concat dir) files in
  let dirs, files = List.partition Sys.is_directory files in
  let files = List.map (fun f -> L (Filename.basename f), save_file t f) files in
  let dirs = List.map (fun d -> L (Filename.basename d), save_dir t d) dirs in
  let tree = {
    value    = None;
    children = List.sort compare (files @ dirs);
  } in
  Low.write t (Tree tree)