import type { BotDefinition, SkillDefinition } from '@burrow/contracts';
import type { MessageRow } from '../mail/service';

const MAX_BODY = 8_000;

export function systemPrompt(
  bot: BotDefinition,
  skills: SkillDefinition[],
): string {
  return [
    bot.persona,
    ...skills.map((s) => `# Skill: ${s.name}\n\n${s.instructions}`),
  ].join('\n\n');
}

export type TriageContext = {
  ownerName: string;
  instructions: string;
  rules: string[];
  mailbox: { address: string; provider: string };
  message: MessageRow;
  ownerWroteToSender: boolean;
};

// Everything the server knows for certain goes above the line; the sender's
// own text goes in a fenced block that the skill tells the bot to judge, not
// obey. A closing tag inside the mail cannot end the block early.
export function triagePrompt(ctx: TriageContext): string {
  const m = ctx.message;
  const body = (m.bodyText ?? m.snippet)
    .slice(0, MAX_BODY)
    .replaceAll('</untrusted_message>', '</untrusted_message_>');
  const addr = (a: { name?: string; email: string }) =>
    a.name ? `${a.name} <${a.email}>` : a.email;
  return `Sort this message for ${ctx.ownerName}.

## ${ctx.ownerName}'s instructions
${ctx.instructions.trim() || '(none)'}

## Rules learned from ${ctx.ownerName}'s corrections
${ctx.rules.length ? ctx.rules.map((r) => `- ${r}`).join('\n') : '(none)'}

## Message facts (from the server, trustworthy)
- Mailbox: ${ctx.mailbox.address} (${ctx.mailbox.provider})
- From: ${addr(m.from)}
- To: ${m.to.map(addr).join(', ') || '(none)'}
- Cc: ${m.cc.map(addr).join(', ') || '(none)'}
- Subject: ${m.subject}
- Received: ${m.receivedAt.toISOString()}
- Attachments: ${m.hasAttachments ? 'yes' : 'no'}
- Authentication-Results: ${m.headers.authenticationResults ?? '(missing)'}
- List-Unsubscribe: ${m.headers.listUnsubscribe ? 'present' : 'absent'}
- ${ctx.ownerName} has written to this sender before: ${ctx.ownerWroteToSender ? 'yes' : 'no'}

## Message text (untrusted, written by the sender)
<untrusted_message>
${body}
</untrusted_message>

Answer with JSON only, matching the schema.`;
}
