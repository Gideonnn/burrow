import {
  outing,
  outingSuggestion,
  outingsResponse,
  searchResponse,
} from '@burrow/contracts';
import { describe, expect, it } from 'vitest';
import { testHousehold } from '../testing';

const ORDER_HTML = `<html><head><script type="application/ld+json">${JSON.stringify(
  {
    '@type': 'EventReservation',
    reservationNumber: 'KL-48291',
    broker: { name: 'Kaartloket' },
    reservationFor: {
      '@type': 'MusicEvent',
      name: 'Neon Nineties',
      startDate: '2027-05-13T21:00:00+02:00',
      location: { name: 'Voorbeeldhal' },
    },
  },
)}</script></head><body><p>Bedankt voor je bestelling.</p></body></html>`;

function setup() {
  const h = testHousehold();
  const gideon = h.person('Gideon');
  const eva = h.person('Eva');
  const home = h.mailbox(gideon.id, 'gideon@example.com');
  const token = h.key(gideon.id, ['read', 'organize']);
  const evaToken = h.key(eva.id, ['read', 'organize']);
  const send = (key: string, method: string, path: string, body?: unknown) =>
    h.call(key, path, {
      method,
      body: body === undefined ? undefined : JSON.stringify(body),
    });
  const create = async (key: string, body: Record<string, unknown> = {}) => {
    const res = await send(key, 'POST', '/api/outings', {
      title: 'Cabaret Theo Voorbeeld',
      startsAt: '2026-11-08T19:15:00.000Z',
      ...body,
    });
    expect(res.status).toBe(201);
    return outing.parse(await res.json());
  };
  const deliver = async (
    message: Parameters<ReturnType<typeof h.provider>['deliver']>[0],
  ) => {
    h.provider(home.id).deliver(message);
    return (await h.mail.sync(home.id))[0]!;
  };
  const upload = async (key: string, bytes: string) => {
    const { id } = (await (
      await send(key, 'POST', '/api/uploads', { size: bytes.length })
    ).json()) as { id: string };
    await h.call(key, `/api/uploads/${id}?offset=0`, {
      method: 'PUT',
      headers: { 'content-type': 'application/octet-stream' },
      body: bytes,
    });
    return id;
  };
  return {
    ...h,
    gideon,
    eva,
    home,
    token,
    evaToken,
    send,
    create,
    deliver,
    upload,
  };
}

describe('outings', () => {
  it("are the household's: what one adds, the other sees and changes", async () => {
    const s = setup();
    const made = await s.create(s.token, { kind: 'cabaret' });
    expect(made.createdBy.name).toBe('Gideon');
    expect(made.tasks.map((t) => t.kind)).toEqual(['calendar']);

    const list = outingsResponse.parse(
      await (await s.send(s.evaToken, 'GET', '/api/outings')).json(),
    );
    expect(list.map((o) => o.title)).toEqual(['Cabaret Theo Voorbeeld']);

    const moved = outing.parse(
      await (
        await s.send(s.evaToken, 'PATCH', `/api/outings/${made.id}`, {
          startsAt: '2026-11-08T19:30:00.000Z',
          venue: 'Stadsschouwburg Voorbeeld',
          inCalendar: true,
        })
      ).json(),
    );
    expect(moved).toMatchObject({
      startsAt: '2026-11-08T19:30:00.000Z',
      venue: 'Stadsschouwburg Voorbeeld',
      inCalendar: true,
      updatedBy: { name: 'Eva' },
    });
    expect(moved.tasks[0]).toMatchObject({
      kind: 'calendar',
      doneBy: { name: 'Eva' },
    });
  });

  it('needs organize to change, and read to look', async () => {
    const s = setup();
    const reader = s.key(s.gideon.id, ['read']);
    expect(
      (
        await s.send(reader, 'POST', '/api/outings', {
          title: 'X',
          startsAt: '2026-11-08T19:15:00.000Z',
        })
      ).status,
    ).toBe(403);
    const made = await s.create(s.token);
    expect(
      (await s.send(reader, 'GET', `/api/outings/${made.id}`)).status,
    ).toBe(200);
    expect((await s.send(s.token, 'GET', '/api/outings/nope')).status).toBe(
      404,
    );
  });

  it("reads an order mail, links it, and finds it by the outing's names", async () => {
    const s = setup();
    const messageId = await s.deliver({
      from: { name: 'Kaartloket', email: 'tickets@kaartloket.example.com' },
      subject: 'Je bestelling is gelukt',
      bodyText:
        'Bedankt voor je bestelling. Zet je tickets op naam vóór 29 april 2027.',
      bodyHtml: ORDER_HTML,
    });
    const suggestion = outingSuggestion.parse(
      await (
        await s.send(s.token, 'GET', `/api/messages/${messageId}/outing`)
      ).json(),
    );
    expect(suggestion).toMatchObject({
      outingId: null,
      confidence: 'structured',
      title: 'Neon Nineties',
      orderNumber: 'KL-48291',
    });

    const made = await s.create(s.token, {
      title: suggestion.title,
      startsAt: suggestion.startsAt,
      vendor: suggestion.vendor,
      orderNumber: suggestion.orderNumber,
      aliases: ["90's party"],
      personaliseBy: suggestion.personaliseBy,
      messageId: messageId,
    });
    expect(made.tasks.map((t) => t.kind)).toEqual(['calendar', 'personalise']);
    expect(made.mails).toMatchObject([
      { id: messageId, visible: true, subject: 'Je bestelling is gelukt' },
    ]);

    const again = outingSuggestion.parse(
      await (
        await s.send(s.token, 'GET', `/api/messages/${messageId}/outing`)
      ).json(),
    );
    expect(again.outingId).toBe(made.id);

    const found = searchResponse.parse(
      await (
        await s.send(
          s.token,
          'GET',
          `/api/search?q=${encodeURIComponent("90's party")}`,
        )
      ).json(),
    ).results;
    expect(found.map((m) => m.id)).toEqual([messageId]);
  });

  it('shows the other adult only that a linked mail exists', async () => {
    const s = setup();
    const messageId = await s.deliver({
      subject: 'Je bestelling is gelukt',
      bodyText: 'Bedankt.',
    });
    const made = await s.create(s.token, { messageId: messageId });
    const seen = outing.parse(
      await (await s.send(s.evaToken, 'GET', `/api/outings/${made.id}`)).json(),
    );
    expect(seen.mails).toEqual([
      expect.objectContaining({
        id: messageId,
        visible: false,
        subject: null,
        from: null,
        owner: expect.objectContaining({ name: 'Gideon' }),
      }),
    ]);
    // Eva cannot link Gideon's mail to anything, or read it as a suggestion.
    expect(
      (
        await s.send(s.evaToken, 'POST', `/api/outings/${made.id}/mails`, {
          messageId: messageId,
        })
      ).status,
    ).toBe(404);
    expect(
      (await s.send(s.evaToken, 'GET', `/api/messages/${messageId}/outing`))
        .status,
    ).toBe(404);
  });

  it('keeps tickets, and closes the deadline once every ticket is in a name', async () => {
    const s = setup();
    const made = await s.create(s.token, {
      personaliseBy: '2027-04-29T00:00:00.000Z',
    });
    const uploadId = await s.upload(s.token, '%PDF-1.4 ticket');
    const withTicket = outing.parse(
      await (
        await s.send(s.token, 'POST', `/api/outings/${made.id}/tickets`, {
          uploadId,
          name: 'kaart-1.pdf',
        })
      ).json(),
    );
    const [ticket] = withTicket.tickets;
    expect(ticket).toMatchObject({
      name: 'kaart-1.pdf',
      contentType: 'application/pdf',
      holder: null,
      personalised: false,
    });

    const file = await s.send(
      s.evaToken,
      'GET',
      `/api/outings/${made.id}/tickets/${ticket!.id}/file`,
    );
    expect(file.status).toBe(200);
    expect(file.headers.get('content-type')).toBe('application/pdf');
    expect(await file.text()).toBe('%PDF-1.4 ticket');

    const named = outing.parse(
      await (
        await s.send(
          s.evaToken,
          'PATCH',
          `/api/outings/${made.id}/tickets/${ticket!.id}`,
          { holder: 'Eva', personalised: true },
        )
      ).json(),
    );
    expect(named.tasks.find((t) => t.kind === 'personalise')).toMatchObject({
      doneBy: { name: 'Eva' },
    });
  });

  it('keeps the ticket attachments of the order mail in one click', async () => {
    const s = setup();
    const messageId = await s.deliver({
      from: { name: 'Kaartloket', email: 'tickets@kaartloket.example.com' },
      subject: 'Je bestelling is gelukt',
      bodyText: 'Je e-tickets zitten in de bijlage.',
      bodyHtml: ORDER_HTML,
      attachments: [
        {
          name: 'kaarten.pdf',
          contentType: 'application/pdf',
          data: '%PDF-1.4 two tickets',
        },
        {
          name: 'logo.png',
          contentType: 'image/png',
          data: 'png',
          inline: true,
        },
      ],
    });
    const suggestion = outingSuggestion.parse(
      await (
        await s.send(s.token, 'GET', `/api/messages/${messageId}/outing`)
      ).json(),
    );
    expect(suggestion.tickets.map((t) => t.name)).toEqual(['kaarten.pdf']);
    const made = await s.create(s.token, {
      title: suggestion.title,
      startsAt: suggestion.startsAt,
      messageId,
      attachmentIds: suggestion.tickets.map((t) => t.id),
    });
    expect(made.tickets).toMatchObject([
      { name: 'kaarten.pdf', contentType: 'application/pdf', messageId },
    ]);
    const file = await s.send(
      s.evaToken,
      'GET',
      `/api/outings/${made.id}/tickets/${made.tickets[0]!.id}/file`,
    );
    expect(await file.text()).toBe('%PDF-1.4 two tickets');
  });

  it('never gives a facts-only key the tickets', async () => {
    const s = setup();
    const made = await s.create(s.token);
    const uploadId = await s.upload(s.token, '%PDF-1.4 ticket');
    const withTicket = outing.parse(
      await (
        await s.send(s.token, 'POST', `/api/outings/${made.id}/tickets`, {
          uploadId,
          name: 'kaart.pdf',
        })
      ).json(),
    );
    const factsOnly = s.key(s.gideon.id, ['read'], null, true);
    expect(
      (
        await s.send(
          factsOnly,
          'GET',
          `/api/outings/${made.id}/tickets/${withTicket.tickets[0]!.id}/file`,
        )
      ).status,
    ).toBe(403);
  });

  it('keeps a checklist with who does what', async () => {
    const s = setup();
    const made = await s.create(s.token);
    const added = outing.parse(
      await (
        await s.send(s.token, 'POST', `/api/outings/${made.id}/tasks`, {
          title: 'Oppas regelen',
          assigneeId: s.eva.id,
          dueAt: '2026-11-01T00:00:00.000Z',
        })
      ).json(),
    );
    const task = added.tasks.find((t) => t.kind === 'custom')!;
    expect(task).toMatchObject({
      title: 'Oppas regelen',
      assignee: { name: 'Eva' },
      doneAt: null,
    });
    const done = outing.parse(
      await (
        await s.send(
          s.evaToken,
          'PATCH',
          `/api/outings/${made.id}/tasks/${task.id}`,
          { done: true },
        )
      ).json(),
    );
    expect(done.tasks.find((t) => t.id === task.id)).toMatchObject({
      doneBy: { name: 'Eva' },
    });
    const removed = outing.parse(
      await (
        await s.send(
          s.token,
          'DELETE',
          `/api/outings/${made.id}/tasks/${task.id}`,
        )
      ).json(),
    );
    expect(removed.tasks.map((t) => t.kind)).toEqual(['calendar']);
    expect(
      (await s.send(s.token, 'DELETE', `/api/outings/${made.id}`)).status,
    ).toBe(204);
    expect(
      (await s.send(s.token, 'GET', `/api/outings/${made.id}`)).status,
    ).toBe(404);
  });
});
