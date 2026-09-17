Network egress from this sandbox is allowlisted by default; it may instead
have been created with `NETWORK_ALLOWLIST=false`, which turns that allow list
off. Either way, a guard enforces what remains blocked.

When a request is blocked by policy, that is a decision to respect, not an
obstacle to route around. Do not retry it, mirror or vendor the resource,
substitute a different host, or quietly drop the step. Report the blocked host
to the user with the specific remedy the guard returned, then wait. The three
are not interchangeable: a default deny needs `sbx policy allow`, a local deny
rule must be removed with `sbx policy rm` because allowing cannot override a
deny, and an organisation policy can only be lifted by IT.

`sbx policy` is a host command. It does not work from inside this sandbox, so
do not try to change the policy yourself.
