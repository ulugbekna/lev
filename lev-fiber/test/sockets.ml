open! Stdune
open Fiber.O
open Lev_fiber

let%expect_test "server & client" =
  let path = "levfiber.sock" in
  (try Unix.unlink path with Unix.Unix_error _ -> ());
  let sockaddr = Unix.ADDR_UNIX path in
  let domain = Unix.domain_of_sockaddr sockaddr in
  let socket () = Unix.socket ~cloexec:true domain Unix.SOCK_STREAM 0 in
  let run () =
    let ready_client = Fiber.Ivar.create () in
    let server () =
      print_endline "server: starting";
      let fd = socket () in
      Unix.setsockopt fd Unix.SO_REUSEADDR true;
      let* server = Socket.Server.create fd sockaddr ~backlog:10 in
      print_endline "server: created";
      let* () = Fiber.Ivar.fill ready_client () in
      print_endline "server: serving";
      Socket.Server.serve server ~f:(fun session ->
          let* i, o = Socket.Server.Session.io session in
          print_endline "server: client connected";
          let* contents = Io.with_read i ~f:Io.Reader.to_string in
          printfn "server: received %S" contents;
          Io.close i;
          let* () =
            Io.with_write o ~f:(fun w ->
                Io.Writer.add_string w "pong";
                Io.Writer.flush w)
          in
          Io.close o;
          Socket.Server.close server)
    in
    let client () =
      let* () = Fiber.Ivar.read ready_client in
      let fd = socket () in
      print_endline "client: starting";
      let* () = Socket.connect fd sockaddr in
      print_endline "client: successfully connected";
      let* i, o = Io.create_rw fd `Non_blocking in
      let* () =
        Io.with_write o ~f:(fun w ->
            Io.Writer.add_string w "ping";
            Io.Writer.flush w)
      in
      Unix.shutdown fd SHUTDOWN_SEND;
      Io.close o;
      let+ result = Io.with_read i ~f:Io.Reader.to_string in
      printfn "client: received %S" result;
      Io.close i
    in
    Fiber.fork_and_join_unit client server
  in
  Lev_fiber.run (Lev.Loop.create ()) ~f:run;
  [%expect
    {|
    server: starting
    server: created
    server: serving
    client: starting
    client: successfully connected
    server: client connected
    server: received "ping"
    client: received "pong" |}]
