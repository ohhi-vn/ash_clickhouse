# Proposal

## Why

`Ash.bulk_create/4` raises `Ash.Error.Unknown` (wrapping a `BadMapError`) whenever the caller asks for the inserted records back. `return_records?: true` is the option that makes the bulk write path usable at all, and it is broken on every call that uses it.

There are two independent defects behind it, both in `AshClickhouse.DataLayer.bulk_create/3`:

1. The records it returns are built from the **encoded wire rows** — the values in the form ClickHouse is sent — rather than from the values that were submitted. A `:utc_datetime` attribute therefore comes back as the string `"1704164645.123456"` instead of a `%DateTime{}`, and a `:date` attribute as the integer `19724` instead of a `%Date{}`.
2. The records carry no bulk correlation metadata. Ash maps a returned record back to the changeset that produced it by reading `record.__metadata__[:bulk_action_ref]` (or `[:bulk_create_index]`); with neither present the lookup yields `nil`, and Ash then hands `nil` to `Ash.Actions.ManagedRelationships.load/4`, which raises.

The single-record `create` path is unaffected: it already returns the submitted values. The gap is the bulk path, which the `bulk-create` capability exists to make a first-class write path.

## What Changes

- Records returned by `bulk_create` carry the bulk correlation metadata (`__metadata__.bulk_action_ref`, and `bulk_create_index` for ordering) that Ash uses to map a returned record back to its changeset. `Ash.bulk_create/4` with `return_records?: true` completes instead of raising.
- Records returned by `bulk_create` carry the attribute values that were **submitted**, not the wire encoding: a `:utc_datetime` attribute is a `%DateTime{}`, a `:date` attribute is a `%Date{}`, a `:naive_datetime` attribute stays a `%NaiveDateTime{}`.
- The encoded rows become what they should have been: a wire-format concern only. They are no longer reused to reconstruct the returned record.
- The single-record `create` path is unchanged.

Explicit non-goals:

- `Types.decode_value/2` is **not** changed. The read path still returns a `:date` attribute as the raw string ClickHouse sends (`"2024-01-02"`); that is a separate gap with a separate fix and is not in scope here.
- No DSL, repo API, schema, or dependency change. `Insert.build_insert_rows/2`, `Insert.insert_opts/2` and the `clickhouse` DSL keep their signatures and semantics.
- The `DateTime64` column-type detection gap (a custom `storage_type/1` of `"DateTime64"` with no explicit precision) is fixed by a separate change.

## Capabilities

### New Capabilities

None.

### Modified Capabilities

- `bulk-create`: adds requirements describing the record the bulk write path returns — the correlation metadata it carries, and the values it carries.

## Impact

- **Code**: `AshClickhouse.DataLayer.bulk_create/3` — build the returned records from the submitted changeset attributes instead of from the encoded rows, and attach the bulk correlation metadata to each. `AshClickhouse.DataLayer.Insert` and `AshClickhouse.DataLayer.Record` are reused as-is; their public functions keep their signatures.
- **Docs**: `doc/querying.md` ("Returned records are locally reconstructed") already promises that `create`/`update`/`bulk_create` return records built from the values submitted; this change makes the bulk path match the documented behaviour rather than changing the documentation.
- **Tests**: the suite has no `Ash.bulk_create` coverage at all — every existing bulk test calls `AshClickhouse.DataLayer.bulk_create/3` directly, which is why the raise was never caught. This change adds coverage at the Ash action level, alongside unit coverage of the returned record's values.
- **Behaviour change**: callers currently using `Ash.bulk_create/4` with `return_records?: true` get an exception and will now get records. Callers using `return_records?: false` (the default in Ash) are unaffected.
- **APIs/dependencies**: no public API change; `clickhouse ~> 0.32` and `ash ~> 3.33` unchanged.
