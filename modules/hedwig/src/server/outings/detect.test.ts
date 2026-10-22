import { describe, expect, it } from 'vitest';
import {
  datesIn,
  detectOuting,
  personaliseDeadline,
  ticketLinks,
} from './detect';

const base = {
  from: { name: 'Kaartloket', email: 'tickets@kaartloket.example.com' },
  receivedAt: new Date(2026, 9, 22, 10, 0),
  bodyHtml: null,
  attachments: [],
};

describe('detectOuting', () => {
  it('reads a ticket mail with attachments but no date it knows as likely, and leaves out the paperwork', () => {
    const input = {
      ...base,
      subject: 'Your ticket for Neon Nineties',
      bodyText: 'Je e-ticket zit in de bijlage. Tot zaterdag!',
      hasAttachments: true,
    };
    expect(detectOuting(input).confidence).toBe('likely');
    const found = detectOuting({
      ...input,
      attachments: [
        {
          id: '1',
          name: 'ticket.pdf',
          contentType: 'application/pdf',
          size: 90_000,
          inline: false,
        },
        {
          id: '2',
          name: 'Terms_of_use.pdf',
          contentType: 'application/pdf',
          size: 90_000,
          inline: false,
        },
        {
          id: '3',
          name: 'Invoice.pdf',
          contentType: 'application/pdf',
          size: 90_000,
          inline: false,
        },
        {
          id: '4',
          name: 'Mobile_ticket_1.png',
          contentType: 'image/png',
          size: 569,
          inline: false,
        },
      ],
    });
    expect(found.tickets.map((t) => t.name)).toEqual(['ticket.pdf']);
  });

  it('takes the name from a subject about tickets for it', () => {
    const found = detectOuting({
      ...base,
      subject:
        'Personaliseren van je ticket(s) voor Neon Nineties is voltooid.',
      bodyText: 'Je tickets zijn op naam gezet.',
    });
    expect(found.title).toBe('Neon Nineties');
    expect(found.confidence).toBe('likely');
  });

  it('reads a schema.org event reservation', () => {
    const html = `<html><head><script type="application/ld+json">${JSON.stringify(
      {
        '@context': 'http://schema.org',
        '@type': 'EventReservation',
        reservationNumber: 'KL-48291',
        broker: { '@type': 'Organization', name: 'Kaartloket' },
        reservationFor: {
          '@type': 'MusicEvent',
          name: 'Neon Nineties',
          startDate: '2027-05-13T21:00:00+02:00',
          doorTime: '2027-05-13T20:00:00+02:00',
          organizer: { name: 'Neon Events' },
          location: {
            '@type': 'Place',
            name: 'Voorbeeldhal',
            address: {
              streetAddress: 'Hallenweg 1',
              postalCode: '3500 AA',
              addressLocality: 'Utrecht',
            },
          },
        },
      },
    )}</script></head><body>Bedankt</body></html>`;
    const found = detectOuting({
      ...base,
      subject: 'Je bestelling',
      bodyText: 'Bedankt',
      bodyHtml: html,
    });
    expect(found).toMatchObject({
      confidence: 'structured',
      title: 'Neon Nineties',
      kind: 'concert',
      startsAt: '2027-05-13T19:00:00.000Z',
      doorsAt: '2027-05-13T18:00:00.000Z',
      venue: 'Voorbeeldhal',
      address: 'Hallenweg 1, 3500 AA Utrecht',
      organiser: 'Neon Events',
      vendor: 'Kaartloket',
      orderNumber: 'KL-48291',
    });
    expect(found.aliases).toEqual([
      'Neon Nineties',
      'concert',
      'Neon Events',
      'Kaartloket',
      'Voorbeeldhal',
      'KL-48291',
    ]);
  });

  it('recognises a ticket shop mail without structured data', () => {
    const found = detectOuting({
      ...base,
      from: { name: 'Weeztix', email: 'noreply@weeztix.example.com' },
      subject: "Je tickets voor 90's Party",
      bodyText:
        'Bestelnummer: WZ-123456\nZaterdag 13 mei 2027 om 21:00 in de Voorbeeldhal.\nLet op: tickets moeten uiterlijk 14 dagen voor het evenement op naam staan.',
      attachments: [
        {
          id: 'a1',
          name: 'tickets.pdf',
          contentType: 'application/pdf',
          size: 2000,
          inline: false,
        },
        {
          id: 'a2',
          name: 'logo.png',
          contentType: 'image/png',
          size: 100,
          inline: true,
        },
      ],
    });
    expect(found).toMatchObject({
      confidence: 'likely',
      title: "90's Party",
      kind: 'feest',
      vendor: 'Weeztix',
      orderNumber: 'WZ-123456',
      startsAt: new Date(2027, 4, 13, 21, 0).toISOString(),
      personaliseBy: new Date(2027, 3, 29, 21, 0).toISOString(),
    });
    expect(found.tickets.map((t) => t.id)).toEqual(['a1']);
  });

  it('says none for ordinary mail', () => {
    const found = detectOuting({
      ...base,
      from: { name: 'Sanne', email: 'sanne@example.nl' },
      subject: 'Etentje zaterdag?',
      bodyText: 'Hebben jullie zin om te komen eten?',
    });
    expect(found.confidence).toBe('none');
  });
});

describe('dates', () => {
  it('reads Dutch, numeric and ISO dates with a time', () => {
    expect(
      datesIn('za 13 mei 2027 20:00, of 14-05-2027 om 19.30, of 2027-05-15'),
    ).toEqual([
      new Date(2027, 4, 13, 20, 0),
      new Date(2027, 4, 14, 19, 30),
      new Date(2027, 4, 15),
    ]);
  });

  it('reads a fixed personalisation deadline', () => {
    expect(
      personaliseDeadline(
        'Zet je tickets op naam vóór 29 april 2027 in je account.',
        null,
      ),
    ).toEqual(new Date(2027, 3, 29));
  });

  it('needs a word about personalising', () => {
    expect(
      personaliseDeadline(
        'Betaal uiterlijk 14 dagen voor aanvang.',
        new Date(),
      ),
    ).toBeNull();
  });
});

describe('ticketLinks', () => {
  it('finds where the shop keeps the tickets, not the help pages', () => {
    const html = `
    <a href="https://order.kaartloket.example.com/download/3f39"><img alt="Klik hier om je tickets te downloaden" src="x.png"></a>
    <a href="https://kaartloket.example.com/ticket-support?utm_source=mail">Ticket support</a>
    <a href="https://get.adobe.com/reader/">Adobe Reader</a>
    <a href="https://track.example.com/3s/tickets.kaartloket.example.com%2Forder%2F01KR/x">Bekijk je tickets</a>
    <a href="https://www.facebook.com/kaartloket">Facebook</a>
    <a href="http://kaartloket.example.com/download/old">Download</a>`;
    expect(ticketLinks(html)).toEqual([
      'https://order.kaartloket.example.com/download/3f39',
      'https://track.example.com/3s/tickets.kaartloket.example.com%2Forder%2F01KR/x',
    ]);
  });
});
