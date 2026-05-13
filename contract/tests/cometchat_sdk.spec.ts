import { test, expect } from '@playwright/test';
import path from 'node:path';
import { createRequire } from 'node:module';

const require = createRequire(import.meta.url);
const sdkPath = require.resolve('@cometchat/chat-sdk-javascript/CometChat.js');

const APP_ID = process.env.COMETCHAT_APP_ID || 'local-app';
const TARGET_HOST = process.env.OPENCHAT_TARGET_HOST || 'localhost:8443/v3.0';
const ALICE_TOKEN = process.env.ALICE_TOKEN || 'uid:alice';
const BOB_TOKEN = process.env.BOB_TOKEN || 'uid:bob';

async function loadSdk(page: any, autoSocket = false) {
  await page.goto(`https://${TARGET_HOST}/settings`);
  await page.setContent('<!doctype html><html><head></head><body></body></html>');
  await page.addScriptTag({ path: sdkPath });
  await page.evaluate(async ({ appId, targetHost, autoSocket }) => {
    const { CometChat } = window as any;
    const settings = new CometChat.AppSettingsBuilder()
      .setRegion('us')
      .overrideClientHost(targetHost)
      .overrideAdminHost(targetHost)
      .autoEstablishSocketConnection(autoSocket)
      .build();
    await CometChat.init(appId, settings);
  }, { appId: APP_ID, targetHost: TARGET_HOST, autoSocket });
}

test('real CometChat SDK can init, login(authToken), and getLoggedinUser', async ({ page }) => {
  await loadSdk(page, false);
  const user = await page.evaluate(async (token) => {
    const { CometChat } = window as any;
    const u = await CometChat.login(token);
    const cached = await CometChat.getLoggedinUser();
    return { uid: u.getUid(), cachedUid: cached.getUid(), name: u.getName() };
  }, ALICE_TOKEN);

  expect(user.uid).toBe('alice');
  expect(user.cachedUid).toBe('alice');
});

test('text messages, message request builder, conversations, unread, read, delete', async ({ browser }) => {
  const alice = await browser.newPage();
  await loadSdk(alice, false);

  const sent = await alice.evaluate(async (token) => {
    const { CometChat } = window as any;
    await CometChat.login(token);
    const m = new CometChat.TextMessage('bob', 'contract hello ' + Date.now(), 'user');
    const sent = await CometChat.sendMessage(m);
    return { id: sent.getId(), text: sent.getData().text, sentAt: sent.getSentAt(), sender: sent.getSender().getUid() };
  }, ALICE_TOKEN);

  expect(sent.sender).toBe('alice');
  expect(sent.text).toContain('contract hello');

  const bob = await browser.newPage();
  await loadSdk(bob, true);
  const fetched = await bob.evaluate(async ({ token, msgId }) => {
    const { CometChat } = window as any;
    await CometChat.login(token);
    await new Promise((resolve) => setTimeout(resolve, 500));
    const req = new CometChat.MessagesRequestBuilder().setUID('alice').setLimit(20).build();
    const messages = await req.fetchPrevious();
    const found = messages.find((m: any) => String(m.getId()) === String(msgId));
    const unread = await CometChat.getUnreadMessageCountForAllUsers();
    await CometChat.markAsRead(found);
    const convReq = new CometChat.ConversationsRequestBuilder().setLimit(20).setConversationType('user').build();
    const conversations = await convReq.fetchNext();
    await CometChat.deleteMessage(msgId);
    return {
      foundText: found.getData().text,
      foundSender: found.getSender().getUid(),
      unreadFromAlice: unread.alice || unread.users?.alice || 0,
      conversationCount: conversations.length,
    };
  }, { token: BOB_TOKEN, msgId: sent.id });

  expect(fetched.foundText).toBe(sent.text);
  expect(fetched.foundSender).toBe('alice');
  expect(fetched.unreadFromAlice).toBeGreaterThanOrEqual(1);
  expect(fetched.conversationCount).toBeGreaterThanOrEqual(1);
});

test('custom messages, media messages, group join, and native reactions', async ({ page }) => {
  await loadSdk(page, false);

  const result = await page.evaluate(async (token) => {
    const { CometChat } = window as any;
    await CometChat.login(token);

    const custom = new CometChat.CustomMessage('bob', 'user', 'ChatMessage', { feature: 'contract-custom' });
    const customSent = await CometChat.sendCustomMessage(custom);

    const file = new File([new Blob(['tiny image payload'], { type: 'image/png' })], 'tiny.png', { type: 'image/png' });
    const media = new CometChat.MediaMessage('bob', file, CometChat.MESSAGE_TYPE.IMAGE, 'user');
    media.setCaption('tiny image');
    const mediaSent = await CometChat.sendMediaMessage(media);

    await CometChat.joinGroup('lobby', CometChat.GROUP_TYPE.PUBLIC, '');
    const groupMsg = new CometChat.TextMessage('lobby', 'group contract ' + Date.now(), 'group');
    const groupSent = await CometChat.sendMessage(groupMsg);

    const reacted = await CometChat.addReaction(customSent.getId(), '👍');

    return {
      customData: customSent.getData().customData,
      mediaCaption: mediaSent.getCaption(),
      mediaUrl: mediaSent.getData().url,
      groupReceiver: groupSent.getReceiverId(),
      reactions: reacted.getReactions().map((r: any) => ({ reaction: r.getReaction(), count: r.getCount() })),
    };
  }, ALICE_TOKEN);

  expect(result.customData.feature).toBe('contract-custom');
  expect(result.mediaCaption).toBe('tiny image');
  expect(result.mediaUrl).toBeTruthy();
  expect(result.groupReceiver).toBe('lobby');
  expect(result.reactions[0].reaction).toBe('👍');
});

test('blocked users APIs used by Hangout settings and DM flows', async ({ page }) => {
  await loadSdk(page, false);

  const result = await page.evaluate(async (token) => {
    const { CometChat } = window as any;
    await CometChat.login(token);

    await CometChat.blockUsers(['bob']);
    const bob = await CometChat.getUser('bob');
    const request = new CometChat.BlockedUsersRequestBuilder()
      .setLimit(100)
      .blockedByMe()
      .build();
    const blocked = await request.fetchNext();
    await CometChat.unblockUsers(['bob']);

    return {
      blockedByMe: bob.getBlockedByMe(),
      hasBlockedMe: bob.getHasBlockedMe(),
      blockedUids: blocked.map((user: any) => user.getUid()),
    };
  }, ALICE_TOKEN);

  expect(result.blockedByMe).toBe(true);
  expect(result.hasBlockedMe).toBe(false);
  expect(result.blockedUids).toContain('bob');
});

test('optional callExtension reaction contract', async ({ page }) => {
  test.skip(!process.env.RUN_EXTENSION_CONTRACT, 'Requires wildcard HTTPS DNS like reactions-us.example.com pointing at the same app.');
  await loadSdk(page, false);
  const out = await page.evaluate(async (token) => {
    const { CometChat } = window as any;
    await CometChat.login(token);
    const msg = await CometChat.sendMessage(new CometChat.TextMessage('bob', 'extension contract', 'user'));
    const data = await CometChat.callExtension('reactions', 'POST', 'v1/react', { messageId: msg.getId(), reaction: '🔥', action: 'add' });
    return data.data ? data.data : data;
  }, ALICE_TOKEN);
  expect(out).toBeTruthy();
});
