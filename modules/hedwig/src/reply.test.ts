import { describe, expect, it } from 'vitest';
import { replyRecipients } from './reply';

const sender = { name: 'Marieke', email: 'marieke@example.nl' };
const desk = { name: 'Bureau', email: 'bureau@example.nl' };
const me = { email: 'gideon@example.com' };
const bas = { name: 'Bas', email: 'bas@example.nl' };
const joris = { email: 'joris@example.nl' };
const own = ['gideon@example.com', 'gideon@werk.example'];

describe('replyRecipients', () => {
  it('answers the Reply-To address instead of the sender', () => {
    const original = { from: sender, to: [me], cc: [bas], replyTo: [desk] };
    expect(replyRecipients(original, own, false)).toEqual({
      to: [desk],
      cc: [],
    });
  });

  it('answers the sender when there is no Reply-To', () => {
    const original = { from: sender, to: [me], cc: [], replyTo: [] };
    expect(replyRecipients(original, own, false)).toEqual({
      to: [sender],
      cc: [],
    });
  });

  it('answers everyone, keeping Cc in Cc, without the owner or doubles', () => {
    const original = {
      from: sender,
      to: [me, { email: 'Bas@Example.nl' }, joris],
      cc: [
        { email: 'GIDEON@werk.example' },
        bas,
        { email: 'BUREAU@example.nl' },
      ],
      replyTo: [desk],
    };
    expect(replyRecipients(original, own, true)).toEqual({
      to: [desk, { email: 'Bas@Example.nl' }, joris],
      cc: [],
    });
  });

  it('keeps Cc recipients that are nowhere else in Cc', () => {
    const original = { from: sender, to: [me], cc: [bas], replyTo: [] };
    expect(replyRecipients(original, own, true)).toEqual({
      to: [sender],
      cc: [bas],
    });
  });

  it('answers the original recipients of mail the owner sent', () => {
    const original = { from: me, to: [joris], cc: [bas], replyTo: [] };
    expect(replyRecipients(original, own, false)).toEqual({
      to: [joris],
      cc: [],
    });
    expect(replyRecipients(original, own, true)).toEqual({
      to: [joris],
      cc: [bas],
    });
  });

  it('answers the owner when the mail went to nobody else', () => {
    const original = { from: me, to: [me], cc: [], replyTo: [] };
    expect(replyRecipients(original, own, true)).toEqual({
      to: [me],
      cc: [],
    });
  });
});
