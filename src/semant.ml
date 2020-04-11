open Ast
open Sast
open Utilities

(* Semant takes an Abstract Syntax Tree and returns a Syntactically Checked AST with partial type inferrence,
syntax checking, and other features. expr objects are converted to sexpr, and stmt objects are converted
to sstmts. *)

(* needs_cast: checks if a given type needs to be manually cast to another (or if cast can be discarded). throws error if invalid *)

let needs_cast t1 t2 = 
    let except = (Failure ("STypeError: cannot cast operand of typ '" ^ string_of_typ t1 ^ "' to type '" ^ string_of_typ t2 ^ "'")) in
    match t2 with 
    | Dyn | Arr | FuncType | Null | Object -> raise (Failure ("SSyntaxError: Invalid Syntax"))
    | _ -> 
      if t1 = t2 then false
      else match (t1, t2) with
        | (Dyn, _) -> true
        | (Int, Float) | (Float, Int) -> true
        | (_, String) -> true
        | _ -> raise except

(* binop: evaluate types of two binary operations and check if the binary operation is valid.
This currently is quite restrictive and does not permit automatic type casting like in Python.
This may be changed in the future. The commented-out line would allow that feature *)

let binop t1 t2 op = 
  let except = (Failure ("STypeError: unsupported operand type(s) for binary " ^ binop_to_string op ^ ": '" ^ type_to_string t1 ^ "' and '" ^ type_to_string t2 ^ "'")) in
  match (t1, t2) with
  | (Dyn, Dyn) | (Dyn, _) | (_, Dyn) -> Dyn
  | _ -> let same = t1 = t2 in (match op with
    | Add | Sub | Mul | Exp when same && t1 = Int -> Int
    | Add | Sub | Mul | Div | Exp when same && t1 = Float -> Float
    | Add | Sub | Mul | Div | Exp when same && t1 = Bool -> Bool
    | Add when same && t1 = String -> String
    (* | Add | Sub | Mul | Div | Exp when t1 = Int || t1 = FloatArr || t1 = Bool && t2 = Int || t2 = Float || t2 = Bool -> Float *)
    | Less | Leq | Greater | Geq when not same && t1 = String || t2 = String -> raise except
    | Eq | Neq | Less | Leq | Greater | Geq | And | Or when same -> Bool
    | And | Or when same && t1 = Bool -> Bool
    | Mul when is_arr t1 && t2 = Int -> t1
    | Mul when is_arr t2 && t1 = Int -> t2
    | Mul when t1 = String && t2 = Int -> String
    | Mul when t2 = String && t1 = Int -> String
    | Add when same && is_arr t1 -> t1
    | Div when same && t1 = Int -> Int
    | Add | Sub | Mul | Div | Exp when (t1 = Bool && t2 = Int) || (t2 = Bool && t1 = Int) -> Int
    | _ -> raise except
  )

(* unop: evalues the type of a unary operation to check if it is valid. Currently is less restrictive
than binop and this may need to be modified depending on how codegen is implemented. *)

let unop t1 op = match t1 with
  | Dyn -> Dyn
  | _ -> (match op with
    | Neg when t1 = Int || t1 = Float || t1 = Bool -> t1
    | Not -> t1
    | _ -> raise (Failure ("STypeError: unsupported operand type for unary " ^ unop_to_string op ^ ": '" ^ type_to_string t1 ^ "'"))
  )

(* convert: takes the triple tuple returned by exp (type, expression, data) and converts
it to (type, sexpr, data) *)

let convert (t, e, d) = (t, (e, t), d)

(* expr: syntactically check an expression, returning its type, the sexp object, and any relevant data *)
let rec expr the_state x = convert (exp the_state x)

(* exp: evaluate expressions, return their types, a partial sast, and any relevant data (basically just a function AST) *)

and exp the_state = function 
  | Unop(op, e) -> (* parse Unops, making sure the argument and ops have valid type combinations *)
    let (t1, e', _) = expr the_state e in
    let t2 = unop t1 op in (t2, SUnop(op, e'), None)

  | Binop(a, op, b) -> (* parse Binops, making sure the two arguments and ops have valid type combinations *)
    let (t1, e1, _) = expr the_state a in 
    let (t2, e2, _) = expr the_state b in 
    let t3 = binop t1 t2 op in (t3, SBinop(e1, op, e2), None)

  | Var(Bind(x, t)) -> (* parse a Var, throwing an error if they are not found in the global lookup table *)
    if StringMap.mem x the_state.locals then (* if found in locals *)
    if (StringMap.mem x the_state.globals) && the_state.noeval && the_state.func then (Dyn, SVar(x), None) (* we're inside a Func and this is a global *)
    else let (t', typ, data) = StringMap.find x the_state.locals in (typ, SVar(x), data)
    else if the_state.noeval && the_state.func then (* we're inside a Func and this is also potentially a global that will be defined in the future *)
      let () = debug ("noeval set and possible global for " ^ x) in 
      let () = possible_globals := (Bind(x, Dyn)) :: !possible_globals in (Dyn, SVar(x), None) 
    else raise (Failure ("SNameError: name '" ^ x ^ "' is not defined"))

  | Cast(typ, e) ->
      let (t1, e', _) = expr the_state e in
      if needs_cast t1 typ then (typ, SCast(t1, typ, e'), None) (* check if the types can be cast *)
      else let (e'', _) = e' in (t1, e'', None) (* extract expr from sexpr *)

  | Field(obj, field) -> (* TODO expand *)
      let (t, e', _) = expr the_state obj in
      if t <> Dyn && t <> Object then raise (Failure "TypeError: primitive types have no fields (yet)") else
      (t, SField(e', field), None)

  | Method(obj, name, args) -> (* todo expand *)
    let (t, e', data) = expr the_state obj in 
    if t <> Dyn && t <> Object then raise (Failure "TypeError: primitive types have no methods (yet)") else
    let args = List.map (fun e -> let (t, e', _) = expr the_state e in e') args in 
    (Dyn, SMethod(e', name, args), None) 

  | ListAccess(e, x) -> (* parse List access to determine the LHS is a list and the RHS is an int if possible *)
    let (t1, e1, _) = expr the_state e in
    let (t2, e2, _) = expr the_state x in
    if t1 <> Dyn && not (is_arr t1) || t2 <> Int && t2 <> Dyn 
      then raise (Failure (Printf.sprintf "STypeError: invalid types (%s, %s) for list access" (type_to_string t1) (type_to_string t2)))
    else if t1 == String then (String, SListAccess(e1, e2), None)
    else (Dyn, SListAccess(e1, e2), None)

  | ListSlice(e, x1, x2) -> raise (Failure "SNotImplementedError: List Slicing has not been implemented")

  | Lit(x) -> 
    let typ = match x with 
      | IntLit(x) -> Int 
      | BoolLit(x) -> Bool 
      | StringLit(x) -> String
      | FloatLit(x) -> Float
    in (typ, SLit(x), None) (* convert lit to type, return (type, SLit(x)), check if defined in map *)
  
  | List(x) -> (* parse Lists to determine if they have uniform type, evaluate each expression separately *)
    let rec aux typ out = function
      | [] -> (Arr, SList(List.rev out, Arr), None) (* replace Dyn with type_to_array typ to allow type inference on lists *)
      | a :: rest -> 
        let (t, e, _) = expr the_state a in 
        if t = typ then aux typ (e :: out) rest 
        else aux Dyn (e :: out) rest in 
      (match x with
        | a :: rest -> let (t, e, _) = expr the_state a in aux t [e] rest
        | [] -> (Dyn, SList([], Dyn), None) (* TODO: maybe do something with this special case of empty list *)
      ) 

  | Call(exp, args) -> (* parse Call, checking that the LHS is a function, matching arguments and types, evaluating the body *)
    let (t, e, data) = expr the_state exp in
    if t <> Dyn && t <> FuncType (* if it's known not to be a function, throw an error *)
        then raise (Failure ("STypeError: cannot call objects of type " ^ type_to_string t)) else
    
    let the_state = change_state the_state S_func in (* transform state when entering the function *)
    let transforms = make_transforms (globals_to_list the_state.globals) in (* empty in case not in function *)
    
    (* print_endline ("printing transforms " ^ (string_of_sstmt 0 transforms)); *)
   
    (match data with 
      | Some(x) -> 
        (match x with 
          | Func(name, formals, body) -> (* if evaluating the expression returns a function *)
            let param_length = List.length args in
            if List.length formals <> param_length 
            then raise (Failure (Printf.sprintf "SSyntaxError: unexpected number of arguments in function call (expected %d but found %d)" (List.length formals) param_length))

            else let rec handle_args (map, bindout, exprout) bind exp = (* add args to a given map *)
                let data = expr the_state exp in 
                let (t', e', _) = data in 
                let (map', name, inferred_t, explicit_t) = assign map data bind in 
                (map', ((Bind(name, explicit_t)) :: bindout), (e' :: exprout))
            in 
            
            let clear_explicit_types map = StringMap.map (fun (a, b, c) -> (Dyn, b, c)) map in (* ignore dynamic types when not in same scope *)

            let fn_namespace = clear_explicit_types the_state.globals in (* we use this map to allow us to overwrite explicit global types *)
            let (map', bindout, exprout) = (List.fold_left2 handle_args (fn_namespace, [], []) formals args) in (* add args to globals *)
            let (map'', _, _, _) = assign map' (Dyn, (SCall (e, (List.rev exprout), transforms), Dyn), data) name in (* add the function itself to the namespace *)

            let (_, types) = split_sbind bindout in

            if the_state.func && TypeMap.mem (x, types) the_state.stack then let () = debug "recursive callstack return" in (Dyn, SCall(e, (List.rev exprout), transforms), None)
            else let stack' = TypeMap.add (x, types) true the_state.stack in (* check recursive stack *)

            let (map2, block, data, locals) = (stmt {the_state with stack = stack'; func = true; locals = map''; } body) in

            (match data with (* match return type with *)
              | Some (typ2, e', d) -> (* it did return something *)
                  let Bind(n1, btype) = name in 
                  if btype <> Dyn && btype <> typ2 then if typ2 <> Dyn 
                  then raise (Failure (Printf.sprintf "STypeError: invalid return type (expected %s but found %s)" (string_of_typ btype) (string_of_typ typ2))) 
                  else let func = { styp = btype; sfname = n1; sformals = (List.rev bindout); slocals = locals; sbody = block } in 
                    (btype, (SCall(e, (List.rev exprout), SFunc(func))), d) 
                  else let func = { styp = typ2; sfname = n1; sformals = (List.rev bindout); slocals = locals; sbody = block } in (* case where definite return type and Dynamic inferrence still has  bind*)
                  (typ2, (SCall(e, (List.rev exprout), SFunc(func))), d)
              
              | None -> (* function didn't return anything, null function *)
                  let Bind(n1, btype) = name in if btype <> Dyn then
                  raise (Failure (Printf.sprintf "STypeError: invalid return type (expected %s but found None)" (string_of_typ btype))) else
                  let func = { styp = Null; sfname = n1; sformals = (List.rev bindout); slocals = locals; sbody = block } in
                  (Null, (SCall(e, (List.rev exprout), SFunc(func))), None))
          
          | _ -> raise (Failure ("SCriticalFailure: unexpected type encountered internally in Call evaluation"))) (* can be expanded to allow classes in the future *)
      
      | None -> debug ("SWarning: called unknown/undefined function with " ^ (string_of_expr exp) ^ " and noeval is " ^ (string_of_bool the_state.noeval)); (* TODO probably not necessary, may be a problem for recursion *)
          let eout = List.rev (List.fold_left (fun acc e' -> let (_, e', _) = expr the_state e' in e' :: acc) [] args) in
          let transforms = make_transforms (globals_to_list the_state.globals) in (* make_transforms transforms all current globals to dynamics and back for unknown/undefined functions *)
          (Dyn, (SCall(e, eout, transforms)), None)
        )

  | _ as temp -> print_endline ("SNotImplementedError: '" ^ (expr_to_string temp) ^ 
      "' semantic checking not implemented"); (Dyn, SNoexpr, None)

(* assign: function to check if a certain assignment can be performed with inferred/given types, 
does assignment if possible, and returns the name, the infered type, and the explicit type to be checked.

the return type is:

(new map, type needed for locals list, type needed for runtime-checking)

The second bind will generally be dynamic, except when type inferred cannot determine if the
operation is valid and runtime checks must be inserted.

typ is type inferred type of data being assigned. t' is the explicit type previously assigned to the
variable being assigned to. t is the type (optionally) bound to the variable in this assignment.

*)

and assign map data bind =
  let (typ, _, data) = data in  
  let Bind(n, t) = bind in
  if StringMap.mem n map then
  let (t', _, _) = StringMap.find n map in 
    (match typ with
      | Dyn -> (match (t', t) with (* todo deal with the Bind thing *)
        | (Dyn, Dyn) -> let map' = StringMap.add n (Dyn, Dyn, data) map in (map', n, Dyn, Dyn) (*  *)
        | (Dyn, _) -> let map' = StringMap.add n (t, t, data) map in (map', n, t, t) (*  *)
        | (_, Dyn) -> let map' = StringMap.add n (t', t', data) map in (map', n, t', t') (*  *)
        | (_, _) -> let map' = StringMap.add n (t, t, data) map in (map', n, t, t))  (*  *)
      | _ -> (match t' with
        | Dyn -> (match t with 
          | Dyn -> let map' = StringMap.add n (Dyn, typ, data) map in (map', n, typ, Dyn) (*  *)
          | _ when t = typ -> let m' = StringMap.add n (t, t, data) map in (m', n, t, Dyn) (*  *)
          | _ -> raise (Failure (Printf.sprintf "STypeError: expression of type %s cannot be assigned to variable '%s' with explicit type %s" (string_of_typ typ) n (string_of_typ t))))
        | _ -> (match t with
          | Dyn when t' = typ -> let m' = StringMap.add n (t', typ, data) map in (m', n, t', Dyn) (*  *)
          | _ when t = typ -> let m' = StringMap.add n (t, t, data) map in (m', n, t, Dyn) (*  *)
          | _ -> raise (Failure (Printf.sprintf "STypeError: expression of type %s cannot be assigned to variable '%s' with explicit type %s" (string_of_typ typ) n (string_of_typ t'))))))
  else if t = typ 
  then let m' = StringMap.add n (t, t, data) map in (m', n, t, Dyn) (*  *)
  else if t = Dyn then let m' = StringMap.add n (Dyn, typ, data) map in (m', n, typ, Dyn) (*  *)
  else if typ = Dyn then let m' = StringMap.add n (t, t, data) map in (m', n, t, t) (*  *)
  else raise (Failure (Printf.sprintf "STypeError: expression of type %s cannot be assigned to variable '%s' with explicit type %s" (string_of_typ typ) n (string_of_typ t)))


(* makes sure an array type can be assigned to a given variable. used for for loops mostly *)
and check_array the_state e b = 
  let (typ, e', data) = expr the_state e in
  (match typ with
  | String -> assign the_state.locals (typ, e', data) b
  | Arr | Dyn -> assign the_state.locals (Dyn, e', data) b
  | _ -> raise (Failure (Printf.sprintf "STypeError: cannot iterate over type %s in 'for' loop" (string_of_typ typ))))


(* check_func: checks an entire function. 

globals and locals are the globals and locals maps (locals contains all globals).
out is a sstmt list containing the semanting checked stmts.
data is a (typ, e', sstmt) tuple containing return information for the function.
local_vars is a list of sbinds containing the local variables.
stack is a TypeMap containing the function call stack.

TODO distinguish between outer and inner scope return statements to stop evaluating when definitely
returned. *)

and check_func out data local_vars the_state = (function  
  | [] -> ((List.rev out), data, the_state.locals  , List.sort_uniq compare (List.rev local_vars))
  | a :: t -> let (m', value, d, loc) = stmt the_state a in
    let the_state = (change_state the_state (S_setmaps (m', the_state.globals))) in
    (match (data, d) with
      | (None, None) -> check_func (value :: out) None (loc @ local_vars) the_state t
      | (None, _) -> check_func (value :: out) d (loc @ local_vars) the_state t
      | (_, None) -> check_func (value :: out) data (loc @ local_vars) the_state t
      | (_, _) when d = data -> check_func (value :: out) data (loc @ local_vars) the_state t
      | _ -> check_func (value :: out) (Some (Dyn, (SNoexpr, Dyn), None)) (loc @ local_vars) the_state t))

(* match_data: when reconciling branches in a conditional branch, this function
  checks what return types can still be inferred. If both return the same type, 
  that will be preserved. If only one returns, a generic dynamic object will be returned.
  If both return the same object, that will be preserved. If both return None, that will 
  be returned. Used in for, if, and while statements.
*)

and match_data d1 d2 = match d1, d2 with
  | (None, None) -> None
  | (None, _) | (_, None) -> (Some (Dyn, (SNoexpr, Dyn), None))
  | (Some x, Some y) -> 
    if x = y then d1
    else let (t1, _, _) = x and (t2, _, _) = y in 
    (Some ((if t1 = t2 then t1 else Dyn), (SNoexpr, Dyn), None))

(* func_stmt: syntactically checkts statements inside functions. Exists mostly to handle 
  function calls which recurse and to redirect calls to expr to expr. We may be able
  to simplify the code by merging this with stmt, but it will be challenging to do.
*)

and merge_blocks b1 b2 = 
  let SBlock(body1) = b1 in 
  let SBlock(body2) = b2 in 
  SBlock(body1 @ body2)

(* stmt: the regular statement function used for evaluating statements outside of functions. *)

and stmt the_state = function (* evaluates statements, can pass it a func *)
  | Return(e) -> 
      if not the_state.func then raise (Failure ("SSyntaxError: return statement outside of function"))
      else let data = expr the_state e in 
      let (typ, e', d) = data in 
      (the_state.locals, SReturn(e'), (Some data), [])

  | Block(s) -> 
      if not the_state.func then let ((value, globals), map') = check [] [] the_state s 
        in (map', SBlock(value), None, globals)
      else let (value, data, map', out) = check_func [] None [] the_state s in 
        (map', SBlock(value), data, out)

  | Expr(e) -> let (t, e', _) = expr the_state e in (the_state.locals, SExpr(e'), None, [])

  | Continue -> if not the_state.forloop then raise (Failure ("SSyntaxError: continue not in loop")) else let () = debug "semantic checking for continue not fully supported" in (the_state.locals, SContinue, None, [])
  | Break -> if not the_state.forloop then raise (Failure ("SSyntaxError: break not in loop")) else let () = debug "semantic checking for break not fully supported" in (the_state.locals, SBreak, None, [])

  | Asn(exprs, e) -> 
    let data = expr the_state e in 
    let (typ, e', d) = data in

    let rec aux (m, lvalues, locals) = function
      | [] -> (m, List.rev lvalues, List.rev locals)
      | Var x :: t -> 
        let Bind (x1, t1) = x in 
        if the_state.cond && t1 <> Dyn then 
        raise (Failure ("SSyntaxError: cannot explicitly type variable '" ^ x1 ^ "' while in conditional branches")) 
        else let (m', name, inferred_t, explicit_t) = assign m data x in 
        (aux (m', SLVar (Bind (name, explicit_t)) :: lvalues, Bind(name, inferred_t) :: locals) t)

      | ListAccess(e, index) :: t ->
        let (t1, e1, _) = expr the_state e in
        let (t2, e2, _) = expr the_state index in
        if t1 <> Dyn && not (is_arr t1) || t2 <> Int && t2 <> Dyn || t1 == String 
          then raise (Failure ("STypeError: invalid types (" ^ string_of_typ t1 ^ ", " ^ string_of_typ t2 ^ ") for list assignment"))
        else (aux (m, SLListAccess (e1, e2) :: lvalues, locals) t)

      | ListSlice(e, low, high) :: t -> raise (Failure "SNotImplementedError: List Slicing has not been implemented")

      | Field(a, b) :: t -> raise (Failure "SNotImplementedError: Fields have not been implemented")
      | _ -> raise (Failure ("STypeError: invalid expression as left-hand side of assignment."))
      
    in let (m, lvalues, locals) = aux (the_state.locals, [], []) exprs in (m, SAsn(lvalues, e'), None, locals)

  | Func(a, b, c) -> 
    let Bind(fn_name, btype) = a in
    
    let rec dups = function (* check duplicate argument names *)
      | [] -> ()
      | (Bind(n1, _) :: Bind(n2, _) :: _) when n1 = n2 -> 
          raise (Failure ("SSyntaxError: duplicate argument '" ^ n1 ^ "' in definition of function " ^ fn_name))
      | _ :: t -> dups t
    in let _ = dups (List.sort (fun (Bind(a, _)) (Bind(b, _)) -> compare a b) b) in 

    let the_state = change_state the_state S_func in
    let (map', _, _, _) = assign the_state.locals (FuncType, (SNoexpr, FuncType), Some(Func(a, b, c))) (Bind(fn_name, Dyn)) in
    let (semantmap, _, _, _) = assign StringMap.empty (FuncType, (SNoexpr, FuncType), Some(Func(a, b, c))) (Bind(fn_name, Dyn)) in (* empty map for semantic checking *)

    let (map'', binds) = List.fold_left 
      (fun (map, out) (Bind(x, t)) -> 
        let (map', name, inferred_t, explicit_t) = assign map (Dyn, (SNoexpr, Dyn), None) (Bind(x, t)) in 
        (map', (Bind(name, explicit_t)) :: out)
      ) (semantmap, []) b in

    let bindout = List.rev binds in
    let (map2, block, data, locals) = (stmt (change_state the_state (S_noeval(map''))) c) in
      (match data with
        | Some (typ2, e', d) ->
            if btype <> Dyn && btype <> typ2 then if typ2 <> Dyn then 
            raise (Failure ("STypeError: invalid return type " ^ string_of_typ typ2 ^ " from function " ^ fn_name)) else 
            let func = { styp = btype; sfname = fn_name; sformals = bindout; slocals = locals; sbody = block } in 
              (map', SFunc(func), None, [Bind(fn_name, FuncType)]) else
              let func = { styp = typ2; sfname = fn_name; sformals = bindout; slocals = locals; sbody = block } in 
            (map', SFunc(func), None, [Bind(fn_name, FuncType)])
        
        | None -> 
          if btype <> Dyn then 
          raise (Failure ("STypeError: expected return type " ^ (string_of_typ btype) ^ " from function " ^ fn_name ^ " but found None")) else 
          let func = { styp = Null; sfname = fn_name; sformals = bindout; slocals = locals; sbody = block } in 
          (map', SFunc(func), None, [Bind(fn_name, FuncType)]))

  | If(a, b, c) -> let (typ, e', _) = expr the_state a in 
    if typ <> Bool && typ <> Dyn 
      then raise (Failure (Printf.sprintf "STypeError: invalid boolean type in 'if' statement (found %s but expected bool)" (string_of_typ typ)))
    else let (map', value, data, out) = stmt (change_state the_state S_cond) b in 
    let (map'', value', data', out') = stmt (change_state the_state S_cond)  c in 
    if equals map' map'' then (map', SIf(e', value, value'), match_data data data', out @ out') 
    else let (merged, main, alt, binds) = transform map' map'' in 
    (merged, SIf(e', merge_blocks value main, merge_blocks value' alt), match_data data data', binds @ out @ out')

  | For(a, b, c) -> 
      let (typ, e', _) = expr the_state b in 
      let (m, name, inferred_t, explicit_t) = check_array the_state b a in 
      let bind_for_locals = Bind(name, inferred_t) in
      let bind_for_sast = Bind(name, inferred_t) in
      let (m', x', d, out) = stmt (change_state the_state (S_forloop(m))) c in 
      if equals the_state.locals m' then let () = debug "equal first time" in (m', SFor(bind_for_sast, e', x'), d, bind_for_locals :: out)
      else let (merged_out, _, exit, binds) = transform the_state.locals m' in
      let (merged, entry, _, _) = transform m m' in 
      let (m', x', d, out) = stmt (change_state the_state (S_forloop(merged)))  c in 
      if equals merged m' then let () = debug "equal second time" in (merged_out, SStage(entry, SFor(bind_for_sast, e', x'), exit), match_data d None, bind_for_locals :: out @ binds) 
      else let (merged, _, _, _) = transform merged_out m' in 
      (merged, SStage(entry, SFor(bind_for_sast, e', x'), exit), match_data d None, bind_for_locals :: out @ binds) 


 | Range(a, b, c) -> 
    let (typ, e', data) = expr the_state b in 
    if typ <> Dyn && typ <> Int 
        then raise (Failure (Printf.sprintf "STypeError: invalid type in 'range' statement (found %s but expected int)" (string_of_typ typ)))

    else let (m, name, inferred_t, explicit_t) = assign the_state.locals (typ, e', data) a in

    let bind_for_locals = Bind(name, inferred_t) in
    let bind_for_sast = Bind(name, inferred_t) in
    let (m', x', d, out) = stmt (change_state the_state (S_forloop m)) c in 
    if equals the_state.locals m' then let () = debug "equal first time" in (m', SRange(bind_for_sast, e', x'), d, bind_for_locals :: out)
    else let (merged_out, _, exit, binds) = transform the_state.locals m' in
    let (merged, entry, _, _) = transform m m' in 
    let (m', x', d, out) = stmt (change_state the_state (S_forloop(m))) c in 
    if equals merged m' then let () = debug "equal second time" in (merged_out, SStage(entry, SRange(bind_for_sast, e', x'), exit), match_data d None, bind_for_locals :: out @ binds) 
    else let (merged, _, _, _) = transform merged_out m' in
    (merged, SStage(entry, SRange(bind_for_sast, e', x'), exit), match_data d None, bind_for_locals :: out @ binds) 

  | While(a, b) -> 
    let (typ, e, data) = expr the_state a in 
    if typ <> Bool && typ <> Dyn 
      then raise (Failure (Printf.sprintf "STypeError: invalid boolean type in 'while' statement (found %s but expected bool)" (string_of_typ typ)))
    else let (m', x', d, out) = stmt (change_state the_state (S_forloop the_state.locals)) b in 
    if equals the_state.locals m' then let () = debug "equal first time" in (m', SWhile(e, x'), d, out) else
    let (merged, entry, exit, binds) = transform the_state.locals m' in 
    let (m', x', d, out) = stmt (change_state the_state (S_forloop merged))  b in 
    if equals merged m' then let () = debug "equal second time" in (m', SStage(entry, SWhile(e, x'), exit), d, out @ binds)
    else let (merged, _, _, _) = transform merged m' in 
    (merged, SStage(entry, SWhile(e, x'), exit), match_data d None, out @ binds)


  | Nop -> (the_state.locals, SNop, None, [])
  | Print(e) -> let (t, e', _) = expr the_state e in (the_state.locals, SPrint(e'), None, [])
  | Type(e) -> let (t, e', _) = expr the_state e in
    (the_state.locals, SType(e'), None, [])

  | Class(name, body) ->
      let (m', x', data, binds) = stmt (change_state the_state S_class) body in
      (m', SClass(name, x'), data, binds)

  | _ as temp -> 
    print_endline ("SNotImplementedError: '" ^ (stmt_to_string temp) ^ "' semantic checking not implemented"); (the_state.locals, SNop, None, [])

(* check: master function to check the entire program by iterating over the list of
statements and returning a list of sstmts, a list of globals, and the updated map *)

and check sast_out globals_out the_state = function
  | [] -> ((List.rev sast_out, List.sort_uniq Stdlib.compare (List.rev (globals_out @ !possible_globals))), the_state.locals)
  | a :: t -> let (m', statement, data, binds) = stmt the_state a in check (statement :: sast_out) (binds @ globals_out) (change_state the_state (S_setmaps (m', m'))) t
