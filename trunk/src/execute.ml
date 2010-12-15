open Ast
open Bytecode

(* Stack layout just after "Ent":

              <-- SP
   Local n
   ...
   Local 0
   Saved FP   <-- FP
   Saved PC
   Arg 0
   ...
   Arg n *)
 
(* Increase the start time of each chord in the sequence by shift *)   
let shift_chords chord_list shift =
  let shift_chord chord =
    [(List.hd chord); (List.nth chord 1); (List.nth chord 2) + shift] @ (List.tl (List.tl (List.tl chord)))
  in List.map shift_chord chord_list
  
let replace_element l i n skip = 
  let a = Array.of_list l in
  a.(i+skip) <- n; Array.to_list a

let execute_prog prog =
  let stack = Array.make 1024 (Num(0))
  and globals = Array.make prog.num_globals (Num(0)) in

  let rec exec fp sp pc = match prog.text.(pc) with
    Num i -> stack.(sp) <- (Num(i)) ; exec fp (sp+1) (pc+1)
  | Mem s -> stack.(sp-1) <- (match (s, stack.(sp-1)) with 
      ("length", (Cho(len :: _))) -> (Num(len))
    | ("start", (Cho(l))) -> (Num(List.nth l 2))
    | ("duration", (Cho(l))) -> (Num(List.nth l 1))
    | ("pitch" , (Not(p,d))) -> (Num(p))
    | ("duration", (Not(p,d))) -> (Num(d))
    | ("current", (Seq ([c; l] :: _ ))) -> (Num(c))
    | ("length", (Seq ([c; l] :: _ ))) -> (Num(l))
    | _ -> raise (Failure ("illegal selection attribute"))) ; exec fp sp (pc+1)
  | Cst s -> stack.(sp-1) <- (match (s, stack.(sp-1)) with 
      ("Number", (Num i))-> (Num(i))
    | ("Note", (Num i)) ->  (Not(i,4))
    | ("Chord", (Not(p,d))) -> (Cho([1;d;0;p]))
    | ("Sequence", (Num 0)) -> (Seq([[0;0]]))
    | ("Sequence", (Cho(l))) -> (Seq([[(List.nth l 1); 1]; l]))
    | _ -> raise (Failure ("illegal type cast"))) ; exec fp sp (pc+1)
  | Not (p, d) -> stack.(sp) <- (Not(p,d)) ; exec fp (sp+1) (pc+1)
  | Cho (l) -> stack.(sp) <- (Cho(l)) ; exec fp (sp+1) (pc+1)
  | Seq (ll) -> stack.(sp) <- (Seq(ll)) ; exec fp (sp+1) (pc+1)
  | Ele -> stack.(sp-2) <- (match (stack.(sp-1), stack.(sp-2)) with 
      (Cho(l), Num(i)) -> (Not((List.nth l (i + 3)), List.nth l 1))
    | (Seq(ll), Num(i)) -> (Cho(List.nth ll (i+1)))
    | _ -> raise (Failure ("unexpected types for []"))) ; exec fp (sp-1) (pc+1)
  | Leo -> stack.(sp-3) <- (match (stack.(sp-1), stack.(sp-2), stack.(sp-3)) with 
      (Cho(l), Num(i), Not(p,d)) -> (Cho(replace_element l i p 3))
    | (Seq(ll), Num(i), Cho(l)) -> Seq(replace_element ll i l 1)
    | _ -> raise (Failure ("assignment to [] failed"))) ; exec fp (sp-2) (pc+1)
  | Lmo (s) -> stack.(sp-2) <- (match (s, stack.(sp-1), stack.(sp-2)) with 
      ("start", (Cho(l)), (Num i)) -> (Cho([(List.hd l); (List.nth l 1); i] @ (List.tl (List.tl (List.tl l)))))
    | ("duration", (Cho(l)), (Num i)) -> (Cho([(List.hd l); i; (List.nth l 2)] @ (List.tl (List.tl (List.tl l)))))
    | ("pitch" , (Not(p,d)), (Num i)) -> (Not(i, d))
    | ("duration", (Not(p,d)), (Num i)) -> (Not(p, i))
    | ("current", (Seq ([c; l] :: cs )), (Num i)) -> (Seq([i;l] :: cs))
    | _ -> raise (Failure ("illegal selection attribute"))) ; exec fp (sp-1) (pc+1)
  | Drp -> exec fp (sp-1) (pc+1)
  | Bin op -> let opA = stack.(sp-2) and opB = stack.(sp-1) in     
      stack.(sp-2) <- (let boolean i = if i then Num(1) else Num(0) in
      match op with
        Add -> (match (opA, opB) with 
            (Num op1, Num op2) -> Num(op1 + op2)
          | (Not(p,d), Num i) -> Not(p,d+i)
          | (Cho(l), Not(p,d)) -> Cho(l @ [p])
          | ((Seq ([c; l] :: cs )), (Not(p, d))) -> Seq([c+d; l+1] :: cs @ [[1;d;c;p]])
          | ((Seq ([c; l] :: cs )), (Cho(chord))) -> Seq([c+(List.nth chord 1); l+1] :: cs @  [[(List.hd chord); (List.nth chord 1); c] @ (List.tl (List.tl (List.tl chord)))])
          | ((Seq ([c1; l1] :: cs1 )), (Seq ([c2; l2] :: cs2 ))) -> Seq([c1+c2; l1+l2] :: cs1 @ (shift_chords cs2 c1))
          | _ -> raise (Failure ("unexpected types for +")))
      | Sub -> (match (opA, opB) with 
          (Num op1, Num op2) -> Num(op1 - op2)
        | _ -> raise (Failure ("unexpected types for -")))
      | Mod -> (match (opA, opB) with 
          (Num op1, Num op2) -> Num(op1 mod op2)
        | _ -> raise (Failure ("unexpected types for %")))
      | DotAdd -> (match (opA, opB) with 
          (Not (p, d), Num op2) -> Not(p + op2, d) (* add pitch of Note to Number *)
        | _ -> raise (Failure ("unexpected types for .+")))
      | DotSub -> (match (opA, opB) with 
          (Not (p, d), Num op2) -> Not(p - op2, d) 
        | _ -> raise (Failure ("unexpected types for .-")))
      | And -> (match (opA, opB) with 
          (Num op1, Num op2) -> boolean (op1 != 0 && op2 != 0)
        | _ -> raise (Failure ("unexpected types for &&")))
      | Or -> (match (opA, opB) with 
          (Num op1, Num op2) -> boolean (op1 == 1 || op2 == 1)
        | _ -> raise (Failure ("unexpected types for ||")))
      | Equal -> (match (opA, opB) with 
          (Num op1, Num op2) -> boolean (op1 =  op2)
        | _ -> raise (Failure ("unexpected types for =")))
      | Neq -> (match (opA, opB) with 
          (Num op1, Num op2) -> boolean (op1 != op2)
        | _ -> raise (Failure ("unexpected types for !=")))
      | Less -> (match (opA, opB) with 
          (Num op1, Num op2) -> boolean (op1 <  op2)
        | _ -> raise (Failure ("unexpected types for <")))
      | Leq -> (match (opA, opB) with 
          (Num op1, Num op2) -> boolean (op1 <= op2)
        | _ -> raise (Failure ("unexpected types for <=")))
      | Greater -> (match (opA, opB) with 
          (Num op1, Num op2) -> boolean (op1 >  op2)
        | _ -> raise (Failure ("unexpected types for >")))
      | Geq -> (match (opA, opB) with 
          (Num op1, Num op2) -> boolean (op1 >= op2)
        | _ -> raise (Failure ("unexpected types for >="))));
      exec fp (sp-1) (pc+1)
  | Lod i -> stack.(sp)   <- globals.(i)  ; exec fp (sp+1) (pc+1)
  | Str i -> globals.(i)  <- stack.(sp-1) ; exec fp sp     (pc+1)
  | Lfp i -> stack.(sp)   <- stack.(fp+i) ; exec fp (sp+1) (pc+1)
  | Sfp i -> stack.(fp+i) <- stack.(sp-1) ; exec fp sp     (pc+1)
  (** this is the print command. change it to set tempo and play *)
  | Jsr(-2) -> (match stack.(sp-1) with Num i ->  print_endline (string_of_int i); exec fp sp (pc+1)
            | _ -> raise (Failure ("unexpected type for set_tempo")))
  | Jsr(-1) -> (match stack.(sp-1) with Seq s ->  print_endline (print_sequence s); exec fp sp (pc+1)
            | Cho d -> let a = List.hd (List.tl d) in let c = List.hd (List.tl (List.tl d)) in
                ignore(List.map print_endline (List.map (fun b -> string_of_int c^","^string_of_int a^","^string_of_int b) (List.tl (List.tl (List.tl d))))); exec fp sp (pc+1)
            |_ -> raise (Failure ("unexpected type for play")))
  | Jsr(-3) -> stack.(sp) <- (Seq([[0;0]])) ; exec fp (sp+1) (pc+1)
  | Jsr(-4) -> (match stack.(sp-1) with Num i ->
                let rec chord l n m = if n>m then l else (match stack.(sp-n-1) with Not (pitch,duration) ->
                                if n=1 then chord [m; duration; 0; pitch] (n+1) m else chord (l @ [pitch]) (n+1) m
                                | _ -> raise (Failure "unexpected type for chord"))
                    in let my_chord = (chord [] 1 i) in
                    stack.(sp-i-1) <- (Cho(my_chord)) ; exec fp (sp-i) (pc+1)
                | _ -> raise (Failure ("unexpected type for chord")))
  | Jsr i -> stack.(sp)   <- (Num(pc + 1))       ; exec fp (sp+1) i
  | Ent i -> stack.(sp)   <- (Num(fp))           ; exec sp (sp+i+1) (pc+1)
  | Rts i -> let new_fp = stack.(fp) and new_pc = stack.(fp-1) in
    stack.(fp-i-1) <- stack.(sp-1) ; exec 
                 (match new_fp with Num nfp -> nfp  
                   | _ -> raise (Failure ("unexpected types for return"))) 
                 (fp-i) 
                 (match new_pc with Num npc -> npc  
                   | _ -> raise (Failure ("unexpected types for return")))
  | Beq i -> exec fp (sp-1) (pc + if 
    (match stack.(sp-1) with Num temp -> temp =  0 
      | _ -> raise (Failure ("unexpected types for return"))) then i else 1)
  | Bne i -> exec fp (sp-1) (pc + if 
    (match stack.(sp-1) with Num temp -> temp !=  0 
      | _ -> raise (Failure ("unexpected types for return"))) then i else 1)
  | Bra i -> exec fp sp (pc+i)
  | Hlt   -> ()

  in exec 0 0 0
