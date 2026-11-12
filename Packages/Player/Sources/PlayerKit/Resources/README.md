# cacert.pem

Mozilla's root certificates as curl publishes them (https://curl.se/ca/cacert.pem, MPL 2.0),
for `MediaClipper`: MPVKit's iOS FFmpeg has no certificate store, so without it HTTPS streams
fail verification. Fetched 2026-11-04 (Mozilla data of 2026-10-20), SHA-256
796f1389bfea13c0ed78f663b765baaff54a508e5483786bd6ece73c5e3e3cbe. Refresh it now and then
(the curl page lists the current SHA-256).
