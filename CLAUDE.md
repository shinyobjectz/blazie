<!-- montology:begin -->
## The vocabulary (montology)

This repo's words live in a database, not a doc. Before naming ANYTHING —
a class, a concept, a tag — check it: `monty onto check <name>`. The full
vocabulary is the `words` skill (generated — never hand-edit; `monty sync`
re-renders it). `monty lint` fails the build on collisions between code
and vocabulary; a FAIL line carries its repair. `monty scan --candidates`
lists recurring declared names that want a definition.
<!-- montology:end -->
