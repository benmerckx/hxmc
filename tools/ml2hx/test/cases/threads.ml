(* native: threads under one master lock: mutexes, conditions, join, Event,
   domains (the stage0 interpreter, WebAssembly, has no threads) *)
let () =
  let m = Mutex.create () and c = Condition.create () in
  let queue = Queue.create () and finished = ref 0 in
  let producer n = for i = 1 to 5 do Mutex.lock m; Queue.push (n * 10 + i) queue; Condition.signal c; Mutex.unlock m; Thread.yield () done in
  let consumer () =
    let total = ref 0 and got = ref 0 in
    while !got < 10 do
      Mutex.lock m;
      while Queue.is_empty queue do Condition.wait c m done;
      total := !total + Queue.pop queue; incr got;
      Mutex.unlock m
    done;
    Mutex.lock m; finished := !total; Mutex.unlock m in
  let tc = Thread.create consumer () in
  let t1 = Thread.create producer 1 and t2 = Thread.create producer 2 in
  List.iter Thread.join [t1; t2; tc];
  Printf.printf "total %d\n" !finished;
  let ch = Event.new_channel () in
  let t = Thread.create (fun () -> Event.sync (Event.send ch "ping"); Thread.delay 0.01; Event.sync (Event.send ch "pong")) () in
  let a = Event.sync (Event.receive ch) in
  let b = Event.sync (Event.receive ch) in
  Thread.join t;
  Printf.printf "%s %s %b\n" a b (Thread.id (Thread.self ()) = 0);
  (try Mutex.lock m; Mutex.lock m with Sys_error e -> print_endline e);
  Mutex.unlock m;
  let t = Thread.create (fun () -> failwith "boom") () in
  Thread.join t;
  print_endline "done"
let () =
  let k = Domain.DLS.new_key (fun () -> 0) in
  Domain.DLS.set k 5;
  let d = Domain.spawn (fun () -> let before = Domain.DLS.get k in Domain.DLS.set k 7; before + 100) in
  let r = Domain.join d in
  let a = Atomic.make 0 in
  let ds = List.init 3 (fun _ -> Domain.spawn (fun () -> for _ = 1 to 100 do Atomic.incr a done)) in
  List.iter Domain.join ds;
  Printf.printf "%d %d %d\n" r (Domain.DLS.get k) (Atomic.get a)
