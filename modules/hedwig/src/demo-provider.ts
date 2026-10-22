import { type FakeAttachment, FakeProvider } from './fake-provider';
import type { ProviderMessage } from './provider';

type Seed = Partial<ProviderMessage> & {
  subject: string;
  minutesAgo: number;
  attachments?: FakeAttachment[];
};

const p = (...paragraphs: string[]) => paragraphs.join('\n\n');

// A one-page PDF with one line of ASCII text; the xref offsets are counted so
// a viewer opens it without repairing.
function pdf(name: string, text: string): FakeAttachment {
  const content = `BT /F1 18 Tf 72 760 Td (${text}) Tj ET`;
  const objects = [
    '<< /Type /Catalog /Pages 2 0 R >>',
    '<< /Type /Pages /Kids [3 0 R] /Count 1 >>',
    '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 595 842] /Contents 4 0 R /Resources << /Font << /F1 5 0 R >> >> >>',
    `<< /Length ${content.length} >>\nstream\n${content}\nendstream`,
    '<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>',
  ];
  let out = '%PDF-1.4\n';
  const offsets = objects.map((body, i) => {
    const at = out.length;
    out += `${i + 1} 0 obj\n${body}\nendobj\n`;
    return at;
  });
  const xref = out.length;
  out += `xref\n0 ${objects.length + 1}\n0000000000 65535 f \n`;
  out += offsets
    .map((o) => `${String(o).padStart(10, '0')} 00000 n \n`)
    .join('');
  out += `trailer\n<< /Size ${objects.length + 1} /Root 1 0 R >>\nstartxref\n${xref}\n%%EOF\n`;
  return { name, contentType: 'application/pdf', data: out };
}

// One grey pixel.
const PHOTO = Buffer.from(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAAAAAA6fptVAAAACklEQVR4nGNoAAAAggCBd81ytgAAAABJRU5ErkJggg==',
  'base64',
);

// Invented households mail for demos and for developing the clients without a
// real account. Every person, company and address here is made up.
const SEEDS: Record<string, Seed[]> = {
  work: [
    {
      subject: 'Planning aansluitingen Noord week 45',
      from: { name: 'Sanne Bakker', email: 'sanne.bakker@werk.example' },
      bodyText: p(
        'Hoi,',
        'De planning voor week 45 staat klaar. Voordat ik de aannemer kan inplannen heb ik jouw vrijgave nodig voor de 312 adressen in Noord.',
        'Lukt het om dat vóór woensdag te doen? Anders verschuift de aannemer naar week 47.',
        'Groet,\nSanne',
      ),
      minutesAgo: 70,
      attachments: [
        pdf('planning-week-45.pdf', 'Planning aansluitingen Noord, week 45'),
      ],
    },
    {
      subject: 'INC0042188 aan jou toegewezen: storing kast Noord',
      from: { name: 'Servicedesk', email: 'servicedesk@werk.example' },
      bodyText:
        'Incident INC0042188 is aan jou toegewezen. Korte omschrijving: 14 aansluitingen zonder signaal.',
      minutesAgo: 160,
    },
    {
      subject: 'Re: Re: Re: Wekelijkse planning Zuid',
      from: { name: 'Peter Smits', email: 'peter.smits@werk.example' },
      cc: [{ email: 'owner@example.com' }],
      bodyText:
        'Allen, kleine wijziging: de ploeg van Noord schuift een dag op. Verder blijft alles gelijk.',
      minutesAgo: 95,
    },
  ],
  personal: [
    {
      subject: 'Etentje zaterdag?',
      from: { name: 'Marieke de Vries', email: 'marieke@example.nl' },
      bodyText: p(
        'Hoi!',
        'Zin om zaterdag bij ons te komen eten? Rond 18:30, niks bijzonders, gewoon gezellig.',
        'Neem jij het toetje mee? Laat even weten of het lukt!',
        'Groetjes, Marieke',
      ),
      minutesAgo: 30,
    },
    {
      subject: 'Uw pakket kon niet worden bezorgd',
      from: { name: 'Pakketdienst', email: 'info@pakket-bezorging.example' },
      bodyText:
        'Geachte klant, uw pakket kon niet worden bezorgd wegens onvoldoende verzendkosten (€ 1,99). Betaal binnen 24 uur via onderstaande link, anders wordt het pakket geretourneerd.',
      headers: { authenticationResults: 'dkim=none; spf=softfail' },
      minutesAgo: 240,
    },
    {
      subject: 'Je bestelling komt vandaag tussen 14:00 en 16:00',
      from: { name: 'Webwinkel', email: 'bezorging@webwinkel.example' },
      bodyText:
        'Goed nieuws: je bestelling wordt vandaag bezorgd tussen 14:00 en 16:00.',
      headers: { authenticationResults: 'dkim=pass; spf=pass' },
      minutesAgo: 180,
    },
    {
      subject: "'BTC to $400k'",
      from: { name: 'Crypto Daily', email: 'news@cryptodaily.example' },
      bodyText: 'Spicy Take Sunday. Read online. Unsubscribe at any time.',
      headers: {
        listUnsubscribe: '<mailto:unsub@cryptodaily.example>',
        authenticationResults: 'dkim=pass',
      },
      minutesAgo: 1300,
    },
    {
      subject: "Foto's van het weekend",
      from: { name: 'Bas Janssen', email: 'bas@example.nl' },
      bodyText:
        "Hé! Hierbij de foto's van zaterdag. Die van de vuurtoren is echt goed gelukt. Groet, Bas",
      attachments: [
        { name: 'vuurtoren.png', contentType: 'image/png', data: PHOTO },
      ],
      minutesAgo: 1400,
    },
  ],
  invoices: [
    {
      subject: 'Je factuur voor oktober',
      from: { name: 'Mailhost', email: 'billing@mailhost.example' },
      bodyText:
        'Your invoice for October is attached. Amount: $5.00, charged to your card.',
      attachments: [
        pdf('factuur-oktober.pdf', 'Mailhost - factuur oktober - $5.00'),
      ],
      minutesAgo: 4000,
    },
    {
      subject: 'Herinnering: afspraak dinsdag om 10:30',
      from: {
        name: 'Tandartspraktijk Centrum',
        email: 'afspraken@tandarts.example',
      },
      bodyText:
        'Dit is een herinnering aan uw controleafspraak op dinsdag om 10:30. Wilt u de afspraak bevestigen door op deze mail te antwoorden?',
      minutesAgo: 300,
    },
  ],
  partner: [
    {
      subject: 'Uitslag en vervolgafspraak',
      from: {
        name: 'Huisartsenpraktijk De Linde',
        email: 'praktijk@huisarts.example',
      },
      bodyText:
        'De uitslag is binnen. We willen graag een korte vervolgafspraak met u inplannen via de app of telefonisch.',
      minutesAgo: 50,
    },
    {
      subject: 'Weekendje Texel?',
      from: { name: 'Lotte', email: 'lotte@example.nl' },
      bodyText:
        "Zullen we in november met z'n vieren een weekend naar Texel gaan? Ik heb een leuk huisje gevonden.",
      minutesAgo: 900,
    },
    {
      subject: 'Uw betaling is mislukt',
      from: {
        name: 'Streamingdienst',
        email: 'billing@streaming-account-help.example',
      },
      bodyText:
        'Uw laatste betaling is mislukt. Werk uw gegevens binnen 24 uur bij om uw account actief te houden.',
      headers: { authenticationResults: 'dkim=fail' },
      minutesAgo: 400,
    },
  ],
};

export const DEMO_SEEDS = Object.keys(SEEDS);

export class DemoProvider extends FakeProvider {
  constructor(
    seed: string,
    private readonly ownAddress: string,
    now = new Date(),
  ) {
    super();
    for (const { minutesAgo, ...message } of SEEDS[seed] ?? []) {
      this.deliver({
        to: [{ email: ownAddress }],
        snippet: (message.bodyText ?? '').slice(0, 140),
        receivedAt: new Date(now.getTime() - minutesAgo * 60_000),
        ...message,
      });
    }
  }

  override async address(): Promise<string> {
    return this.ownAddress;
  }
}
