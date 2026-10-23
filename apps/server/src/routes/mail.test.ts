import {
  attachmentSummary,
  folderCounts,
  messageDetail,
  messageSummary,
} from '@burrow/contracts';
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

describe('counts', () => {
  async function counts(h: ReturnType<typeof setup>, token: string) {
    const res = await h.call(token, '/api/mailboxes/counts');
    expect(res.status).toBe(200);
    return folderCounts.parse(await res.json());
  }

  it('counts every unread inbox message, not only the newest page', async () => {
    const h = setup();
    const token = h.key(h.gideon.id, ['read', 'organize']);
    for (let i = 0; i < 130; i++) {
      h.provider(h.home.id).deliver({
        subject: `Mail ${i}`,
        unread: i < 120,
        receivedAt: new Date(Date.UTC(2026, 9, 1, 0, i)),
      });
    }
    h.provider(h.home.id).deliver({ subject: 'Archived', folder: 'archive' });
    const [newest] = await syncAndList(h, token, h.home.id);
    await h.call(token, `/api/messages/${newest!.id}/actions`, {
      method: 'POST',
      body: JSON.stringify({ ops: [{ op: 'archive' }] }),
    });

    expect(
      (await counts(h, token)).toSorted((a, b) =>
        a.folder.localeCompare(b.folder),
      ),
    ).toEqual([
      { mailboxId: h.home.id, folder: 'archive', total: 2, unread: 1 },
      { mailboxId: h.home.id, folder: 'inbox', total: 129, unread: 120 },
    ]);
  });

  it('only counts the mailboxes the key may see', async () => {
    const h = setup();
    const work = h.mailbox(h.gideon.id, 'gideon@work.example.com');
    h.provider(h.home.id).deliver({ subject: 'Home' });
    h.provider(work.id).deliver({ subject: 'Work' });
    h.provider(h.evas.id).deliver({ subject: 'Eva' });
    const all = h.key(h.gideon.id, ['read']);
    await syncAndList(h, all, h.home.id);
    await syncAndList(h, all, work.id);
    await syncAndList(h, h.key(h.eva.id, ['read']), h.evas.id);

    const homeOnly = h.key(h.gideon.id, ['read'], [h.home.id]);
    expect((await counts(h, homeOnly)).map((c) => c.mailboxId)).toEqual([
      h.home.id,
    ]);
    expect((await counts(h, all)).map((c) => c.mailboxId).toSorted()).toEqual(
      [h.home.id, work.id].toSorted(),
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

describe('attachments', () => {
  const LOGO = 'AAMk/logo+1=';

  async function withFiles(h: ReturnType<typeof setup>, token: string) {
    h.provider(h.home.id).deliver({
      subject: 'Offerte',
      attachments: [
        {
          name: 'offerte 2026 (één).pdf',
          contentType: 'application/pdf',
          data: '%PDF-1.4!',
        },
        {
          id: LOGO,
          name: 'logo.png',
          contentType: 'image/png',
          inline: true,
          data: 'PNG!',
        },
        { name: 'scan.tiff', contentType: 'image/tiff', size: 30e6, data: '' },
      ],
    });
    const [message] = await syncAndList(h, token, h.home.id);
    return message!.id;
  }

  it('lists the files of a message without their content', async () => {
    const h = setup();
    const token = h.key(h.gideon.id, ['read']);
    const id = await withFiles(h, token);
    const res = await h.call(token, `/api/messages/${id}/attachments`);
    expect(z.array(attachmentSummary).parse(await res.json())).toEqual([
      {
        id: 'att1',
        name: 'offerte 2026 (één).pdf',
        contentType: 'application/pdf',
        size: 9,
        inline: false,
      },
      {
        id: LOGO,
        name: 'logo.png',
        contentType: 'image/png',
        size: 4,
        inline: true,
      },
      {
        id: 'att3',
        name: 'scan.tiff',
        contentType: 'image/tiff',
        size: 30e6,
        inline: false,
      },
    ]);
  });

  it('downloads one as a file the browser will not render', async () => {
    const h = setup();
    const token = h.key(h.gideon.id, ['read']);
    const id = await withFiles(h, token);
    const res = await h.call(token, `/api/messages/${id}/attachments/att1`);
    expect(res.status).toBe(200);
    expect(await res.text()).toBe('%PDF-1.4!');
    expect(res.headers.get('content-type')).toBe('application/pdf');
    expect(res.headers.get('content-disposition')).toBe(
      "attachment; filename*=UTF-8''offerte%202026%20%28%C3%A9%C3%A9n%29.pdf",
    );
    expect(res.headers.get('x-content-type-options')).toBe('nosniff');

    const logo = await h.call(
      token,
      `/api/messages/${id}/attachments/${encodeURIComponent(LOGO)}`,
    );
    expect(await logo.text()).toBe('PNG!');
  });

  it('refuses a file above 25 MB without downloading it', async () => {
    const h = setup();
    const token = h.key(h.gideon.id, ['read']);
    const id = await withFiles(h, token);
    const res = await h.call(token, `/api/messages/${id}/attachments/att3`);
    expect(res.status).toBe(413);
    expect(await res.text()).toContain('25 MB');
  });

  it('answers 404 for another person’s message and an unknown file', async () => {
    const h = setup();
    const id = await withFiles(h, h.key(h.gideon.id, ['read']));
    const eva = h.key(h.eva.id, ['read']);
    for (const path of ['attachments', 'attachments/att1']) {
      expect((await h.call(eva, `/api/messages/${id}/${path}`)).status).toBe(
        404,
      );
    }
    const gideon = h.key(h.gideon.id, ['read']);
    expect(
      (await h.call(gideon, `/api/messages/${id}/attachments/nope`)).status,
    ).toBe(404);
    expect(
      (await h.call(gideon, '/api/messages/nope/attachments')).status,
    ).toBe(404);
  });

  it('are content, so a facts-only key gets 403', async () => {
    const h = setup();
    const id = await withFiles(h, h.key(h.gideon.id, ['read']));
    const facts = h.key(h.gideon.id, ['read'], null, true);
    for (const path of ['attachments', 'attachments/att1']) {
      expect((await h.call(facts, `/api/messages/${id}/${path}`)).status).toBe(
        403,
      );
    }
  });
});
