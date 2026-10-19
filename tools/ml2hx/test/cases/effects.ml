(* Deep handlers that resume last (as the compiler's hxbWriter uses them),
   extensible types with parameters. *)
open Effect
open Effect.Deep

type _ Effect.t += Ask : string -> int Effect.t
type _ Effect.t += Log : string -> unit Effect.t

let compute () =
  let a = perform (Ask "a") in
  perform (Log (Printf.sprintf "a=%d" a));
  let b = perform (Ask "b") in
  a + b

let with_answers f =
  try_with f () {
    effc = (fun (type c) (eff : c Effect.t) ->
      match eff with
      | Ask s -> Some (fun (k : (c, _) continuation) -> continue k (String.length s * 10))
      | _ -> None)
  }

let with_log f =
  try_with f () {
    effc = (fun (type c) (eff : c Effect.t) ->
      match eff with
      | Log s -> Some (fun (k : (c, _) continuation) -> print_endline ("log: " ^ s); continue k ())
      | _ -> None)
  }

let () = Printf.printf "%d\n" (with_log (fun () -> with_answers compute))
let () =
  match compute () with
  | _ -> print_endline "no"
  | exception Effect.Unhandled _ -> print_endline "unhandled"

type 'a box = ..
type 'a box += Int_box of int | Any_box of 'a
let show : type a. a box -> string = function
  | Int_box n -> string_of_int n
  | Any_box _ -> "any"
  | _ -> "?"
let () = print_endline (show (Int_box 3) ^ show (Any_box 'c'))
