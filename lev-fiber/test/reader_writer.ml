open! Stdune
open Fiber.O
open Lev_fiber

let%expect_test "pipe" =
  let run () =
    let* input, output = Io.pipe ~cloexec:true () in
    let write () =
      let+ () =
        Io.with_write output ~f:(fun writer ->
            Io.Writer.add_string writer "foobar";
            Io.Writer.flush writer)
      in
      Io.close output;
      printfn "writer: finished"
    in
    let read () =
      let+ contents = Io.with_read input ~f:Io.Reader.to_string in
      printfn "read: %S" contents;
      Io.close input
    in
    Fiber.fork_and_join_unit read write
  in
  let print_errors f () =
    Fiber.with_error_handler
      ~on_error:(fun exn ->
        Format.eprintf "%a@." Exn_with_backtrace.pp_uncaught exn;
        Exn_with_backtrace.reraise exn)
      f
  in
  Lev_fiber.run (Lev.Loop.create ()) ~f:(print_errors run);
  [%expect {|
    writer: finished
    read: "foobar" |}]

let%expect_test "write with resize" =
  let run () =
    let* input, output = Io.pipe ~cloexec:true () in
    let len = 6120 in
    let write () =
      let+ () =
        Io.with_write output ~f:(fun writer ->
            Io.Writer.add_string writer (String.make len '1');
            Io.Writer.flush writer)
      in
      Io.close output;
      printfn "writer: finished"
    in
    let read () =
      let+ contents = Io.with_read input ~f:Io.Reader.to_string in
      let len' = String.length contents in
      printfn "read: %d length" len';
      assert (len = len');
      Io.close input
    in
    Fiber.fork_and_join_unit read write
  in
  let print_errors f () =
    Fiber.with_error_handler
      ~on_error:(fun exn ->
        Format.eprintf "%a@." Exn_with_backtrace.pp_uncaught exn;
        Exn_with_backtrace.reraise exn)
      f
  in
  Lev_fiber.run (Lev.Loop.create ()) ~f:(print_errors run);
  [%expect {|
    writer: finished
    read: 6120 length |}]

let%expect_test "blocking pipe" =
  let fdr, fdw = Unix.pipe ~cloexec:true () in
  let run () =
    let* r = Io.create fdr `Blocking Input in
    let* w = Io.create fdw `Blocking Output in
    let writer () =
      let+ () =
        Io.with_write w ~f:(fun writer ->
            Io.Writer.add_string writer "foo bar baz";
            Io.Writer.flush writer)
      in
      printfn "writer: finished";
      Io.close w
    in
    let reader () =
      let+ read = Io.with_read r ~f:Io.Reader.to_string in
      printfn "read: %S" read;
      Io.close r
    in
    Fiber.fork_and_join_unit reader writer
  in
  Lev_fiber.run (Lev.Loop.create ()) ~f:run;
  [%expect {|
    writer: finished
    read: "foo bar baz" |}]

let with_pipe_test output f =
  let run () =
    let* ic, oc = Io.pipe ~cloexec:true () in
    let writer () =
      let+ () =
        Io.with_write oc ~f:(fun writer ->
            let len_output = String.length output in
            let rec loop pos =
              if pos = len_output then Fiber.return ()
              else
                let available = Io.Writer.available writer in
                if available = 0 then
                  let* () = Io.Writer.flush writer in
                  loop pos
                else
                  let len = min available (len_output - pos) in
                  Io.Writer.add_substring writer output ~pos ~len;
                  loop (pos + len)
            in
            let* () = loop 0 in
            Io.Writer.flush writer)
      in
      Io.close oc
    in
    Fiber.fork_and_join_unit
      (fun () ->
        let+ () = f ic in
        Io.close ic)
      writer
  in
  Lev_fiber.run (Lev.Loop.default ()) ~f:run

let%expect_test "read lines" =
  with_pipe_test "foo\nbar\r\n\nbaz\r\r\neof" (fun r ->
      Io.with_read r
        ~f:
          (let rec loop reader =
             let* res = Io.Reader.read_line reader in
             match res with
             | Ok line ->
                 printfn "line: %S" line;
                 loop reader
             | Error (`Partial_eof s) ->
                 printfn "eof: %S" s;
                 Fiber.return ()
           in
           loop));
  [%expect
    {|
    line: "foo"
    line: "bar"
    line: ""
    line: "baz\r"
    eof: "eof" |}]

let%expect_test "read exactly - sufficient" =
  let len = 6 in
  with_pipe_test "foobarbaz" (fun r ->
      Io.with_read r ~f:(fun reader ->
          let+ res = Io.Reader.read_exactly reader len in
          match res with
          | Error (`Partial_eof s) -> printfn "eof: %S" s
          | Ok s ->
              assert (String.length s = len);
              printfn "success: %S\n" s));
  [%expect {| success: "foobar" |}]

let%expect_test "read exactly - insufficient" =
  let str = "foobarbaz" in
  let len = String.length str + 10 in
  with_pipe_test str (fun r ->
      Io.with_read r ~f:(fun reader ->
          let+ res = Io.Reader.read_exactly reader len in
          match res with
          | Error (`Partial_eof s) -> printfn "eof: %S" s
          | Ok s ->
              assert (String.length s = len);
              printfn "success: %S\n" s));
  [%expect {| eof: "foobarbaz" |}]
