# Proposal: whether a field has a default, in `const for ... in fields<T>`

*A proposal to the Goose language, from the Honk web framework. Draft, not
yet filed.*

## Summary

Let a `fields<T>` expansion ask, at specialization time, whether the
current field declares a default. This builds on the "Defaults and
annotations" item in `docs/design/const_for.md` §10, in its narrowest form:
a compile-time `bool`, with no access to the default expression and nothing
evaluated during expansion.

```goose
const for <N, A> in fields<T> {
    if !has_default(A) && !seen(N) { missing(N); }
}
```

## Motivation

A library that reads values into structs needs to know which fields the
input must supply. Honk validates JSON request bodies against plain Goose
structs, as a serde derive or Pydantic would:

```goose
struct ItemIn {
    name: u8[..32],             // must be sent
    price: f64,                 // must be sent
    tax: f64 = 0.2,             // may be left out
    discount: f64 = 0.0,        // may be left out, but Honk cannot tell
}
```

Today an expansion can see each field's *value* in `T { .. }`, but not
whether that value came from a declared default or from the type's zero.
Honk therefore guesses: a field is required when its value in `T { .. }`
is its type's zero. That guess gets `discount` wrong, and the error only
appears at run time, as a client being told `Field required`. Honk adds
`honk::Opt<T>` as an escape hatch, but users have to know the rule before
they hit it.

The same question comes up for any reader of external data: JSON, CSV,
config files, query strings, command-line flags, and the migration of old
serialized records.

## Proposed design

A specialization-time predicate on an accessor:

```goose
has_default(A) -> bool        // a constant: does this field declare `= ...`?
```

* It is valid only where an accessor from `fields<T>` is in scope, like
  `v.A`, and it folds to `true` or `false` in each expansion. Dead branches
  then fold away, as `if` on a constant already does.
* It does not evaluate the default. §10 notes that "defaults may contain
  runtime work and must not be executed during expansion". The predicate
  only asks whether the declaration has a `= ...`. The value is still
  obtained as today, through `T { .. }`, at run time.
* A variant payload's fields (`fields<V>`) answer the same way.

### Alternative spellings

* A third binding `<N, A, D>`, where `D` is a `bool` constant. This
  overlaps with the type binding `<N, A, U>` that §10 already considers,
  and binding counts are exact in v1, so it would need its own rule.
* A source filter, `fields_with_default<T>` / `fields_without_default<T>`.
  It needs no new expression form, but splits one loop into two.

The predicate keeps v1's two bindings unchanged and composes with a future
`U` binding.

## What it removes in Honk

```goose
// today (honk/model.goose): a guess, with five overloads for the guess
fn required_field(v: i64, k: i64) -> bool { v == 0 }
fn required_field(v: f64, k: i64) -> bool { v == 0.0 }
fn required_field(v: bool, k: i64) -> bool { false }
...

// with the proposal
if !has_default(A) && !seen[i] { add_error(e, "missing", loc, "Field required", ""); }
```

The generated OpenAPI `required` lists would become exact as well.

## Compatibility and cost

* Purely additive: no existing program changes meaning. `has_default` is a
  contextual name, like `fields` and `types`.
* No runtime cost, since the answer is a constant per expansion. Compile
  time grows by one flag read per field.
* The compiler already knows, at every struct literal, which fields have
  defaults, because `T { .. }` and missing-field errors depend on it.

## Open questions

* Should a field whose type has a default of its own (a nested struct whose
  fields all have defaults) count as having one? This proposal says no:
  only a written `= ...` counts, which is what users can see in the
  declaration.
* Generic structs: `has_default` answers for the instantiation, which is
  the same for every instantiation because defaults are written once.
