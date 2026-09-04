Network egress from this sandbox is allowlisted, and a guard enforces it.

When a request is blocked by policy, that is a decision to respect, not an
obstacle to route around. Do not retry it, mirror or vendor the resource,
substitute a different host, or quietly drop the step. Report the blocked host
to the user and wait for them to allow it from their host machine.

`sbx policy` is a host command. It does not work from inside this sandbox, so
do not try to change the policy yourself.
