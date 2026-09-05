Network egress from this sandbox is allowlisted, and a guard enforces it.

When a request is blocked by policy, that is a decision to respect, not an
obstacle to route around. Do not retry it, mirror or vendor the resource,
substitute a different host, or quietly drop the step. Report the blocked host
to the user with the specific remedy the guard returned, then wait. The three
are not interchangeable: a default deny needs `sbx policy allow`, a local deny
rule must be removed with `sbx policy rm` because allowing cannot override a
deny, and an organisation policy can only be lifted by IT.

`sbx policy` is a host command. It does not work from inside this sandbox, so
do not try to change the policy yourself.
