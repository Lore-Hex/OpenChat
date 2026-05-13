# OpenChat: AGPL CometChat-compatible drop-in endpoint

OpenChat is a BEAM/Elixir replacement for the covered subset of CometChat. It is designed for a URL-swizzled CometChat JavaScript SDK to call directly, without changing call sites such as `CometChat.login`, `CometChat.sendMessage`, `MessagesRequestBuilder`, `ConversationsRequestBuilder`, message listeners, and reaction calls.

**License:** AGPL-3.0-or-later.

## API coverage matrix

### Covered APIs

| Area | SDK/API surface | Routes | Coverage |
|---|---|---|---|
| Settings and auth | SDK init settings, `CometChat.login(authToken)`, `getLoggedinUser`, logout token revocation | `GET /settings`, `POST /users/:uid/auth_tokens`, `POST /admin/users/auth`, `DELETE /admin/users/auth/:authToken`, `GET /me`, `PUT /me`, `DELETE /me` | Covered by ExUnit API tests and Playwright SDK contract tests. `PUT /me` returns the user, authToken, jwt/fat placeholders, wsChannel, and SDK settings. |
| Local JWT and sessions | SDK session/JWT compatibility payloads | `POST /me/jwt`, `POST /user_sessions` | Covered by ExUnit API tests. These are local compatibility payloads, not CometChat-issued credentials. |
| Users | List, search, paginate, create, update, deactivate, reactivate, fetch with block state | `GET /users`, `POST /users`, `PUT /users`, `GET /users/:uid`, `PUT /users/:uid`, `DELETE /users/:uid` | Covered by store and API regression tests. |
| Blocks | Block, unblock, list blocked users, `blockedByMe`, `hasBlockedMe` | `GET /blockedusers`, `POST /blockedusers`, `DELETE /blockedusers` | Covered by ExUnit API tests and Playwright SDK contract tests. |
| Groups and membership | List, search, paginate, create, update, fetch, delete, join public/password groups, member list, add/remove members, update scopes | `GET /groups`, `POST /groups`, `GET /groups/:guid`, `PUT /groups/:guid`, `DELETE /groups/:guid`, `GET /groups/:guid/members`, `POST /groups/:guid/members`, `PUT /groups/:guid/members`, `DELETE /groups/:guid/members`, `PUT /groups/:guid/members/:uid`, `DELETE /groups/:guid/members/:uid` | Covered by store/API/Redis tests and SDK group join contract tests. |
| Group bans | Ban, unban, list/search banned users | `GET /groups/:guid/bannedusers`, `POST /groups/:guid/bannedusers/:uid`, `DELETE /groups/:guid/bannedusers/:uid` | Covered by API regression and Redis cleanup tests. |
| Messages | Text, custom, media-shaped messages, multipart media upload, admin sends, validation, deterministic pagination, cursor metadata | `POST /messages`, `GET /users/:uid/messages`, `GET /groups/:guid/messages`, `GET /messages/:messageId`, `GET /user/messages/:muid` | Covered by store tests, API tests, media upload tests, and Playwright SDK contract tests. |
| Threads | Send replies and fetch thread messages | `POST /messages/:parentId/thread`, `GET /messages/:parentId/thread` | Covered by API regression tests. |
| Message actions | Edit/delete action messages and hidden deleted-message fetch behavior | `PUT /messages/:messageId`, `DELETE /messages/:messageId` | Covered by store/API tests and SDK delete contract tests. |
| Unread and read state | Unread count fetches, mark read, mark unread, read cursor rewind | `GET /messages?unread=1&count=1`, `POST /users/:uid/conversation/read`, `POST /groups/:guid/conversation/read`, `DELETE /users/:uid/conversation/read`, `DELETE /groups/:guid/conversation/read` | Covered by store/API tests and WebSocket receipt tests. SDK v4 can also send read receipts over WebSocket, which update read state. |
| Conversations | List conversations, fetch user/group conversation, hide a conversation for the current user, delete a conversation by canonical conversation id | `GET /conversations`, `GET /users/:uid/conversation`, `GET /groups/:guid/conversation`, `DELETE /users/:uid/conversation`, `DELETE /groups/:guid/conversation`, `DELETE /conversations/:conversationId` | Covered by store/API/Redis tests and SDK conversation contract tests. |
| Reactions | Native reaction add/remove/list/filter and `callExtension("reactions", ...)` fallback | `POST /messages/:messageId/reactions/:reaction`, `DELETE /messages/:messageId/reactions/:reaction`, `GET /messages/:messageId/reactions`, `GET /messages/:messageId/reactions/:reaction`, `MATCH /extensions/:name/*path`, `MATCH /v1/*path` | Covered by store/API tests. The real SDK extension contract is optional and requires wildcard HTTPS DNS. |
| Media serving | Serve uploaded media files | `GET /media/:file` | Covered by API regression tests. |
| WebSocket | SDK auth event, message/action/reaction broadcasts, read receipts, ping/malformed frame handling | `/`, `/ws`, `/socket` | Covered by WebSocket handler tests. |

### Partial, stubbed, or not-done APIs

| Area | Routes/API | Current behavior | Status |
|---|---|---|---|
| Delivery receipts | `POST /users/:uid/conversation/delivered`, `POST /groups/:guid/conversation/delivered` | Returns success in the SDK shape. It does not persist a delivered cursor or broadcast delivered events. | Stub |
| Generic message list | `GET /messages` without `unread=1&count=1` | Returns an empty list. Use `GET /users/:uid/messages`, `GET /groups/:guid/messages`, or thread routes for real message history. | Partial |
| Extensions beyond reactions | `MATCH /extensions/:name/*path`, extension-host fallback | All extension calls are interpreted as reaction add/remove requests. Non-reaction extensions are not implemented. | Partial |
| SDK sessions and JWTs | `POST /user_sessions`, `POST /me/jwt` | Returns local compatibility payloads only. There is no external CometChat session registry or signed CometChat JWT issuer. | Partial |
| Broader CometChat product areas | Calls, typing indicators, live presence/occupancy, push notifications, moderation workflows, webhooks, roles, polls, message translations | No route-level implementation unless listed in the covered matrix above. | Not done |

## WebSocket

The SDK builds the WebSocket URL from the `/me` settings as:

```text
wss://<CHAT_HOST>:<CHAT_WSS_PORT>
```

OpenChat accepts WebSocket connections at `/`, `/ws`, and `/socket`. It handles the SDK auth event, broadcasts messages/actions/reactions, and processes read receipts.

## Important compatibility note

This implementation targets the inspected JavaScript SDK wire shape for `@cometchat/chat-sdk-javascript@4.1.8`. CometChat does not publish a stable public REST contract for every SDK-internal endpoint. Pin the SDK version in production and run the contract harness before upgrading.

## Local development

```bash
mix deps.get
mix test
PORT=4000 PUBLIC_HOST=localhost PUBLIC_WS_PORT=8443 mix run --no-halt
```

The JavaScript SDK always uses HTTPS for overridden hosts, so the contract harness expects a TLS reverse proxy. The supplied Docker Compose includes Caddy in front of the Elixir service.
Compose publishes Caddy on both `https://localhost` and `https://localhost:8443`; the SDK uses `localhost:8443` for the initial override and the advertised production-style `localhost:443` settings for follow-on REST/WebSocket calls.

```bash
docker compose up --build
cd contract
npm install
OPENCHAT_TARGET_HOST=localhost:8443/v3.0 npm test
```

For local Playwright, Caddy uses an internal/self-signed certificate and the Playwright config ignores HTTPS errors.

## App-side URL swizzle

If you can adjust only the CometChat app settings creation, point both SDK hosts at the replacement:

```js
const appSettings = new CometChat.AppSettingsBuilder()
  .setRegion("us")
  .overrideClientHost("chat.example.com/v3.0")
  .overrideAdminHost("chat.example.com/v3.0")
  .autoEstablishSocketConnection(true)
  .build();

await CometChat.init(APP_ID, appSettings);
```

All existing CometChat method calls remain the same.

For a literal zero-code swizzle, deploy TLS and DNS so the SDK's existing CometChat hostnames resolve to this service. That is usually harder operationally than using `overrideClientHost`/`overrideAdminHost`.

## Runtime configuration

| Variable | Default | Purpose |
|---|---:|---|
| `PORT` | `4000` | HTTP port the Elixir app listens on |
| `PUBLIC_HOST` | `localhost` | Host returned to SDK in `/me.settings.CHAT_HOST` |
| `PUBLIC_WS_PORT` | `PORT` | Port returned as `/me.settings.CHAT_WSS_PORT` |
| `COMETCHAT_APP_ID` | `local-app` | App ID accepted/reported by the clone |
| `COMETCHAT_API_KEY` | `local-api-key` | Optional admin API key if you choose to enforce it |
| `COMETCHAT_REGION` | `us` | Region returned to SDK settings |
| `EXTENSION_DOMAIN` | `PUBLIC_HOST` | Extension domain used by `callExtension` URL generation |
| `REDIS_URL` | unset | Optional Redis URL for durable per-record storage |
| `REDIS_KEY_PREFIX` | `open_chat` | Redis namespace prefix for record keys, indexes, and counters |
| `REDIS_SNAPSHOT_KEY` | `open_chat:snapshot:v1` | Legacy import key for older single-snapshot deployments |
| `SEED_USERS_JSON` | built-in Alice/Bob/Carol | Initial users. List or map. Users may include `authToken`. |
| `SEED_GROUPS_JSON` | built-in public `lobby` | Initial groups. List or map. |
| `ACCEPT_UID_TOKENS` | `true` | Accept `uid:<uid>` tokens for local/dev and contract tests |
| `UPLOAD_DIR` | `priv/static/uploads` | Uploaded media storage directory |
| `PUBLIC_MEDIA_BASE_URL` | unset | Absolute media URL base; otherwise `/media/<file>` |

## Persistence strategy

By default all state is in one OTP GenServer. If `REDIS_URL` is set, each mutation is also persisted into Redis as per-record keys under `REDIS_KEY_PREFIX`:

- `open_chat:users:<uid>`
- `open_chat:tokens:<authToken>`
- `open_chat:groups:<guid>`
- `open_chat:members:<guid>`
- `open_chat:messages:<messageId>`
- `open_chat:conversation_messages:<conversationId>`
- `open_chat:thread_messages:<parentMessageId>`
- `open_chat:reads:<uid>`
- `open_chat:hidden_conversations:<uid>`
- `open_chat:reactions:<messageId>`
- `open_chat:blocks:<uid>`
- `open_chat:banned:<guid>`
- `open_chat:counter:<counterName>`
- `open_chat:index:<bucket>` sets for reloadable key discovery

On startup, OpenChat reloads state from those Redis keys. Normal mutations write only the touched records, indexes, and counters; reset and legacy imports replace the namespace. If no per-key namespace has been initialized but `REDIS_SNAPSHOT_KEY` exists, OpenChat imports that legacy JSON snapshot into the per-key layout.

Redis writes are per operation and per key, but one OTP GenServer still serializes mutation ordering. For horizontal write scale, split write ownership by entity or move command handlers to Redis/Postgres with optimistic concurrency while preserving the same route/test contract.

## AWS deployment sketch

Use one of these patterns:

1. **ECS/Fargate + ALB + ElastiCache Redis**
   - ALB terminates TLS for `chat.example.com` and, if using `callExtension`, `*.chat.example.com`.
   - ALB forwards HTTP and WebSocket upgrades to the service on `PORT=4000`.
  - ElastiCache Redis set as `REDIS_URL` for durable per-record storage.

2. **EC2/ASG + Caddy/Nginx + Redis**
   - Caddy/Nginx terminates TLS and proxies `/v3.0/*`, `/media/*`, and `/` WebSocket traffic to the BEAM app.

Recommended env for ALB/Fargate:

```text
PORT=4000
PUBLIC_HOST=chat.example.com
PUBLIC_WS_PORT=443
COMETCHAT_APP_ID=<your app id>
COMETCHAT_REGION=us
EXTENSION_DOMAIN=chat.example.com
REDIS_URL=redis://<elasticache-endpoint>:6379/0
```

## Test matrix

### ExUnit unit/API tests

- Auth token login and `getLoggedinUser` payload compatibility
- Admin token generation
- User and group message send/fetch
- Group join and group message membership checks
- Text/custom/media-shaped messages
- Message edit/delete action payloads
- Conversations and unread counts
- Read/unread transitions
- Native reactions

### Playwright contract tests against the real SDK

- `CometChat.init` with overridden hosts
- `CometChat.login(authToken)` and `CometChat.getLoggedinUser()`
- `CometChat.TextMessage` + `sendMessage`
- `MessagesRequestBuilder().setUID().fetchPrevious()`
- `ConversationsRequestBuilder().fetchNext()`
- `getUnreadMessageCountForAllUsers()`
- `markAsRead(message)`
- `deleteMessage(messageId)`
- `CustomMessage`, `MediaMessage`, `joinGroup`, and native reactions
- Optional `callExtension` reaction contract when wildcard extension DNS is configured
