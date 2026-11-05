# Disk image packaging failures

Craft retains the failed disk image lifecycle phase in its packaging error:
staging, image creation, attachment, layout, detachment or conversion. The
receipt includes the owned temporary image and requested mount path, the
successful attachment tool output, and every failed detach attempt in order.

Keep this receipt with the original failing job log. An error after transient
contention must retain both diagnostics; a later local success cannot explain
whether the original mount disappeared or the requested path stopped resolving.

Only resource contention receives the existing bounded detach retries. Other
errors, including a missing mount, still fail packaging. The final cleanup
attempt remains responsible for the owned attachment. Successful packaging
still requires image conversion and the configured signature verification.
