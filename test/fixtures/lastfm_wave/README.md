Public Deezer search responses captured 2026-11-11 via the actual upstream
`sources/deezer/index.js` customSearch function (Deezer extension 1.3.11):
https://github.com/mornyeapp/Mornye-Extension/blob/main/sources/deezer/index.js

The JS ran in a local VM with real HTTPS requests to api.deezer.com, with
`filter: track, limit: 20`. Only track identity and duration fields are retained.
The phone's installed extension version may differ.

`Slipknot Duality` returns live/cover candidates but no exact studio recording;
`Duality` returns Slipknot's exact recording first. Korn is spelled KoЯn in
Deezer metadata. Psychosocial already matches the first query.
