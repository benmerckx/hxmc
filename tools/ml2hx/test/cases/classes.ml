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
