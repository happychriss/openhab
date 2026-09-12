# openHAB config

**Read `todo.md` at the start of every session** — it holds the open work items and
decisions for this config. Add new findings there rather than leaving them in chat history.

## Working rules

- Changes here affect a live home. Plan and get review before editing rules or items.
- After editing `.items` files, re-run `init.rules`.
- Heating logic lives in `automation/ruby/heating.rb` (JRuby), not in `rules/*.rules`.
