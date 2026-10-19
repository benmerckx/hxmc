(* ml2hx replacement of thread-local-storage's thread_local_storage.ml (MIT,
   see its repository): the same module, with each thread's slots in a table
   by thread id instead of a field of Thread.t's block reached with
   Obj.magic. (tools/ml2hx/README.md, Replacements) *)
(* original idea:
   https://discuss.ocaml.org/t/a-hack-to-implement-efficient-tls-thread-local-storage/13264 *)


type 'a t = int
(** Unique index for this TLS slot. *)

let tls_length index =
  let ceil_pow_2_minus_1 (n : int) : int =
    let n = n lor (n lsr 1) in
    let n = n lor (n lsr 2) in
    let n = n lor (n lsr 4) in
    let n = n lor (n lsr 8) in
    let n = n lor (n lsr 16) in
    if Sys.int_size > 32 then
      n lor (n lsr 32)
    else
      n
  in
  let size = ceil_pow_2_minus_1 (index + 1) in
  assert (size > index);
  size

(** Counter used to allocate new keys *)
let counter = Atomic.make 0

(** Value used to detect a TLS slot that was not initialized yet.
    Because [counter] is private and lives forever, no other
    object the user can see will have the same address. *)
let sentinel_value_for_uninit_tls : Obj.t = Obj.repr counter

external max_wosize : unit -> int = "caml_sys_const_max_wosize"

let max_word_size = max_wosize ()

let create () : _ t =
  let index = Atomic.fetch_and_add counter 1 in
  if tls_length index <= max_word_size then
    index
  else (
    (* Some platforms have a small max word size. *)
    ignore (Atomic.fetch_and_add counter (-1));
    failwith "Thread_local_storage.create: out of TLS slots"
  )

(* Each thread's slots, by thread id (instead of a field of Thread.t's
   block reached with Obj.magic). *)
let tables : (int, Obj.t array) Hashtbl.t = Hashtbl.create 16
let tables_lock = Mutex.create ()

let[@inline] own_tls () =
  let id = Thread.id (Thread.self ()) in
  Mutex.lock tables_lock;
  let tls = Hashtbl.find_opt tables id in
  Mutex.unlock tables_lock;
  tls

let[@inline] get_raw index : Obj.t =
  match own_tls () with
  | Some tls when index < Array.length tls -> Array.unsafe_get tls index
  | _ -> sentinel_value_for_uninit_tls

exception Not_set

let[@inline] get_exn slot =
  let v = get_raw slot in
  if v != sentinel_value_for_uninit_tls then
    Obj.obj v
  else
    raise_notrace Not_set

let[@inline] get_opt slot =
  let v = get_raw slot in
  if v != sentinel_value_for_uninit_tls then
    Some (Obj.obj v)
  else
    None

(** Allocating and setting *)

(** Grow the array so that [index] is valid. *)
let grow (old : Obj.t array) (index : int) : Obj.t array =
  let new_length = tls_length index in
  let new_ = Array.make new_length sentinel_value_for_uninit_tls in
  Array.blit old 0 new_ 0 (Array.length old);
  new_

let get_tls_with_capacity index : Obj.t array =
  let store new_tls =
    Mutex.lock tables_lock;
    Hashtbl.replace tables (Thread.id (Thread.self ())) new_tls;
    Mutex.unlock tables_lock;
    new_tls
  in
  match own_tls () with
  | None -> store (grow [||] index)
  | Some tls -> if index < Array.length tls then tls else store (grow tls index)

let[@inline] set slot value : unit =
  let tls = get_tls_with_capacity slot in
  Array.unsafe_set tls slot (Obj.repr (Sys.opaque_identity value))

let[@inline] get_default ~default slot =
  let v = get_raw slot in
  if v != sentinel_value_for_uninit_tls then
    Obj.obj v
  else (
    let v = default () in
    set slot v;
    v
  )
