# Academy Manager — operator console

This branch holds ONLY the console: `index.html`, its stylesheet and the
branding images. It is the GitHub Pages publishing source, so anything
committed here is on the open web.

Nothing else from the platform repo belongs on this branch. Pages serves
whatever it can see, and `main` carries migrations, `PLATFORM.md`,
`prompts/` and `scripts/` — none of which should be world-readable even
though none of them holds a credential.

**Never add `value=` to the sign-in inputs.** On 2026-08-05 the operator
password was prefilled here and on CourtSync, and went public on both.
That is why the console came down. The console is safe to publish only
because it ships no secret: the key in `index.html` is the Supabase
`anon` key, which is public by design, and the gate requires an account
whose `am_role` is `operator`.
