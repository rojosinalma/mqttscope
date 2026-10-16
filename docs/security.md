# Security

1. **No built-in authentication.** Anyone who can reach the port can read every stored message,
   publish (if enabled) and change settings, including the broker credentials. Run it on a trusted
   network, or put it behind a reverse proxy that handles authentication (basic auth, an identity
   proxy, a VPN).
2. **Publishing** can be switched off with the `publish_enabled` setting; it then returns 403 from
   `POST /api/publish` and the UI hides the form. Messages published from the UI are stored with
   `origin: ui` so they can be told apart from broker traffic.
3. **Payloads are untrusted input.** They are escaped in the UI, parsed defensively (JSON parse
   failures fall back to text or binary), and capped by `max_payload_bytes` before storage.
4. **Broker credentials** live in plain text in the SQLite `settings` table; `GET /api/settings`
   masks `mqtt_pass`, but the file itself is readable by anyone with access to the `data/`
   directory. Protect that directory. To rotate the password, change it on the broker first, then
   update `mqtt_pass` in Settings — mqttscope reconnects with the new value.
5. **Least privilege on the broker.** The MQTT user only needs subscribe rights on `#` and
   `$SYS/#` (or whatever `mqtt_subscriptions` lists). Grant publish rights only if you use the
   Publish feature, and scope them to the topics you intend to write.
6. **Resource bounds** are part of the security posture: SSE streams are capped
   (`sse_max_clients`, `sse_queue_size`, `sse_idle_timeout_s`), the ingest drops its backlog past
   `ingest_max_backlog`, the topic registry evicts past `max_topics`, and the database never grows
   past `max_db_bytes`. See [`configuration.md`](configuration.md).

Report vulnerabilities by opening an issue on GitHub or, for anything sensitive, by contacting me
through my GitHub profile first.
