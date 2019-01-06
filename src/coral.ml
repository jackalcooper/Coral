open Ast
open Sast
open Utilities
open Interpret

let () = Sys.set_signal Sys.sigint
  (Sys.Signal_handle 
    (fun _signum ->
      try Sys.remove "source.ll"; Sys.remove "source.s"; exit 0 with _ -> exit 0))

(* boolean flags used to handle command line arguments *)
let debug = ref false
let run = ref true

(* file path flags to handle compilation from a file *)
let fpath = ref ""
let fpath_set = ref false

(* exceptions flag enables or disables runtime exceptions *)
let exceptions = ref true

(* assembly flag specifies whether to generate the .s assembly file instead of an executable *)
let assembly = ref false

(* emit_llvm flag specifies whether to generate the LLVM IR file instead of an executable *)
let emit_llvm = ref false

(* executable_name is name of executable file *)
let executable_name = ref ""

(* usage: usage message for function calls *)
let usage = "usage: " ^ Sys.argv.(0) ^ " [file] [-d] [-r]"

(* function used to handle command line arguments *)
let speclist =
[
  ( "[file]", Arg.String (fun foo -> ()), ": compile from a file instead of the default interpreter");
  ( "-d", Arg.Set debug, ": print debugging information at compile time");
  ( "-S", Arg.Set assembly, ": generate x86 assembly output instead of executable");
  ( "-emit-llvm", Arg.Set emit_llvm, ": generate llvm ir output instead of compiling");
  ( "-o", Arg.Set_string executable_name, ": specify the name of the generated executable or assembly file");
  ( "-no-compile", Arg.Clear run, ": run semantic checking on a file instead of compiling or running it");
  ( "-no-except", Arg.Clear exceptions, ": run compilation on a file without runtime checks");
]

(* this is a complicated function. it takes the lexed buffer, runs it through the tokenize parser in order to 
extract a list of tokens. once this list has been extracted, we iterate over it to check if the indentations 
are correct, and to insert Parser.INDENT and Parser.DEDENT tokens as desired. We also sanitize it using the 
above methods *)

let indent_done = ref false
let tabwidth = 8

let indent tokens base current =
    let rec aux curr s out stack = match s with
    | [] -> (curr, stack, List.rev out)
    | Parser.CEND :: (Parser.EOL :: t) -> aux 0 t out stack;
    | Parser.TAB :: t -> if not !indent_done then aux (curr + tabwidth) t out stack else aux curr t out stack
    | Parser.SPACE :: t -> if not !indent_done then aux (curr + 1) t out stack else aux curr t out stack
    | Parser.EOL :: t -> indent_done := false; aux 0 t (Parser.SEP :: out) stack 
    | a :: t -> indent_done := true;
      if Stack.top stack = curr then aux curr t (a::out) stack (* do nothing, continue with next character *)
      
      else if (curr < Stack.top stack) then 
        let rec dedent out curr stack = 
          if curr < (Stack.top stack) then let _ = Stack.pop stack in dedent (Parser.DEDENT :: out) curr stack
          else (out, stack)

        in let (tokens, stacK) = dedent [] curr stack in 
        if Stack.top stack = curr then aux curr (a :: t) (tokens @ out) stack (* if dedented, pop off the stack and add a DEDENT token *)
        else raise (Failure "SSyntaxError: invalid indentation detected!");

      else if (curr > Stack.top stack) then 
        let _ = Stack.push curr stack in aux curr (a :: t) (Parser.INDENT :: out) stack (* if indented by one, push onto the stack and add an indent token *)
      else raise (Failure "SSyntaxError: invalid indentation detected!"); (* else raise an error *)
  in aux current tokens [] base

(* search_env_opt: search the given environment variable for valid search paths 
and search these for files of the form path/name, return channel if exists, None otherwise *)

let search_env_opt env name = 
  if not (Filename.is_relative name) 
    then if Sys.file_exists name 
      then Some name 
      else None
  else let env_string = Sys.getenv_opt env in
    match env_string with
      | None -> if Sys.file_exists name then Some name else None
      | Some x -> let paths = String.split_on_char ':' x in
          let curr = List.find_opt (fun path -> Sys.file_exists (Filename.concat path name)) paths in
          match curr with
            | None -> if Sys.file_exists name then Some name else None
            | Some path -> Some (Filename.concat path name)

(* get_ast: loads the ast from a given path if possible, lexing and parsing the file found 
at that path. used for the file-based compiler, not the interpreter, which requires different behavior *)

let get_ast path = 
  let chan = open_in path
  in let base = Stack.create() in let _ = Stack.push 0 base in

  let rec read current stack = (* logic of the interpreter *)
    try 
      let line = (input_line chan) ^ "\n" in (* add newline for parser, gets stripped by input_line *)
      if String.length line = 1 then (read current stack)
      else let lexbuf = (Lexing.from_string line) in
      let temp = (Parser.tokenize Scanner.token) lexbuf in (* char buffer to token list *)
      let (curr, stack, formatted) = indent temp stack current in
      formatted @ (read curr stack)
   with End_of_file -> close_in chan; Array.make (Stack.length stack - 1) Parser.DEDENT |> Array.to_list
  in let formatted = ref (read 0 base) in
  let _ = if !debug then (Printf.printf "Lexer: ["; (List.iter (Printf.printf "%s ") (List.map print !formatted); print_endline "]\n")) in (* print debug messages *)

  let token lexbuf = (* hack I found online to convert lexbuf list to a map from lexbuf to Parser.token, needed for Ocamlyacc *)
  match !formatted with 
    | []     -> Parser.EOF 
    | h :: t -> formatted := t ; h in

  let program = Parser.program token (Lexing.from_string "") in program

(* ast_from_path: takes a given filename and searches for files with that name in any 
directory contained in the $PATH env variable. This calls search_env_opt on "PATH" internally.
Raises an error if the path is not found, unlike search_env_opt which returns None *)

let ast_from_path fname = 
  let path = search_env_opt "PATH" fname in
  let name = match path with
    | None -> raise (Failure ("FileNotFoundError: unable to open file " ^ fname)) 
    | Some x -> x
  in get_ast name

(* fix_extension: checks if a given file ends with the .cl extension. If so, return
the original path. If not, append .cl to it. *)


let fix_extension file = match Filename.check_suffix file ".cl" with
  | true -> file
  | false -> file ^ ".cl"

(* parse_imports: this function takes an ast and traverses it, replacing import statements with
the full ast of the specified file. The behavior of this function follows Python. First the $PATH
directories are searched, and then the local directory is searched. If the file is found in neither
of these places, it throws an error. *)

let parse_imports li =
  let rec aux out = function
    | [] -> List.rev out
    | Import(name) :: t -> 
        let program = ast_from_path (fix_extension name) in
        aux ((List.rev program) @ out) t
    | Func(a, b, s1) :: t -> let updated = aux [] (from_block s1) in aux (Func(a, b, Block(updated)) :: out) t
    | Block(s1) :: t -> let updated = aux [] s1 in aux (Block(updated) :: out) t
    | If(a, s1, s2) :: t -> let u1 = aux [] (from_block s1) in let u2 = aux [] (from_block s2) in aux (If(a, Block(u1), Block(u2)) :: out) t
    | For(a, b, s1) :: t -> let updated = aux [] (from_block s1) in aux (For(a, b, Block(updated)) :: out) t
    | While(a, s1) :: t -> let updated = aux [] (from_block s1) in aux (While(a, Block(updated)) :: out) t
    | a :: t -> aux (a :: out) t 
  in aux [] li

(* process_output_to_list: [copied from a Stack Overflow forum post. Runs a Unix command in a subprocess,
captures the output, and stores earch result in a list to be printed or used further. Used for running
bash scripts to compile the program *)

let process_output_to_list = fun command -> 
  let chan = Unix.open_process_in command in
  let res = ref ([] : string list) in
  let rec process_otl_aux () =  
    let e = input_line chan in
    res := e :: !res;
    process_otl_aux() in
  try process_otl_aux ()
  with End_of_file ->
    let stat = Unix.close_process_in chan in (List.rev !res, stat)

let cmd_to_list command =
  let (l, _) = process_output_to_list command in l

(* strip_stmt: this function strips Type(x) and Print(x) stmts from the ast of past 
function calls when used with the interpreter. The interpreter currently works by appending
past parsed asts to the current one, and by default past print statements will be called each time
the interpreter is run on any input statement. Note that this excludes functions because they may
contain desired function calls. There is no good way around this with the current model. *)

let rec strip_stmt = function 
  | Type(x) | Print(x) -> Nop
  | If(a, b, c) -> If(a, strip_stmt b, strip_stmt c)
  | While(a, b) -> While(a, strip_stmt b)
  | For(a, b, c) -> For(a, b, strip_stmt c)
  | Range(a, b, c) -> Range(a, b, strip_stmt c)
  | Block(x) -> Block(strip_print x)
  | _ as x -> x

and strip_print ast = List.rev (List.fold_left (fun acc x -> (strip_stmt x) :: acc) [] ast)

(* codegen: command to run codegen to a generated sast, save it to a file (source.ll), compile and
evaluate it, and return the output *)

let codegen sast fname = 
  let output = 
  (try 
    let m = Codegen.translate sast !exceptions in
    Llvm_analysis.assert_valid_module m;

    let llvm_name = (match String.length !executable_name with
      | 0 -> fname ^ ".ll"
      | _ -> !executable_name ^ ".ll") in

    let oc = open_out llvm_name in
    Printf.fprintf oc "%s\n" (Llvm.string_of_llmodule m); close_out oc;

    let assembly_name = (match String.length !executable_name with
      | 0 -> fname ^ ".s"
      | _ -> !executable_name ^ ".s") in

    let executable_name = (match String.length !executable_name with
      | 0 -> "a.out"
      | _ -> !executable_name) in
    
    let output = match (!emit_llvm, !assembly) with
      | (true, _) -> [] 
      | (false, true) -> 
        let output = cmd_to_list ("llc " ^ llvm_name ^ " -o " ^ assembly_name) in
        Sys.remove llvm_name; output
      | (false, false) -> 
        let output = cmd_to_list ("llc " ^ llvm_name ^ " -o " ^ assembly_name ^ " && gcc " ^ assembly_name ^ " -o " ^ executable_name ^ " && ./" ^ executable_name) in
        Sys.remove llvm_name; Sys.remove assembly_name; output
    
    in output
  with
    | Not_found -> raise (Failure ("CodegenError: variable not found!"))
  ) in output


(* this is the main function loop for the interpreter. We lex the input from stdin,
convert it to a list of Parser.token, apply the appropriate indentation corrections,
check to make sure we are at 0 indentation level, print more dots otherwise, and then
compute the correct value and repeat. *)

let is_empty tokens = match tokens with
  | Parser.NOP :: [Parser.EOL] -> true
  | _ -> false

let block = ref false

let rec from_console map past run = 
  try 
    Printf.printf ">>> "; flush stdout;
    let base = Stack.create() in let _ = Stack.push 0 base in

    let rec read current stack = (* logic of the interpreter *)
        let line = (input_line stdin) ^ "\n" in (* add newline for parser, gets stripped by input_line *)
        let lexbuf = (Lexing.from_string line) in
        let temp = (Parser.tokenize Scanner.token) lexbuf in (* char buffer to token list *)
        let (curr, stack, formatted) = indent temp stack current in 
        if Filename.check_suffix (String.trim line) ":" then block := true
        else if Stack.top stack = 0 then block := false;
        if is_empty temp || not !block then formatted else
        (Printf.printf "... "; flush stdout;
        formatted @ (read curr stack))

    in let formatted = ref (read 0 base) in
    let _ = if !debug then (Printf.printf "Lexer: ["; (List.iter (Printf.printf "%s ") (List.map print !formatted); print_endline "]\n")) in (* print debug messages *)

    let token lexbuf = (* hack I found online to convert lexbuf list to a map from lexbuf to Parser.token, needed for Ocamlyacc *)
    match !formatted with 
      | []     -> Parser.EOF 
      | h :: t -> formatted := t ; h in

    let program = 
      if run then ((strip_print past) @ (Parser.program token (Lexing.from_string "")))
      else (Parser.program token (Lexing.from_string "")) in

    let imported_program = parse_imports program in

    let (sast, map') = (Semant.check map [] [] { forloop = false; cond = false; noeval = false; stack = TypeMap.empty; } imported_program) in (* temporarily here to check validity of SAST *)
    let _ = if !debug then print_endline ("Parser: \n\n" ^ (string_of_sprogram sast)) in (* print debug messages *)
    
    if run then
      let output = codegen sast "source" in
      List.iter print_endline output; flush stdout; 
      from_console map imported_program run

    else flush stdout; from_console map' [] false

  with
    | Not_found -> Printf.printf "NotFoundError: unknown error\n"; from_console map past run
    | Parsing.Parse_error -> Printf.printf "SyntaxError: invalid syntax\n"; flush stdout; from_console map past run
    | Failure explanation -> Printf.printf "%s\n" explanation; flush stdout; from_console map past run
    | Runtime explanation -> Printf.printf "%s\n" explanation; flush stdout; from_console map past run

(* this is the main function loop for the file parser. We lex the input from a given file,
convert it to a list of Parser.token, apply the appropriate indentation corrections,
dedent to the zero level as needed, and then compute the correct value *)

let rec from_file map fname run = (* todo combine with loop *)
  try
    let original_path = Sys.getcwd () in
    let program = Sys.chdir (Filename.dirname fname); ast_from_path (Filename.basename fname) in
    let imported_program = parse_imports program in

    let (sast, map') = (Semant.check map [] [] { forloop = false; cond = false; noeval = false; stack = TypeMap.empty; } imported_program) in (* temporarily here to check validity of SAST *)
    let () = if !debug then print_endline ("Parser: \n\n" ^ (string_of_sprogram sast)); flush stdout; in (* print debug messages *)
    let () = Sys.chdir original_path in

    if run then 
      let output = codegen sast (Filename.remove_extension (Filename.basename fname)) in
      List.iter print_endline output; flush stdout;

  with
    | Not_found -> Printf.printf "NotFoundError: unknown error!\n"; flush stdout
    | Parsing.Parse_error -> Printf.printf "ParseError: invalid syntax!\n"; flush stdout
    | Failure explanation -> Printf.printf "%s\n" explanation; flush stdout

(* Coral main interpreter loop. Parses command line arguments, including a single
anonymous argument (file path) and runs either the interpreter or the from_file compiler *)

let () =
  Arg.parse speclist (fun path -> if not !fpath_set then fpath := path; fpath_set := true; ) usage; (* parse command line arguments *)
  let emptymap = StringMap.empty in 

  if !fpath_set then from_file emptymap !fpath !run
  else
  ( 
    Printf.printf "Welcome to the Coral programming language!\n\n"; flush stdout; 
    try 
      from_console emptymap [] !run 
    with Scanner.Eof -> exit 0
  )

