(* Classes: parameters, class-level lets, instance variables, initializers,
   inheritance, virtual methods, super calls, self calls, method arities. *)
class virtual base (n : int) =
  let doubled = n * 2 in
  object (self)
    val mutable count = doubled
    method virtual name : string
    method incr d = count <- count + d; self#get
    method get = count
    method add a b = a + b + count
    initializer Printf.printf "init %d\n" count
  end

class child = object (self)
  inherit base 3 as super
  method name = "child"
  method! get = super#get * 10
  method describe = Printf.sprintf "%s:%d" self#name self#get
end

let use (o : base) = o#incr 4
let named (o : #base) = o#name

let () =
  let c = new child in
  Printf.printf "%d\n" (use (c :> base));
  Printf.printf "%s %s %d\n" (named c) c#describe (c#add 1 2);
  let adder = c#add 100 in
  Printf.printf "%d\n" (adder 5)

(* new typed as the ancestor, parameters used by inherit, abbreviations of
   class types, recursive structural object types *)
class virtual vbase (name : string) = object
  method name = name
  method virtual clone : vbase
end
class leaf (name : string) (n : int) = object
  inherit vbase (name ^ string_of_int n)
  method clone = new leaf name (n + 1)
end
type t = leaf
let show (x : t) = Printf.printf "%s %s\n" x#name ((x#clone)#clone)#name
let () = show (new leaf "a" 1)
let rec count (o : < next : 'a option; v : int > as 'a) =
  match o#next with None -> o#v | Some p -> o#v + count p
let () =
  let last : (< next : 'a option; v : int > as 'a) = object method next = None method v = 3 end in
  let first = object method next = Some last method v = 4 end in
  Printf.printf "%d\n" (count first)

(* functions over open object types *)
let names l = List.map (fun o -> o#name) l
let () =
  print_endline (String.concat "," (names [new leaf "p" 1; new leaf "q" 2]));
  let rec total = function [] -> 0 | o :: r -> o#v + total r in
  Printf.printf "%d\n" (total [object method v = 1 end; object method v = 2 end])
class counter = object
  val n = 0
  val label = "c"
  method n = n
  method label = label
  method bump = {< n = n + 1 >}
end
let () =
  let a = new counter in
  let b = a#bump#bump in
  Printf.printf "%d %d %s %b\n" a#n b#n b#label (a == b)
class state = object
  val mutable inside = false
  method enter = let old = inside in inside <- true; (fun () -> inside <- old)
  method inside = inside
end
let () =
  let s = new state in
  let restore = s#enter in
  let during = s#inside in
  restore ();
  Printf.printf "%b %b\n" during s#inside;
  let o = object val mutable n = 0 method tick = n <- n + 1; (fun k -> n + k) method n = n end in
  let f = o#tick in
  Printf.printf "%d %d\n" o#n (f 10)
