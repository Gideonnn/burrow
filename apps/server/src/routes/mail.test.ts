import { messageDetail, messageSummary } from '@burrow/contracts';
import { describe, expect, it } from 'vitest';
import { z } from 'zod';
import { testHousehold } from '../testing';

function setup() {
  const h = testHousehold();
  const gideon = h.person('Gideon');
  const eva = h.person('Eva');
  const home = h.mailbox(gideon.id, 'gideon@example.com');
  const evas = h.mailbox(eva.id, 'eva@example.com');
  return { ...h, gideon, eva, home, evas };
}

const list = z.array(messageSummary);

async function syncAndList(
  h: ReturnType<typeof setup>,
  token: string,
  mailboxId: string,
  folder = 'inbox',
) {
  await h.call(token, `/api/mailboxes/${mailboxId}/sync`, { method: 'POST' });
  return list.parse(
    await (
      await h.call(
        token,
        `/api/mailboxes/${mailboxId}/messages?folder=${folder}`,
      )
    ).json(),
  );
}

describe('sync and list', () => {
  it('stores new inbox mail, newest first, and reports it as arrived', async () => {
    const h = setup();
    const token = h.key(h.gideon.id, ['read']);
    h.provider(h.home.id).deliver({
      subject: 'Old',
      receivedAt: new Date('2026-10-18T08:00:00Z'),
    });
    h.provider(h.home.id).deliver({
      subject: 'New',
      receivedAt: new Date('2026-10-19T08:00:00Z'),
    });
    const inbox = await syncAndList(h, token, h.home.id);
    expect(inbox.map((m) => m.subject)).toEqual(['New', 'Old']);
    expect(h.arrived).toHaveLength(2);
  });

  it('does not report the same mail as arrived twice', async () => {
    const h = setup();
    const token = h.key(h.gideon.id, ['read']);
    h.provider(h.home.id).deliver({ subject: 'Once' });
    await syncAndList(h, token, h.home.id);
    await syncAndList(h, token, h.home.id);
    expect(h.arrived).toHaveLength(1);
  });

  it('hides another person’s mailbox as if it did not exist', async () => {
    const h = setup();
    const token = h.key(h.gideon.id, ['read']);
    h.provider(h.evas.id).deliver({ subject: 'Private' });
    expect(
      (await h.call(token, `/api/mailboxes/${h.evas.id}/messages`)).status,
    ).toBe(404);
    expect(
      (
        await h.call(token, `/api/mailboxes/${h.evas.id}/sync`, {
          method: 'POST',
        })
      ).status,
    ).toBe(404);

    const evaKey = h.key(h.eva.id, ['read']);
    const [message] = await syncAndList(h, evaKey, h.evas.id);
    expect((await h.call(token, `/api/messages/${message!.id}`)).status).toBe(
      404,
    );
  });
});

describe('actions', () => {
  it('archives at the provider first, then locally', async () => {
    const h = setup();
    const token = h.key(h.gideon.id, ['read', 'organize']);
    h.provider(h.home.id).deliver({ subject: 'Newsletter' });
    const [message] = await syncAndList(h, token, h.home.id);

    const res = await h.call(token, `/api/messages/${message!.id}/actions`, {
      method: 'POST',
      body: JSON.stringify({ ops: [{ op: 'archive' }, { op: 'markRead' }] }),
    });
    expect(messageDetail.parse(await res.json())).toMatchObject({
      folder: 'archive',
      unread: false,
    });
    expect(h.provider(h.home.id).applied).toHaveLength(1);
    expect(await syncAndList(h, token, h.home.id)).toEqual([]);
  });

  it('leaves the local copy alone when the provider refuses', async () => {
    const h = setup();
    const token = h.key(h.gideon.id, ['read', 'organize']);
    h.provider(h.home.id).deliver({ subject: 'Keep me' });
    const [message] = await syncAndList(h, token, h.home.id);
    h.provider(h.home.id).failNextApply = true;
    const res = await h.call(token, `/api/messages/${message!.id}/actions`, {
      method: 'POST',
      body: JSON.stringify({ ops: [{ op: 'archive' }] }),
    });
    expect(res.status).toBe(502);
    expect(await syncAndList(h, token, h.home.id)).toHaveLength(1);
  });

  it('need the organize right', async () => {
    const h = setup();
    const token = h.key(h.gideon.id, ['read']);
    h.provider(h.home.id).deliver({ subject: 'x' });
    const [message] = await syncAndList(h, token, h.home.id);
    const res = await h.call(token, `/api/messages/${message!.id}/actions`, {
      method: 'POST',
      body: JSON.stringify({ ops: [{ op: 'archive' }] }),
    });
    expect(res.status).toBe(403);
  });
});

describe('send', () => {
  it('sends from the mailbox with threading for a reply', async () => {
    const h = setup();
    const token = h.key(h.gideon.id, ['read', 'send']);
    h.provider(h.home.id).deliver({
      subject: 'Question',
      headers: { messageId: '<q@example.com>' },
    });
    const [message] = await syncAndList(h, token, h.home.id);
    const res = await h.call(token, '/api/send', {
      method: 'POST',
      body: JSON.stringify({
        mailboxId: h.home.id,
        to: [{ email: 'someone@example.com' }],
        subject: 'Re: Question',
        body: 'Answer',
        inReplyTo: message!.id,
      }),
    });
    expect(res.status).toBe(202);
    const [sent] = h.provider(h.home.id).sent;
    expect(sent?.from.email).toBe('gideon@example.com');
    expect(sent?.replyTo?.headers.messageId).toBe('<q@example.com>');
  });

  it('needs the send right', async () => {
    const h = setup();
    const token = h.key(h.gideon.id, ['read', 'organize', 'draft']);
    const res = await h.call(token, '/api/send', {
      method: 'POST',
      body: JSON.stringify({
        mailboxId: h.home.id,
        to: [{ email: 'a@example.com' }],
        subject: 's',
        body: 'b',
      }),
    });
    expect(res.status).toBe(403);
  });

  it('cannot send from someone else’s mailbox', async () => {
    const h = setup();
    const token = h.key(h.gideon.id, ['send']);
    const res = await h.call(token, '/api/send', {
      method: 'POST',
      body: JSON.stringify({
        mailboxId: h.evas.id,
        to: [{ email: 'a@example.com' }],
        subject: 's',
        body: 'b',
      }),
    });
    expect(res.status).toBe(404);
  });
});
