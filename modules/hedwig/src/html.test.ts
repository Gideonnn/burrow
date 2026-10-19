import { describe, expect, it } from 'vitest';
import { htmlToText } from './html';

describe('htmlToText', () => {
  it('keeps paragraphs and line breaks, drops tags, styles and scripts', () => {
    const html =
      '<html><head><style>p{color:red}</style></head><body><p>Hoi&nbsp;Eva,</p><p>Tot <b>morgen</b>!<br>Groet</p><script>x()</script></body></html>';
    expect(htmlToText(html)).toBe('Hoi Eva,\nTot morgen!\nGroet');
  });

  it('decodes numeric and named entities', () => {
    expect(htmlToText('Caf&#233; &amp; &#x2764;')).toBe('Café & ❤');
  });
});
