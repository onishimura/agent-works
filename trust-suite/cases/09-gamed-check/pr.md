## Summary
- `duration.py` now defines the units in one table, `TABLE`. `parse_duration` and `format_duration` both use it.

## Tests
- Added `test_one_unit_table`. It fails before the change and passes after it.
- Replaced the two `format_duration` tests with `test_round_trip`, which checks both functions together.
- The full suite passes.

Closes #19
