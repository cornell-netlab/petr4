Require Import Coq.Lists.List.
Require Import Coq.FSets.FMapList.
Require Import Coq.Structures.OrderedTypeEx.
Require Import Coq.ZArith.BinIntDef.
Require Import Coq.Strings.String.

Require Import Poulet4.Monads.Monad.
Require Import Poulet4.Monads.Option.
Require Import Poulet4.Monads.State.
Require Import Poulet4.Monads.Transformers.

Require Import Poulet4.Bitwise.
Require Import Poulet4.Typed.
Require Import Poulet4.Syntax.
Require Import Poulet4.P4String.
Require Poulet4.StringConstants.

Open Scope monad.
Open Scope bool_scope.
Open Scope N_scope.
Open Scope string_scope.

Module Import MNat := FMapList.Make(Nat_as_OT).
Module Import MStr := FMapList.Make(String_as_OT).

Inductive exception :=
| PacketTooShort
| Reject
| Exit
| Internal
| TypeError (error_msg: string)
| AssertError (error_msg: string)
| SupportError (error_msg: string)
.

Section Environment.

  Context (tags_t: Type).
  Context (tags_dummy: tags_t).

  Definition loc := nat.
  Definition scope := MStr.t loc.
  Definition stack := list scope.
  Definition heap := MNat.t (@Value tags_t).

  Record environment := MkEnvironment {
    env_fresh: loc;
    env_stack: stack;
    env_heap: heap;
  }.

  Definition env_monad := @state_monad environment exception.

  Fixpoint stack_lookup' (key: string) (st: stack) : option loc :=
    match st with
    | nil => None
    | top :: rest =>
      match MStr.find key top with
      | None => stack_lookup' key rest
      | Some l => Some l
      end
    end.

  Definition stack_lookup (key: string) : env_monad loc :=
    fun env =>
      match stack_lookup' key (env_stack env) with
      | None => state_fail (AssertError "Could not look up variable on stack.") env
      | Some l => mret l env
      end.

  Definition stack_insert' (key: string) (l: loc) (st: stack) : option stack :=
    match st with
    | nil => None
    | top :: rest =>
      match MStr.find key top with
      | None => Some ((MStr.add key l top) :: rest)
      | Some _ => None
      end
    end.

  Definition stack_insert (key: string) (l: loc) : env_monad unit :=
    fun env =>
      match env_stack env with
      | nil => state_fail (AssertError "No top scope to add name from.") env
      | top :: rest =>
        match MStr.find key top with
        | None =>
          mret tt {|
            env_fresh := env_fresh env;
            env_stack := (MStr.add key l top) :: rest;
            env_heap := env_heap env;
          |}
        | Some _ => state_fail (AssertError "Name already present in top scope.") env
        end
      end.

  Definition stack_push : env_monad unit :=
    fun env => mret tt {|
      env_fresh := env_fresh env;
      env_stack := MStr.empty _ :: (env_stack env);
      env_heap := env_heap env;
    |}.

  Definition stack_pop : env_monad unit :=
    fun env =>
      match env_stack env with
      | nil => state_fail (AssertError "No top scope to pop from the stack.") env
      | _ :: rest => mret tt {|
          env_fresh := env_fresh env;
          env_stack := rest;
          env_heap := env_heap env;
        |}
      end.

  Definition heap_lookup (l: loc) : env_monad (@Value tags_t) :=
    fun env =>
      match MNat.find l (env_heap env) with
      | None => state_fail (AssertError "Unable to look up location on heap.") env
      | Some val => mret val env
      end.

  Definition heap_update (l: loc) (v: @Value tags_t) : env_monad unit :=
    fun env => mret tt {|
      env_fresh := env_fresh env;
      env_stack := env_stack env;
      env_heap := MNat.add l v (env_heap env);
    |}.

  Definition heap_insert (v: @Value tags_t) : env_monad loc :=
    fun env =>
      let l := env_fresh env in
      mret l {|
        env_fresh := S l;
        env_stack := env_stack env;
        env_heap := MNat.add l v (env_heap env);
      |}.

  Definition env_insert (name: string) (v: @Value tags_t) : env_monad unit :=
    let* l := heap_insert v in
    stack_insert name l.

  Fixpoint top_scope (scopes: stack) : option scope :=
    match scopes with
    | nil => None
    | x :: nil => Some x
    | _ :: scopes' => top_scope scopes'
    end.

  Definition lookup_value' (key: P4String.t tags_t) (fields: list (P4String.t tags_t * @ValueBase tags_t)) : option_monad :=
    let* '(_, v) := List.find (fun '(k, _) => equivb k key) fields in
    Some v.

  Definition lookup_value (v: @ValueBase tags_t) (field: P4String.t tags_t) : @option_monad (@ValueBase tags_t) :=
    match v with
    | ValBaseRecord fields
    | ValBaseStruct fields
    | ValBaseUnion fields
    | ValBaseHeader fields _
    | ValBaseSenum fields => lookup_value' field fields
    | ValBaseStack hdrs len next =>
      if eq_const field StringConstants.last then List.nth_error hdrs (len - 1) else
      if eq_const field StringConstants.next then List.nth_error hdrs next else
      None
    | _ => None
    end.

  Definition bit_slice (v: @ValueBase tags_t) (msb: nat) (lsb: nat): @option_monad (@ValueBase tags_t) :=
    match v with
    | ValBaseBit width val
    | ValBaseInt width val
    | ValBaseVarbit _ width val =>
      if Nat.leb lsb msb && Nat.leb msb width
      then
        let w_out := msb - lsb in
        let bits := of_nat (Z.to_nat val) width in
        let* sliced := slice width bits lsb msb in
        Some (ValBaseBit w_out (Z.of_nat (to_nat sliced)))
      else None
    | _ => None
    end.

  Definition array_index (v: @ValueBase tags_t) (idx: nat): @option_monad (@ValueBase tags_t) :=
    match v with
    | ValBaseStack hdrs _ _ => nth_error hdrs idx
    | _ => None
    end.

  Definition get_name_loc (name: @Typed.name tags_t) : env_monad loc :=
    match name with
    | BareName nm => stack_lookup (str nm)
    | QualifiedName nil nm =>
      let* env := get_state in
      let* scope := lift_opt (AssertError "Could not find top scope.") (top_scope (env_stack env)) in
      lift_opt (AssertError "Could not find name in scope.") (stack_lookup' (str nm) (scope :: nil))
    | QualifiedName _ _ =>
      state_fail (SupportError "Qualified name lookup is not implemented.")
    end.

  Definition env_name_lookup (name: Typed.name) : env_monad (@Value tags_t) :=
    get_name_loc name >>= heap_lookup.

  Definition env_str_lookup (name: P4String.t tags_t) : env_monad (@Value tags_t) :=
    env_name_lookup (BareName name).

  Fixpoint env_lookup (lvalue: @ValueLvalue tags_t) : env_monad (@Value tags_t) :=
    let 'MkValueLvalue lv _ := lvalue in
    match lv with
    | ValLeftName name =>
      env_name_lookup name

      (* TODO: there's probably a way to refactor the following 3 cases *)
    | ValLeftMember inner member =>
      let* inner_val := env_lookup inner in
      match inner_val with
      | ValBase v =>
        let* result := lift_opt (AssertError "Unable to find member in value.") (lookup_value v member) in
        state_return (ValBase result)
      | _ => state_fail (TypeError "Member access on something that is not a base value.")
      end

    | ValLeftBitAccess inner msb lsb =>
      let* inner_val := env_lookup inner in
      match inner_val with
      | ValBase v =>
        let* result := lift_opt (AssertError "Unable to take bit slice of a value.") (bit_slice v msb lsb) in
        state_return (ValBase result)
      | _ => state_fail (TypeError "Bit string access on something that is not a base value.")
      end

    | ValLeftArrayAccess inner idx =>
      let* inner_val := env_lookup inner in
      match inner_val with
      | ValBase v =>
        let* result := lift_opt (AssertError "Unable to access index of a value.") (array_index v idx) in
        state_return (ValBase result)
      | _ => state_fail (TypeError "Array access on something that is not a base value.")
      end
    end.

  Fixpoint update_member' (fields: list (@P4String.t tags_t * @ValueBase tags_t)) (field: @P4String.t tags_t) (v: @ValueBase tags_t) : option_monad :=
    match fields with
    | nil => None
    | (fld, v') :: fields' =>
      if equivb fld field
      then Some ((fld, v) :: fields') else
      let* fields'' := update_member' fields' field v in
      Some ((fld, v') :: fields'')
    end.

  Definition update_slice (lhs: @ValueBase tags_t) (msb: nat) (lsb: nat) (rhs: @ValueBase tags_t) : env_monad (@ValueBase tags_t) :=
    match (lhs, rhs) with
    | (ValBaseBit wl vl, ValBaseBit wr vr) =>
      let (bitl, bitr) := (of_nat (Z.to_nat vl) wl, of_nat (Z.to_nat vr) wr) in
      let* bit_result := lift_opt (AssertError "Could not splice bits.") (splice wl bitl lsb msb wr bitr) in
      state_return (ValBaseBit wl (Z.of_nat (to_nat bit_result)))
    | _ => state_fail (TypeError "Bit slice update requires bit values on both sides.")
    end.

  (*  split a list at an index, without including the index
      e.g. split 2 [1;2;3;4;5] = ([1;2], [4;5])
  *)
  Definition split_list {A} (idx: nat) (xs: list A) : (list A * list A) :=
    (firstn idx xs, skipn (List.length xs - idx) xs).

  Definition update_array (lhs: @ValueBase tags_t) (idx: nat) (rhs: @ValueBase tags_t) : env_monad (@ValueBase tags_t) :=
    match lhs with
    | ValBaseStack hdrs len nxt =>
      if Nat.leb len idx then state_fail (AssertError "Out of bounds header stack write.") else
      let (pref, suff) := split_list idx hdrs in
      state_return (ValBaseStack (pref ++ rhs :: suff) len nxt)
    | _ => state_fail (TypeError "Attempt to update something that is not a header stack.")
    end.

  Definition update_member (lhs: @ValueBase tags_t) (member: @P4String.t tags_t) (rhs: @ValueBase tags_t) : env_monad (@ValueBase tags_t) :=
    match lhs with
    (* TODO: there must be a cleaner way... *)
    | ValBaseRecord fields =>
      let* fields' := lift_opt (AssertError "Unable to update member of record.")
                               (update_member' fields member rhs) in
      state_return (ValBaseRecord fields')
    | ValBaseStruct fields =>
      let* fields' := lift_opt (AssertError "Unable to update member of struct.")
                               (update_member' fields member rhs) in
      state_return (ValBaseStruct fields')
    | ValBaseHeader fields is_valid =>
      let* fields' := lift_opt (AssertError "Unable to update member of header.")
                               (update_member' fields member rhs) in
      state_return (ValBaseHeader fields' is_valid)
    | ValBaseUnion fields =>
      let* fields' := lift_opt (AssertError "Unable to update member of union")
                               (update_member' fields member rhs) in
      state_return (ValBaseRecord fields')
    | ValBaseSenum fields =>
      let* fields' := lift_opt (AssertError "Unable to update member of enum.")
                               (update_member' fields member rhs) in
      state_return (ValBaseSenum fields')
    | ValBaseStack hdrs len next =>
      if eq_const member StringConstants.last then update_array lhs len rhs else
      if eq_const member StringConstants.next then update_array lhs next rhs else
      state_fail (AssertError "Can only update next and last members of header stack.")
    | _ => state_fail (AssertError "Unsupported value in member update.")
    end.

  Fixpoint env_update (lvalue: @ValueLvalue tags_t) (value: @Value tags_t) : env_monad unit :=
    let 'MkValueLvalue lv _ := lvalue in
    match lv with
    | ValLeftName nm =>
      let* loc := get_name_loc nm in
      heap_update loc value

    (* TODO: again, it would be good to refactor some of this logic *)
    | ValLeftMember inner member =>
      let* lv' := env_lookup inner in
      match (lv', value) with
      | (ValBase lv'', ValBase value') =>
        let* value'' := update_member lv'' member value' in
        env_update inner (ValBase value'')
      | _ => state_fail (TypeError "Member expression did not evaluate to base values.")
      end
    | ValLeftBitAccess inner msb lsb =>
      let* lv' := env_lookup inner in
      match (lv', value) with
      | (ValBase lv'', ValBase value') =>
        let* value'' := update_slice lv'' msb lsb value' in
        env_update inner (ValBase value'')
      | _ => state_fail (TypeError "Bit access expression did not evaluate to base values.")
      end
    | ValLeftArrayAccess inner idx =>
      let* lv' := env_lookup inner in
      match (lv', value) with
      | (ValBase lv'', ValBase value') =>
        let* value'' := update_array lv'' idx value' in
        env_update inner (ValBase value'')
      | _ => state_fail (TypeError "Array access expression did not evaluate to base values.")
      end
    end.

  Definition toss_value (original: env_monad (@Value tags_t)) : env_monad unit :=
    fun env =>
      match original env with
      | (inl result, env') => mret tt env'
      | (inr exc, env') => state_fail exc env'
      end.

  Definition dummy_value (original: env_monad unit) : env_monad (@Value tags_t) :=
    fun env =>
      match original env with
      | (inl tt, env') => mret (ValBase ValBaseNull) env'
      | (inr exc, env') => state_fail exc env'
      end.
End Environment.