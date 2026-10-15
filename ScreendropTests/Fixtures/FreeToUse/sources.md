# Free To Use responses

Saved on 2026-10-15 with three GET requests, no audio downloads. These are the
original JSON responses, with no catalogue cache or API key:

- `categories-page-1.json`: https://api.freetouse.com/v3/music/categories/all?limit=50&offset=0
- `categories-page-2.json`: https://api.freetouse.com/v3/music/categories/all?limit=50&offset=50
- `search-instrumental.json`: https://api.freetouse.com/v3/music/tracks/search?query=instrumental&limit=5&offset=0

The tests change selected fields in memory to check premium filtering, unsafe
media URLs, ordered artists/tags, pagination and invalid responses. The saved
responses remain unchanged. Tests use URLProtocol and never contact the service.
