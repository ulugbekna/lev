open Stdune
open Fiber.O
module Timer = Lev_fiber.Timer
module Wheel = Timer.Wheel

let%expect_test "sleep" =
  Lev_fiber.run (Lev.Loop.create ()) ~f:(fun () ->
      print_endline "sleep";
      let+ () = Lev_fiber.Timer.sleepf 0.1 in
      print_endline "awake");
  [%expect {|
    sleep
    awake |}]

let%expect_test "timer wheel start/stop" =
  Lev_fiber.run (Lev.Loop.create ()) ~f:(fun () ->
      let* wheel = Wheel.create ~delay:10. in
      Fiber.fork_and_join_unit
        (fun () ->
          print_endline "wheel: run";
          Wheel.run wheel)
        (fun () ->
          print_endline "wheel: stop";
          Wheel.stop wheel));
  [%expect {|
    wheel: run
    wheel: stop |}]

let%expect_test "timer wheel cancellation" =
  Lev_fiber.run (Lev.Loop.create ()) ~f:(fun () ->
      let* wheel = Wheel.create ~delay:10. in
      Fiber.fork_and_join_unit
        (fun () ->
          let* task = Wheel.task wheel in
          let* () = Wheel.cancel task in
          let* result = Wheel.await task in
          match result with
          | `Ok -> assert false
          | `Cancelled ->
              print_endline "cancellation succeeded";
              Wheel.stop wheel)
        (fun () ->
          print_endline "wheel: stop";
          Wheel.run wheel));
  [%expect {|
    cancellation succeeded
    wheel: stop |}]

let%expect_test "timer wheel cancellation" =
  Lev_fiber.run (Lev.Loop.create ()) ~f:(fun () ->
      let delay = 0.3 in
      let sleep () = Timer.sleepf (delay /. 2.) in
      let* wheel = Wheel.create ~delay in
      let pool = Fiber.Pool.create () in
      Fiber.fork_and_join_unit
        (fun () ->
          let await t n =
            let+ t = Wheel.await t in
            match t with
            | `Ok -> printfn "%i finished" n
            | `Cancelled -> assert false
          in
          let* t1 = Wheel.task wheel in
          let* () = Fiber.Pool.task pool ~f:(fun () -> await t1 1) in
          let* t2 =
            let* () = sleep () in
            Wheel.task wheel
          in
          let* () = Fiber.Pool.task pool ~f:(fun () -> await t2 2) in
          let* () = Fiber.Pool.stop pool in
          let+ () = sleep () in
          Wheel.reset t1)
        (fun () ->
          print_endline "wheel: run";
          Fiber.fork_and_join_unit
            (fun () ->
              let* () = Fiber.Pool.run pool in
              Wheel.stop wheel)
            (fun () -> Wheel.run wheel)));
  [%expect {|
    wheel: run
    2 finished
    1 finished |}]

let%expect_test "wheel - stopping with running timers" =
  Lev_fiber.run (Lev.Loop.create ()) ~f:(fun () ->
      let* wheel = Wheel.create ~delay:1.0 in
      Fiber.fork_and_join_unit
        (fun () ->
          print_endline "wheel: run";
          Wheel.run wheel)
        (fun () ->
          printfn "creating a task";
          let* task = Wheel.task wheel in
          printfn "stopping the wheel";
          let* () = Wheel.stop wheel in
          let+ res = Wheel.await task in
          match res with
          | `Ok -> assert false
          | `Cancelled -> printfn "timer cancelled"));
  [%expect
    {|
    wheel: run
    creating a task
    stopping the wheel
    timer cancelled |}]
