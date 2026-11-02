# Proposal: a field's type in `fields<T>`, and size parameters

*A proposal to the Goose language, from the Honk web framework. Draft, not
yet filed.*

## Summary

Two related changes, each useful alone, that let generic code handle every
member of the array family without enumerating sizes:

1. **The field-type binding** `const for <N, A, U> in fields<T>` from
   `docs/design/const_for.md` §10, with `U` bound to the field's read type.
2. **Size parameters** on generic functions, `fn f<let K>(s: u8[..K])`, so
   that one overload covers `u8[..K]` for every `K`. Today the spec says
   "there are no size parameters (`fn f<N>(a: i64[N])` is an error)" (§3.3).

## Motivation

Honk's model code walks a struct's fields and picks a reader, writer or
JSON Schema writer for each field through overload resolution:

```goose
const for <N, A> in fields<T> { read_value(r, dst.A, e, loc, BY_TYPE); }
```

Two things make that harder than it should be.

**There is no way to say "any other type is a model".** An overload set
needs a catch-all for nested structs, but a generic `T` parameter ranks the
same as `T[:]`, so arrays become ambiguous. Honk works around this with a
dispatch token: every specific overload takes `k: i64`, the catch-all takes
`k: f64`, and each call passes an `i64`. That works only because an
integer-to-float conversion is the candidate the compiler tries last
(§7.1). The trick is correct but obscure, and it repeats through nine
overload sets. With `U` bound, the library could dispatch on the type
itself, by `types<...>` membership or by passing `U` explicitly.

**Limited arrays need one overload per capacity.** A request field
`name: u8[..32]` must be read by an overload whose parameter is exactly
`u8[..32]&`, since a `u8[:]` cannot grow and a generic `T&` cannot append.
Honk therefore lists ten capacities (8 to 4096) in each of four overload
sets. Any other capacity fails to compile with an error about `fields`,
which confuses users:

```goose
fn read_value(r: json::Reader&, dst: u8[..8]&, ...)    { read_limited(r, dst, 8, ...); }
fn read_value(r: json::Reader&, dst: u8[..16]&, ...)   { read_limited(r, dst, 16, ...); }
// ... eight more, in four overload sets
```

With size parameters this becomes one overload:

```goose
fn read_value<let K>(r: json::Reader&, dst: u8[..K]&, ...) { read_limited(r, dst, K, ...); }
```

## Proposed design

### 1. `<N, A, U>`

As sketched in §10. `U` is the field's **read type**: the type `v.A` has as
an expression. For a `varint` field that is `i64`. For a resizable or
variable-size field it is the field's declared type, usable only where
that type is legal (as a reference parameter's pointee, say), which matches
§10's warning that "not every storage type is legal as an ordinary function
result".

`U` behaves as a type parameter inside the fragment, so it composes with
what exists today:

```goose
const for <N, A, U> in fields<T> {
    read_into<U>(r, dst.A);          // dispatch on U explicitly
}
```

### 2. Size parameters

* Syntax `<let K>` in a function's generic list, to mark a constant rather
  than a type. `let` already means "an immutable binding", and `let` globals
  already serve as compile-time sizes.
* `K` is inferred from an argument's type (`u8[..32]` binds `K = 32`), and
  may be given explicitly (`f<32>(...)`).
* Inside the body `K` is an `i64` constant, usable wherever an array size
  or a `const for` constant is today.
* Each distinct `K` is its own specialization, as each type is now, so
  there is no runtime cost and code size grows per size used.
* Overload ranking: binding a size is a generic exact match, the same rank
  as binding a type. `u8[..K]&` therefore beats a coercion to `u8[:]`, as
  `T[>..]&` does today.

## What it removes in Honk

The 40 capacity overloads, the dispatch-token parameter on nine overload sets,
and the "capacities 8 to 4096" limit in the docs. The error users see for
an unsupported field type would name their field type instead of
`fields requires a concrete struct`.

## Compatibility and cost

* Both are additive. `<let K>` is new syntax in a generic list where `let`
  is not legal today. A third binding in `fields` is new, and the existing
  two-binding form is unchanged.
* Specialization per size follows the existing model. The compiler already
  tracks array sizes as part of types.

## Open questions

* Should size parameters also be allowed on structs (`struct Buf<let K> {
  data: u8[..K] }`)? Useful, but larger: it touches type identity and
  serialization. This proposal is functions only.
* `T[k]` fixed arrays would benefit too (`fn sum<T, let K>(a: T[K])`),
  although slices already cover most read-only uses.
