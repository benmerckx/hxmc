module type SHOW = sig
  val name : string
  val show : int -> string
end
module Dec : SHOW = struct let name = "dec" let show = string_of_int end
module Hex : SHOW = struct let name = "hex" let show = Printf.sprintf "%x" end
let pick b = if b then (module Dec : SHOW) else (module Hex : SHOW)
module Chosen = (val pick (Array.length Sys.argv > 5))
let () = print_endline (Chosen.name ^ " " ^ Chosen.show 255)
let () =
  List.iter (fun m -> let module M = (val m : SHOW) in print_endline (M.name ^ ":" ^ M.show 10)) [pick true; pick false]
